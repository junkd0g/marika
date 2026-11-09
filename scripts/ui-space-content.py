#!/usr/bin/env python3
"""Check native space notes, block editing, tickets, isolation, autosave and restart."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-space-content-'))
data = root / 'data'; data.mkdir()
project = root / 'Product'; project.mkdir()
(project / 'README.md').write_text('# Product\n')
space, pid, sid = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
personal = '00000000-0000-0000-0000-000000000001'
(data / 'workspace.json').write_text(json.dumps(dict(
    spaces=[dict(id=personal, name='Personal'), dict(id=space, name='Product', color='violet')],
    projects=[dict(id=pid, path=str(project), name='Product', spaceID=space, conversationSessionID=sid, layout=dict(showsInspector=False))],
    sessions=[dict(id=sid, projectID=pid, agent='codex', title='Project chat', mode='ask', createdAt='2026-11-09T12:00:00Z', updatedAt='2026-11-09T12:00:00Z')], selectedSpaceID=personal)))


def s(op, **kw):
    return dict(op=op, **kw)


def run(name, steps):
    script, log = root / (name + '.json'), root / (name + '.log')
    script.write_text(json.dumps(steps))
    with log.open('w') as out:
        result = subprocess.run([str(repo / '.build/debug/Marika')], cwd=repo,
            env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script), MARIKA_DEMO='1',
                     MARIKA_EDITOR_DEFAULTS_SUITE='app.marika.space-content.' + uuid.uuid4().hex),
            stdout=out, stderr=subprocess.STDOUT, timeout=100)
    assert result.returncode == 0 and '[driver] FAILED' not in log.read_text(), f'{log}\n{log.read_text()[-5000:]}'
    return [json.loads(line.split('[driver] spaceContent ', 1)[1]) for line in log.read_text().splitlines() if '[driver] spaceContent ' in line]


states = run('content', [s('wait', seconds=1), s('agentsMock'), s('size', width=1240, height=820),
    s('clickMarker', name='space-open-notes'), s('clickMarker', name='space-note-new'),
    s('spaceContentText', name='space-note-title', text='Personal ideas'),
    s('spaceNoteBlock', kind='Heading', text='What to build'),
    s('spaceNoteBlock', kind='Checklist', append=True, checked=True, text='Write the first plan'),
    s('key', code=36), s('wait', seconds=.2), s('spaceContentState'), s('shot', path=str(root / 'notes-dark.png')),
    s('spaceSwitch', name='Product'), s('clickMarker', name='space-open-notes'), s('spaceContentState'),
    s('clickMarker', name='space-note-new'), s('spaceContentText', name='space-note-title', text='Team decisions'),
    s('spaceNoteBlock', kind='Text', text='The ticket board belongs to this space.'),
    s('clickMarker', name='space-note-archive'), s('clickMarker', name='space-note-show-archive'),
    s('spaceContentState'), s('clickMarker', name='space-note-archive'), s('clickMarker', name='space-note-show-archive'),
    s('spaceContentState'), s('clickMarker', name='space-open-tickets'), s('clickMarker', name='space-ticket-new'),
    s('spaceContentText', name='space-ticket-title', text='Improve the login screen'),
    s('spaceContentText', name='space-ticket-description', text='## Acceptance criteria\n- Show a clear next step\n- Preserve keyboard navigation'),
    s('spaceTicketFields', status='In Progress', priority='High', assignee='Jordan', linkProject=True),
    s('shot', path=str(root / 'ticket-editor.png'), sheet=True),
    s('appearance', dark=False), s('wait', seconds=.3), s('shot', path=str(root / 'ticket-editor-light.png'), sheet=True),
    s('appearance', dark=True), s('wait', seconds=.3), s('clickMarker', name='space-ticket-done'),
    s('spaceContentState'), s('shot', path=str(root / 'ticket-board-dark.png')),
    s('appearance', dark=False), s('size', width=900, height=650), s('wait', seconds=.3), s('shot', path=str(root / 'ticket-board-light.png')),
    s('wait', seconds=1), s('exitWithoutSaving')])
assert states[0]['space'] == 'Personal' and states[0]['notes'][0]['title'] == 'Personal ideas', states
assert states[0]['notes'][0]['blocks'][1]['checked'], states
assert len(states[0]['notes'][0]['blocks']) == 3 and states[0]['notes'][0]['blocks'][2]['kind'] == 'Checklist', states
assert states[1]['space'] == 'Product' and states[1]['notes'] == [] and states[1]['tickets'] == [], states
assert states[2]['notes'][0]['archived'] and not states[3]['notes'][0]['archived'], states
assert states[4]['tickets'][0]['title'] == 'Improve the login screen' and states[4]['tickets'][0]['projectID'].lower() == pid.lower(), states
assert states[4]['tickets'][0]['status'] == 'In Progress' and states[4]['tickets'][0]['priority'] == 'High', states
saved = json.loads((data / 'workspace.json').read_text())
assert saved['spaces'][1]['section'] == 'Tickets' and saved['spaces'][1]['tickets'][0]['body'].startswith('## Acceptance'), saved
restored = run('restart', [s('wait', seconds=1), s('spaceContentState'),
    s('spaceSwitch', name='Personal'), s('spaceContentState'),
    s('clickMarker', name='space-open-tickets'), s('spaceContentState'),
    s('clickMarker', name='space-ticket-new'), s('spaceContentText', name='space-ticket-title', text='A separate ticket'),
    s('clickMarker', name='space-ticket-done'), s('spaceContentState'), s('quit')])
assert restored[0]['space'] == 'Product' and restored[0]['section'] == 'Tickets' and len(restored[0]['tickets']) == 1, restored
assert restored[1]['space'] == 'Personal' and restored[1]['section'] == 'Notes' and restored[1]['notes'][0]['title'] == 'Personal ideas', restored
assert restored[2]['tickets'] == [], restored
assert restored[3]['tickets'][0]['key'] != restored[0]['tickets'][0]['key'], restored
print('Space notes, native block/ticket editing, archive/restore, isolation, autosave and restart passed. Diagnostics:', root)
