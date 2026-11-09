#!/usr/bin/env python3
"""Check preview recovery, sign-in feedback and native window chrome using isolated data."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-followups-'))
data, project = root / 'data', root / 'Preview Demo'
data.mkdir()
(project / 'settings').mkdir(parents=True)
(project / 'index.html').write_text('<!doctype html><title>Preview home</title><h1>Preview home</h1>')
(project / 'settings/index.html').write_text('<!doctype html><title>Recovered route</title><h1>Your project preview is back.</h1>')
with socket.socket() as reserve:
    reserve.bind(('127.0.0.1', 0))
    port = reserve.getsockname()[1]
base = f'http://127.0.0.1:{port}'
target = base + '/settings/?view=one#details'
pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
(data / 'workspace.json').write_text(json.dumps(dict(projects=[dict(id=pid, path=str(project), name='Preview Demo',
    previewConfiguration=dict(command=f'/usr/bin/python3 -m http.server {port} --bind 127.0.0.1', address=base + '/'),
    layout=dict(panel='Browser', showsInspector=False, browserURLs=[target]))],
    sessions=[dict(id=sid, projectID=pid, agent='claude', title='Setup checks', mode='ask',
                   createdAt='2026-11-09T12:00:00Z', updatedAt='2026-11-09T12:00:00Z')])))


def step(op, **values):
    return dict(op=op, **values)


steps = [step('wait', seconds=.8), step('welcomeStatus', codex='ready'), step('welcomeShow'), step('welcomeState'),
    step('size', width=900, height=600), step('wait', seconds=.2), step('shot', path=str(root / 'ready-agent-suggestion.png')),
    step('welcomeUseReadyAgent'), step('welcomeState'), step('welcomeFinish'),
    step('shortcut', key='3', exactMenu=True), step('wait', seconds=.5), step('toolbarCheck'),
    step('browserCheck', hasError=True), step('shot', path=str(root / 'preview-stopped.png')),
    step('clickMarker', name='browser-start-project-preview'), step('previewWait'), step('browserWait'),
    step('wait', seconds=.3), step('browserCheck', title='Recovered route'), step('browserState'),
    step('shot', path=str(root / 'preview-recovered.png')),
    step('fullScreen', enabled=True), step('toolbarCheck'), step('uiState'), step('shot', path=str(root / 'fullscreen.png')),
    step('fullScreen', enabled=False), step('toolbarCheck'), step('previewStop'),
    step('welcomeShow'), step('welcomeStatus', codex='signedOut', codexExecutable='/bin/echo'),
    step('signInFixture', failFirst=True, seconds=1.5), step('signInStart'), step('signInState'),
    step('wait', seconds=.2), step('shot', path=str(root / 'sign-in-failed.png')),
    step('signInStart'), step('signInState'), step('wait', seconds=.2), step('shot', path=str(root / 'sign-in-waiting.png')),
    step('wait', seconds=2), step('signInState'), step('welcomeState'), step('shot', path=str(root / 'sign-in-confirmed.png')),
    step('quit')]
script, log = root / 'steps.json', root / 'driver.log'
script.write_text(json.dumps(steps))
with log.open('w') as output:
    result = subprocess.run([str(repo / '.build/debug/Marika')], cwd=repo,
        env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script), MARIKA_DEMO='1',
                 MARIKA_EDITOR_DEFAULTS_SUITE='app.marika.followups.' + uuid.uuid4().hex),
        stdout=output, stderr=subprocess.STDOUT, timeout=75)
lines = log.read_text().splitlines()
assert result.returncode == 0 and not any('[driver] FAILED' in line for line in lines), log


def records(kind):
    return [json.loads(line.split('[driver] ' + kind + ' ', 1)[1]) for line in lines if '[driver] ' + kind + ' ' in line]


welcome = records('welcome')
assert welcome[0]['agent'] == 'claude' and welcome[0]['suggestedAgent'] == 'codex', welcome
assert welcome[1]['agent'] == 'codex' and welcome[1]['ready'], welcome
assert records('browser state')[0]['url'] == target, records('browser state')
assert [state['phase'] for state in records('signIn')] == ['failed', 'waiting', 'succeeded'], records('signIn')
assert welcome[-1]['ready'], welcome
assert records('ui')[0]['fullScreen'] and not records('ui')[0]['toolbarVisible'], records('ui')
print('Preview recovery, ready-agent suggestion, sign-in retry/confirmation and full-screen chrome passed. Diagnostics:', root)
