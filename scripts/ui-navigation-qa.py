#!/usr/bin/env python3
"""Guard cross-section navigation and compact layouts with many spaces."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-navigation-qa-'))
data, project = root / 'data', root / 'Copper'
data.mkdir(); project.mkdir()
(project / 'README.md').write_text('# QA project\n')
personal = '00000000-0000-0000-0000-000000000001'
pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
spaces = [dict(id=personal, name='Personal')]
spaces += [dict(id=str(uuid.uuid4()), name=name) for name in
           ['Research', 'Client website redesign', 'Operations', 'Writing', 'Support', 'A long space name for QA']]
(data / 'workspace.json').write_text(json.dumps(dict(spaces=spaces, selectedSpaceID=personal,
    projects=[dict(id=pid, path=str(project), name='Copper', spaceID=personal, conversationSessionID=sid,
                   layout=dict(panel='Code', openTabs=['Conversation', 'Code', 'Agents', 'Stats'], showsInspector=False))],
    sessions=[dict(id=sid, projectID=pid, agent='codex', title='Project chat', mode='ask',
                   createdAt='2026-11-09T12:00:00Z', updatedAt='2026-11-09T12:00:00Z')])))

def s(op, **kw): return dict(op=op, **kw)

steps = [s('wait', seconds=1), s('agentsMock'), s('size', width=900, height=600), s('appearance', dark=True),
    s('wait', seconds=.3), s('qaLayoutState'), s('shot', path=str(root / 'compact-project.png')),
    s('clickMarker', name='space-open-notes'), s('clickMarker', name='space-note-new'),
    s('spaceContentText', name='space-note-title', text='QA plan'), s('qaLayoutState'),
    s('shot', path=str(root / 'compact-notes-dark.png')),
    s('welcomeShow'), s('wait', seconds=.2), s('assertMarker', name='welcome-checklist'), s('qaLayoutState'),
    s('projectClick', name='Copper'), s('assertMarker', name='workspace-header'),
    s('assertMarker', name='welcome-checklist', present=False),
    s('clickMarker', name='space-open-tickets'), s('welcomeShow'), s('wait', seconds=.2),
    s('assertMarker', name='welcome-checklist'), s('welcomeFinish', explore=True),
    s('assertMarker', name='workspace-header'), s('welcomeShow'),
    s('spaceSwitch', name='Research'), s('assertMarker', name='space-empty'),
    s('assertMarker', name='welcome-checklist', present=False),
    s('spaceSwitch', name='Personal'), s('clickMarker', name='space-open-notes'),
    s('appearance', dark=False), s('wait', seconds=.3), s('qaLayoutState'),
    s('shot', path=str(root / 'compact-notes-light.png'))]
for shortcut, title in [('1', 'chat'), ('2', 'code'), ('3', 'browser'), ('4', 'agents'), ('5', 'stats'),
                        ('6', 'pipelines'), ('7', 'api'), ('8', 'changes'), ('9', 'terminal'), ('0', 'research')]:
    steps += [s('shortcut', key=shortcut, exactMenu=True), s('wait', seconds=.3),
              s('assertMarker', name='workspace-header'), s('qaLayoutState'),
              s('shot', path=str(root / (title + '-compact.png')))]
steps.append(s('quit'))
(root / 'steps.json').write_text(json.dumps(steps))
log = root / 'driver.log'
with log.open('w') as out:
    result = subprocess.run([str(repo / '.build/debug/Marika')], cwd=repo,
        env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(root / 'steps.json'), MARIKA_DEMO='1',
                 MARIKA_EDITOR_DEFAULTS_SUITE='app.marika.navigation-qa.' + uuid.uuid4().hex),
        stdout=out, stderr=subprocess.STDOUT, timeout=90)
assert result.returncode == 0 and '[driver] FAILED' not in log.read_text(), f'{log}\n{log.read_text()[-4000:]}'
states = [json.loads(line.split('[driver] qaLayout ', 1)[1]) for line in log.read_text().splitlines() if '[driver] qaLayout ' in line]
assert all(state['projectListHeight'] >= 79 and state['windowWidth'] <= 901 for state in states), states
assert states[0]['tabWidths']['Agents'] >= 85, states[0]
assert states[2]['welcome'] and states[2]['commandPanel'] == '', states[2]
assert states[-1]['space'] == 'Personal', states[-1]
print('Help navigation, project navigation, hidden commands and compact many-space layouts passed. Diagnostics:', root)
