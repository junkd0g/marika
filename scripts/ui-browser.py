#!/usr/bin/env python3
"""Exercise the native browser against a local server using isolated project data."""
import base64
import functools
import http.server
import json
import os
import plistlib
import shutil
from pathlib import Path
import subprocess
import tempfile
import threading
import sys
import time
import socket
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-browser-'))
data = root / 'data'
data.mkdir()
app = root / 'Marika.app'
(app / 'Contents/MacOS').mkdir(parents=True)
(app / 'Contents/Resources').mkdir()
for name in ['Marika', 'MarikaBrowserMCP']:
    shutil.copy2(repo / '.build/debug' / name, app / 'Contents/MacOS' / name)
shutil.copy2(repo / 'Resources/Info.plist', app / 'Contents/Info.plist')
info_path = app / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
info['CFBundleIdentifier'] = 'app.marika.browser-tests.' + uuid.uuid4().hex
info_path.write_bytes(plistlib.dumps(info))
shutil.copy2(repo / 'Resources/AppIcon.icns', app / 'Contents/Resources/AppIcon.icns')
(app / 'Contents/Frameworks').mkdir()
shutil.copytree(repo / '.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework',
                app / 'Contents/Frameworks/Sparkle.framework', symlinks=True)
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True, capture_output=True)
project = root / 'Project'
project.mkdir()
(project / 'index.html').write_text('''<!doctype html><meta charset="utf-8"><title>Browser Test</title><link rel="icon" href="/favicon.png">
<style>body{font:16px system-ui;max-width:720px;margin:64px auto;background:#f7f8fa;color:#182230}
h1{font-size:42px}a{color:#3269d9}section{padding:30px;background:white;border-radius:14px;margin-top:24px}</style>
<h1>A browser that feels at home.</h1><p>Local preview, persistent sessions, and familiar controls.</p>
<section><h2>Preview workspace</h2><p>Find this unique browser needle.</p>
<a id="next" href="second.html">Next page</a> · <a id="popup" href="second.html" target="_blank">Open in a tab</a></section>
<p><a id="download" href="sample.bin" download>Download sample</a></p>
<p><button onclick="document.getElementById('result').textContent = confirm('Local dialog test') ? 'Confirmed' : 'Cancelled'">Test dialog</button></p>
<label>Choose a test file <input type="file" onchange="document.getElementById('result').textContent = this.files[0]?.name || 'No file'"></label><p id="result"></p>
''')
(project / 'favicon.png').write_bytes(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1sAAAAASUVORK5CYII='))
(project / 'sample.bin').write_text('Browser download fixture')
(project / 'second.html').write_text('<!doctype html><title>Second Page</title><h1>Second page</h1><a href="index.html">Back home</a>')

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    flaky_count = 0
    def do_GET(self):
        if self.path == '/sample.bin':
            payload = b'Browser download fixture'
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', 'attachment; filename="' + root.name + '.bin"')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        elif self.path == '/flaky.bin':
            type(self).flaky_count += 1
            payload = b'Retried download fixture'
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload[:3] if type(self).flaky_count == 1 else payload)
            self.wfile.flush()
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_WR)
        elif self.path == '/slow.bin':
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', '1048576')
            self.end_headers()
            try:
                for _ in range(32):
                    self.wfile.write(b'x' * 32768)
                    self.wfile.flush()
                    time.sleep(.05)
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            super().do_GET()
    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(QuietHandler, directory=str(project)))
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'
pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
(data / 'workspace.json').write_text(json.dumps(dict(
    projects=[dict(id=pid, path=str(project), name='Browser Studio', conversationSessionID=sid, layout=dict(showsInspector=False))],
    sessions=[dict(id=sid, projectID=pid, agent='codex', title='Browser checks', mode='ask', createdAt='2026-11-08T12:00:00Z', updatedAt='2026-11-08T12:00:00Z')]
)))

def step(op, **values):
    return dict(op=op, **values)

def shortcut(key, **values):
    return step('shortcut', key=key, exactMenu=True, **values)

def run(name, steps):
    script, log = root / (name + '.json'), root / (name + '.log')
    script.write_text(json.dumps(steps))
    with log.open('w') as output:
        result = subprocess.run([str(app / 'Contents/MacOS/Marika')], env=dict(os.environ,
            MARIKA_DATA=str(data), MARIKA_DRIVER=str(script), MARIKA_DEMO='1',
            MARIKA_EDITOR_PREFERENCES=str(root / 'preferences.json')), stdout=output, stderr=subprocess.STDOUT, timeout=100)
    assert result.returncode == 0 and '[driver] FAILED' not in log.read_text(), f'{log}\n{log.read_text()[-4000:]}'

