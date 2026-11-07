#!/usr/bin/env python3
"""Check speed selection, persistence and the chat layout without provider requests."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-codex-style-'))
project, data = root / 'Studio', root / 'data'
project.mkdir()
data.mkdir()
pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
workspace = {'projects': [{'id': pid, 'path': str(project), 'name': 'Studio', 'layout': {'showsInspector': False}}],
             'sessions': [{'id': sid, 'projectID': pid, 'agent': 'codex', 'title': 'New session',
                           'mode': 'ask', 'createdAt': '2026-11-07T12:00:00Z', 'updatedAt': '2026-11-07T12:00:00Z'}]}
(data / 'workspace.json').write_text(json.dumps(workspace))


def s(op, **kw):
    return dict(op=op, **kw)


def run(name, steps):
    script, log = root / (name + '.json'), root / (name + '.log')
    script.write_text(json.dumps(steps))
    with log.open('w') as output:
        result = subprocess.run([str(repo / '.build/debug/Marika')],
            env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script)),
            stdout=output, stderr=subprocess.STDOUT, timeout=60)
    lines = log.read_text().splitlines()
    assert result.returncode == 0 and not any('[driver] FAILED' in line for line in lines), log
    return lines


def records(lines, name):
    prefix = '[driver] ' + name + ' '
    return [json.loads(line.split(prefix, 1)[1]) for line in lines if prefix in line]


steps = [s('wait', seconds=1), s('agentsMock', seconds=.1), s('composerMock'),
         s('appearance', dark=True), s('size', width=1240, height=820), s('wait', seconds=.25),
         s('shot', path=str(root / 'new-chat-dark.png')),
         s('settings', serviceTier='priority'), s('state'),
         s('send', text='Review this project and suggest a focused improvement.'), s('wait', seconds=.3),
         s('draft', text='Make the search easier to use, and keep the keyboard shortcuts working.\nAdd a test for the change.'),
         s('settings', effort='high'), s('uiState'), s('shot', path=str(root / 'chat-dark.png')),
         s('size', width=900, height=600), s('inspector', show=True), s('wait', seconds=.25), s('uiState'),
         s('shot', path=str(root / 'chat-narrow.png')),
         s('settings', serviceTier='ultrafast'), s('state'),
         s('appearance', dark=False), s('wait', seconds=.2), s('uiState'), s('shot', path=str(root / 'chat-light.png')),
         s('checkpoint'), s('quit')]
lines = run('layout-and-speed', steps)
assert [state['serviceTier'] for state in records(lines, 'state')] == ['priority', 'ultrafast']
for ui in records(lines, 'ui'):
    assert ui['titleHidden'], 'The extra window title returned'
    for name, control in ui['windowControls'].items():
        assert control and control['visible'] and control['enabled'], f'{name} window control is unavailable: {ui}'
        assert control['bounds']['width'] > 0 and control['bounds']['height'] > 0, control
    speed, content = ui['speed'], ui['content']
    assert speed and speed['width'] > 30 and speed['height'] > 5, ui
    assert speed['x'] >= content['x'] and speed['x'] + speed['width'] <= content['x'] + content['width'] + 1, ui
    assert ui['composer']['height'] >= min(ui['composerUsedHeight'], 190) - 1, ui
saved = json.loads((data / 'workspace.json').read_text())
assert saved['sessions'][0]['serviceTier'] == 'ultrafast'
assert saved['sessions'][0]['effort'] == 'high'
restored = run('restored', [s('wait', seconds=1), s('composerMock'), s('state'), s('uiState'),
                            s('settings', serviceTier='default'), s('state'),
                            s('checkpoint'), s('quit')])
states = records(restored, 'state')
assert states[0]['serviceTier'] == 'ultrafast' and states[0]['effort'] == 'high'
assert states[-1]['serviceTier'] == 'default' and states[-1]['effort'] == 'high'
print('Codex-style UI and speed persistence checks passed. Screenshots and logs:', root)
