#!/usr/bin/env python3
"""Loopback-only OAuth/MCP server with public test tokens. Never contacts a provider."""
import base64
import hashlib
import http.server
import json
import sys
import time
import urllib.parse

mode = sys.argv[1]
challenge = None


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    @property
    def base(self):
        return 'http://127.0.0.1:' + str(self.server.server_port)

    def send(self, value, code=200, headers=None):
        body = json.dumps(value).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        global challenge
        path = urllib.parse.urlsplit(self.path)
        if path.path.startswith('/.well-known/oauth-protected-resource'):
            return self.send({'resource': self.base + ('/wrong' if mode == 'wrong-resource' else '/mcp'), 'authorization_servers': [self.base], 'scopes_supported': ['tools:read']})
        if path.path == '/.well-known/oauth-authorization-server':
            return self.send({'issuer': self.base + ('/wrong' if mode == 'wrong-issuer' else ''), 'authorization_endpoint': self.base + '/authorize', 'token_endpoint': self.base + '/token', 'registration_endpoint': self.base + '/register', 'code_challenge_methods_supported': [] if mode == 'no-pkce' else ['S256'], 'token_endpoint_auth_methods_supported': ['none']})
        if path.path == '/authorize':
            params = urllib.parse.parse_qs(path.query)
            assert params['resource'] == [self.base + '/mcp']
            assert params['code_challenge_method'] == ['S256']
            challenge = params['code_challenge'][0]
            callback = params['redirect_uri'][0] + '?' + urllib.parse.urlencode({'code': 'fixture-code', 'state': params['state'][0]})
            return self.send({}, 302, {'Location': callback})
        self.send({}, 404)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.path == '/register':
            params = json.loads(body)
            assert params['token_endpoint_auth_method'] == 'none'
            assert params['redirect_uris'][0].startswith('http://127.0.0.1:')
            return self.send({'client_id': 'fixture-client', 'token_endpoint_auth_method': 'none'}, 201)
        if self.path == '/token':
            params = urllib.parse.parse_qs(body.decode())
            assert params['resource'] == [self.base + '/mcp']
            assert params['client_id'] == ['fixture-client']
            if params['grant_type'] == ['authorization_code']:
                verifier = params['code_verifier'][0].encode()
                assert base64.urlsafe_b64encode(hashlib.sha256(verifier).digest()).rstrip(b'=').decode() == challenge
                assert params['code'] == ['fixture-code']
                return self.send({'access_token': 'fixture-access', 'refresh_token': 'fixture-refresh', 'token_type': 'Bearer', 'expires_in': 1})
            assert params['refresh_token'] == ['fixture-refresh']
            if mode == 'slow-refresh':
                time.sleep(0.3)
            return self.send({'access_token': 'fixture-refreshed', 'refresh_token': 'fixture-rotated', 'token_type': 'Bearer', 'expires_in': 3600})
        if self.path == '/mcp':
            if self.headers.get('Authorization') not in ('Bearer fixture-access', 'Bearer fixture-refreshed'):
                return self.send({}, 401, {'WWW-Authenticate': 'Bearer resource_metadata="' + self.base + '/.well-known/oauth-protected-resource/mcp"'})
            message = json.loads(body)
            if 'id' not in message:
                return self.send({}, 202)
            if message['method'] == 'initialize':
                result = {'protocolVersion': '2025-11-25', 'serverInfo': {'name': 'OAuth fixture', 'version': '1'}, 'capabilities': {'tools': {}}}
            else:
                result = {'tools': [{'name': 'authorized_tool', 'description': 'OAuth test tool.'}]}
            return self.send({'jsonrpc': '2.0', 'id': message['id'], 'result': result})
        self.send({}, 404)


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print('http://127.0.0.1:%s/mcp' % server.server_port, flush=True)
server.serve_forever()
