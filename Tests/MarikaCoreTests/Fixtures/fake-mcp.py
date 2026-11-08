#!/usr/bin/env python3
"""Local MCP fixture: discovery only, with strict handshake and session checks."""
import http.server
import json
import os
import queue
import sys
import threading
import time

mode = sys.argv[1]
log_path = sys.argv[2]
initialized = False
messages = queue.Queue()
lock = threading.Lock()


def log(value):
    with lock, open(log_path, 'a') as output:
        output.write(json.dumps(value) + '\n')


def reply(message):
    global initialized
    method = message.get('method')
    log(message)
    if method == 'initialize':
        if os.environ.get('MCP_EXPECT_TOKEN') and os.environ.get('TOKEN') != os.environ['MCP_EXPECT_TOKEN']:
            raise RuntimeError('Missing expanded environment variable')
        return {'protocolVersion': '2025-11-25', 'capabilities': {'tools': {}, 'resources': {}, 'prompts': {}},
                'serverInfo': {'name': 'Marika fixture', 'version': '1.0'}}
    if method == 'notifications/initialized':
        initialized = True
        return None
    if not initialized:
        raise RuntimeError('Initialization notification missing')
    if method == 'tools/list':
        if message.get('params', {}).get('cursor') == 'next':
            return {'tools': [{'name': 'inspect_schema', 'description': 'Inspect a local fixture schema.'}]}
        return {'tools': [{'name': 'read_file', 'description': 'Read a file in the project.', 'annotations': {'readOnlyHint': True, 'destructiveHint': False, 'openWorldHint': False}}], 'nextCursor': 'next'}
    if method == 'resources/list':
        return {'resources': [{'uri': 'fixture://schema', 'name': 'Schema'}]}
    if method == 'prompts/list':
        return {'prompts': [{'name': 'review'}]}
    raise RuntimeError('Unexpected request: ' + str(method))


if mode in ('stdio', 'silent'):
    for line in sys.stdin:
        message = json.loads(line)
        if mode == 'silent':
            time.sleep(30)
            continue
        result = reply(message)
        if result is not None:
            print(json.dumps({'jsonrpc': '2.0', 'id': message['id'], 'result': result}), flush=True)
    sys.exit(0)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def respond(self, status, body=b'', content_type='application/json', session=False):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        if session:
            self.send_header('Mcp-Session-Id', 'fixture-session')
        self.end_headers()
        if body:
            self.wfile.write(body)
        self.wfile.flush()

    def do_DELETE(self):
        log({'method': 'DELETE', 'session': self.headers.get('Mcp-Session-Id')})
        self.respond(204)

    def do_GET(self):
        if mode != 'legacy':
            return self.respond(405)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        self.wfile.write(b'event: endpoint\ndata: /messages\n\n')
        self.wfile.flush()
        try:
            while True:
                message = messages.get(timeout=20)
                self.wfile.write(('event: message\ndata: ' + json.dumps(message) + '\n\n').encode())
                self.wfile.flush()
        except (queue.Empty, BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        message = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if mode == 'unauthorized':
            return self.respond(401)
        if mode == 'http-auth' and self.headers.get('Authorization') != 'Bearer fixture-secret':
            return self.respond(403)
        if mode != 'legacy' and message.get('method') != 'initialize':
            if self.headers.get('Mcp-Session-Id') != 'fixture-session' or self.headers.get('MCP-Protocol-Version') != '2025-11-25':
                return self.respond(400)
        result = reply(message)
        if result is None:
            return self.respond(202)
        response = {'jsonrpc': '2.0', 'id': message['id'], 'result': result}
        if mode == 'legacy':
            messages.put(response)
            return self.respond(202)
        if mode == 'http-sse':
            # Multiple data lines are legal and must be joined with a newline.
            body = ''.join('data: ' + line + '\n' for line in json.dumps(response, indent=2).splitlines()) + '\n'
            return self.respond(200, body.encode(), 'text/event-stream', session=True)
        self.respond(200, json.dumps(response).encode(), session=True)


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print('http://127.0.0.1:%s/mcp' % server.server_port, flush=True)
server.serve_forever()
