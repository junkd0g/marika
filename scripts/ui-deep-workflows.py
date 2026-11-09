#!/usr/bin/env python3
"""Check search/edit continuity and API request lifecycle against a local server."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--case', choices=['note-create', 'note-edit', 'note-keyboard', 'knowledge', 'requests', 'remove', 'shutdown'])
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-deep-workflows-'))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/slow':
            time.sleep(2)
        body = json.dumps(dict(path=self.path, header=self.headers.get('X-QA'))).encode()
        try:
            self.send_response(503 if self.path == '/error' else 200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'


def s(op, **kw): return dict(op=op, **kw)


def run(case):
    fixture = root / case; fixture.mkdir()
    data = fixture / 'data'; data.mkdir()
    project = fixture / 'Product'; project.mkdir()
    (project / 'README.md').write_text('# Product\n')
    personal = '00000000-0000-0000-0000-000000000001'
    pid, sid, note, first, second = [str(uuid.uuid4()).upper() for _ in range(5)]
    date = '2026-11-09T12:00:00Z'
    (data / 'workspace.json').write_text(json.dumps(dict(
        spaces=[dict(id=personal, name='Personal', notes=[dict(id=note, title='Needle plan',
            blocks=[dict(id=str(uuid.uuid4()), kind='Text', text='Initial draft', checked=False)],
            pinned=False, archived=False, createdAt=date, updatedAt=date)])],
        projects=[dict(id=pid, path=str(project), name='Product', spaceID=personal, conversationSessionID=sid,
            layout=dict(showsInspector=False),
            apiCollection=dict(baseURL=base, endpoints=[dict(name='Slow request', method='GET', path='/slow', source='README.md',
                                                          headers={'X-QA': 'sent-by-marika', 'X-Empty': ''})]),
            knowledge=dict(entries=[dict(id=first, revision=1, updatedAt=date, title='Needle decision', kind='decision', content='First decision'),
                                    dict(id=second, revision=1, updatedAt=date, title='Other document', kind='document', content='Second document')], proposals=[]))],
        sessions=[dict(id=sid, projectID=pid, agent='codex', title='Project chat', mode='ask', createdAt=date, updatedAt=date)],
        selectedSpaceID=personal, selectedSessionID=sid)))
    steps = [s('wait', seconds=1), s('agentsMock'), s('size', width=1240, height=820)]
    if case.startswith('note-'):
        steps += [s('clickMarker', name='space-open-notes')]
        if case == 'note-create':
            steps += [s('spaceContentText', name='space-note-search', text='nothing-matches-qa'),
                      s('assertMarker', name='space-note-title', present=False),
                      s('clickMarker', name='space-note-empty-create'), s('assertMarker', name='space-note-title'),
                      s('spaceContentText', name='space-note-title', text='Created from search')]
        elif case == 'note-keyboard':
            steps += [s('spaceNoteBlock', text='First line'), s('key', code=36, shift=True, application=True),
                      s('spaceContentState'), s('key', code=36), s('wait', seconds=.2), s('spaceContentState'),
                      s('spaceNoteBlock', kind='Bullet list', text='List item'), s('key', code=36, shift=True, application=True),
                      s('spaceContentState'), s('key', code=36), s('wait', seconds=.2),
                      s('spaceContentState'), s('key', code=36), s('wait', seconds=.2), s('spaceContentState'),
                      s('spaceNoteBlock', kind='Code', text='print(1)'), s('key', code=36, shift=True, application=True),
                      s('spaceContentState'), s('key', code=36), s('wait', seconds=.2), s('spaceContentState'),
                      s('spaceNoteBlock', kind='Checklist', checked=True, text='Verify changes'),
                      s('key', code=36, shift=True, application=True), s('spaceContentState'),
                      s('key', code=36), s('wait', seconds=.2), s('spaceContentState'),
                      s('spaceContentText', name='space-note-search', text='Needle'),
                      s('key', code=36, shift=True, application=True), s('assertMarker', name='space-note-title')]
        else:
            steps += [s('spaceContentText', name='space-note-search', text='Needle'),
                      s('spaceContentText', name='space-note-title', text='Renamed plan'),
                      s('assertMarker', name='space-note-title'),
                      s('spaceNoteBlock', text='Editor remains usable after renaming'),
                      s('spaceContentText', name='space-note-search', text='nothing-matches-qa'),
                      s('assertMarker', name='space-note-title', present=False),
                      s('spaceContentText', name='space-note-search', text=''),
                      s('assertMarker', name='space-note-title')]
        steps += [s('spaceContentState'), s('shot', path=str(fixture / 'notes.png'))]
    elif case == 'knowledge':
        steps += [s('researchSection', index=2), s('assertMarker', name='knowledge-search'),
                  s('spaceContentText', name='knowledge-search', text='Needle'),
                  s('assertMarker', name='knowledge-result-' + first),
                  s('clickMarker', name='knowledge-result-' + first), s('clickMarker', name='knowledge-all'),
                  s('assertMarker', name='knowledge-entry-' + second),
                  s('size', width=900, height=600), s('shot', path=str(fixture / 'knowledge.png'))]
    elif case == 'requests':
        steps += [s('shortcut', key='7', exactMenu=True), s('wait', seconds=.3), s('apiClickSend'),
                  s('apiRequestsTest'), s('size', width=900, height=600), s('appearance', dark=True),
                  s('wait', seconds=.3), s('shot', path=str(fixture / 'api-dark.png')),
                  s('appearance', dark=False), s('wait', seconds=.3), s('shot', path=str(fixture / 'api-light.png'))]
    else:
        steps += [s('apiLifecycleTest', action=case)]
    steps.append(s('exitWithoutSaving') if case == 'shutdown' else s('quit'))
    script, log = fixture / 'steps.json', fixture / 'driver.log'
    script.write_text(json.dumps(steps))
    with log.open('w') as out:
        result = subprocess.run([str(repo / '.build/debug/Marika')], cwd=repo,
            env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script), MARIKA_DEMO='1',
                     MARIKA_EDITOR_DEFAULTS_SUITE='app.marika.deep-workflows.' + uuid.uuid4().hex),
            stdout=out, stderr=subprocess.STDOUT, timeout=60)
    assert result.returncode == 0 and '[driver] FAILED' not in log.read_text(), f'{log}\n{log.read_text()[-3500:]}'
    if case == 'note-keyboard':
        states = [json.loads(line.split('[driver] spaceContent ', 1)[1])['notes'][0]['blocks']
                  for line in log.read_text().splitlines() if '[driver] spaceContent ' in line]
        assert len(states[0]) == 1 and states[0][0]['text'] == 'First line\n', states
        assert len(states[1]) == 2, states
        assert len(states[2]) == 2 and states[2][1]['text'] == 'List item\n', states
        assert len(states[3]) == 3 and states[3][2]['kind'] == 'Bullet list', states
        assert len(states[4]) == 3 and states[4][2]['kind'] == 'Text', states
        assert len(states[5]) == 3 and states[5][2]['text'] == 'print(1)\n', states
        assert len(states[6]) == 4 and states[6][3]['kind'] == 'Text', states
        assert len(states[7]) == 4 and states[7][3]['text'] == 'Verify changes\n', states
        assert len(states[8]) == 5 and states[8][4]['kind'] == 'Checklist' and not states[8][4]['checked'], states
        saved = json.loads((data / 'workspace.json').read_text())['spaces'][0]['notes'][0]['blocks']
        assert len(saved) == 5 and saved[0]['text'] == 'First line\n', saved
    elif case.startswith('note-'):
        saved = json.loads((data / 'workspace.json').read_text())['spaces'][0]['notes']
        assert any(n['title'] == ('Created from search' if case == 'note-create' else 'Renamed plan') for n in saved), saved


failures = []
try:
    for case in [args.case] if args.case else ['note-create', 'note-edit', 'note-keyboard', 'knowledge', 'requests', 'remove', 'shutdown']:
        try:
            run(case)
            print('Passed', case, flush=True)
        except Exception as error:
            failures.append(case)
            print(error, flush=True)
finally:
    server.shutdown()
print('Diagnostics:', root)
if failures:
    raise SystemExit('Deep workflow checks failed: ' + ', '.join(failures))