if '--interactive' in sys.argv:
    script = root / 'interactive.json'
    script.write_text(json.dumps([step('wait', seconds=1), step('codeOpen', path='index.html'), shortcut('3'), step('browserOpen', url=base + '/index.html'), step('browserWait'), step('split', panel='code')]))
    print('INTERACTIVE_APP=' + str(app), flush=True)
    print('INTERACTIVE_ROOT=' + str(root), flush=True)
    print('INTERACTIVE_URL=' + base, flush=True)
    try:
        with (root / 'interactive.log').open('w') as output:
            subprocess.run([str(app / 'Contents/MacOS/Marika')], env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script), MARIKA_DEMO='1'), stdout=output, stderr=subprocess.STDOUT)
    finally:
        server.shutdown()
    sys.exit(0)

try:
    run('browser', [
        step('wait', seconds=1), shortcut('3'), step('wait', seconds=.4),
        step('appearance', dark=True), step('shot', path=str(root / 'new-tab-dark.png')),
        shortcut('l'), step('wait', seconds=.2), step('browserCheck', focusedField='Search or enter address'),
        step('browserAddress', text=base + '/index.html'), step('key', code=36), step('browserWait'),
        step('browserCheck', tabs=1, title='Browser Test', history=1),
        shortcut('f'), step('wait', seconds=.3), step('shot', path=str(root / 'find.png')), step('browserCheck', focusedField='Find in page'),
        step('browserFind', text='unique browser needle'), step('browserCheck', found=True),
        step('browserFind', text='not-on-the-page-9876'), step('browserCheck', found=False),
        step('key', code=53), shortcut('d'), step('browserCheck', bookmarks=1),
        step('browserPrepareDownload', path=str(root / 'downloaded.bin')),
        step('browserJS', script="document.getElementById('download').click(); return true;"),
        step('browserSaveDownload', path=str(root / 'downloaded.bin'), content='Browser download fixture'),
        shortcut('+'), step('browserCheck', zoom=1.1), shortcut('-'), step('browserCheck', zoom=1.0),
        step('browserJS', script="document.cookie='marika_test=retained; max-age=3600; path=/'; localStorage.setItem('marika_test','retained'); return true;", expect=True),
        step('browserJS', script="document.getElementById('next').click(); return true;"), step('browserWait'),
        step('browserCheck', title='Second Page', history=2), shortcut('['), step('browserWait'),
        step('browserCheck', title='Browser Test'), shortcut(']'), step('browserWait'),
        step('browserCheck', title='Second Page'), shortcut('t'), step('wait', seconds=.3),
        step('browserCheck', tabs=2, focusedField='Search or enter address'), shortcut('w'),
        step('browserCheck', tabs=1), shortcut('['), step('browserWait'),
        step('browserJS', script="document.getElementById('popup').click(); return true;"), step('wait', seconds=.5), step('browserWait'),
        step('browserCheck', tabs=2, title='Second Page'), shortcut('w'),
        step('browserCheck', tabs=1), shortcut('t', shift=True), step('browserWait'),
        step('browserCheck', tabs=2, title='Second Page'), step('browserMoveTab'),
        shortcut('[', shift=True), step('browserCheck', title='Browser Test'),
        step('wait', seconds=.4), step('shot', path=str(root / 'browser-dark.png')),
        step('appearance', dark=False), step('size', width=900, height=650), step('wait', seconds=.4),
        step('shot', path=str(root / 'browser-light-compact.png')), step('wait', seconds=1), step('quit')
    ])
    run('restart', [step('wait', seconds=1), shortcut('3'), step('browserWait'),
        step('browserCheck', tabs=2, title='Browser Test', bookmarks=1, history=2),
        step('browserJS', script="return document.cookie.includes('marika_test=retained') && localStorage.getItem('marika_test') === 'retained';", expect=True),
        step('browserPolishChecks'), step('quit')])
    saved = json.loads((data / 'workspace.json').read_text())['projects'][0]['layout']
    assert {page['title'] for page in saved['browserLibrary']['history']} == {'Browser Test', 'Second Page'}, saved
    print('Browser navigation, tabs, find, zoom, bookmarks, history and session restoration passed. Screenshots and logs:', root)
finally:
    server.shutdown()
