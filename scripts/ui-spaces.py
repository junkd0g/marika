#!/usr/bin/env python3
"""Exercise native spaces controls, project scoping, live work and restart restoration.

Build the debug app first. This uses isolated data and mock agents.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-spaces-ui-'))
data = root / 'data'
data.mkdir()
projects, sessions = [], []
for index, name in enumerate(['Studio', 'Research']):
    folder = root / name
    folder.mkdir()
    (folder / 'README.md').write_text('# ' + name + '\n')
    pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
    projects.append(dict(id=pid, path=str(folder), name=name, conversationSessionID=sid,
                         layout=dict(showsInspector=False)))
    sessions.append(dict(id=sid, projectID=pid, agent='codex', title=name + ' chat', mode='ask',
                         createdAt=f'2026-11-0{6-index}T12:00:00Z', updatedAt=f'2026-11-0{6-index}T12:00:00Z'))
(data / 'workspace.json').write_text(json.dumps(dict(projects=projects, sessions=sessions)))


def step(op, **values):
    return dict(op=op, **values)


def run(name, steps):
    script, log = root / (name + '.json'), root / (name + '.log')
    script.write_text(json.dumps(steps))
    with log.open('w') as output:
        result = subprocess.run([str(repo / '.build/debug/Marika')],
                                env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script)),
                                stdout=output, stderr=subprocess.STDOUT, timeout=75)
    lines = log.read_text().splitlines()
    assert result.returncode == 0 and not any('[driver] FAILED' in line for line in lines), log
    return [json.loads(line.split('[driver] spaces ', 1)[1]) for line in lines if '[driver] spaces ' in line]


run('controls', [step('wait', seconds=1), step('appearance', dark=True),
                 step('spacesTest', directory=str(root)), step('quit')])
saved = json.loads((data / 'workspace.json').read_text())
assert [space['name'] for space in saved['spaces']] == ['Personal', 'Studio'], saved['spaces']
assert len(saved['projects']) == 2 and len(saved['sessions']) == 2
states = run('restart', [step('wait', seconds=1), step('spacesState'),
                         step('spaceSwitch', name='Personal'), step('spacesState'),
                         step('spaceCreate', name='Ideas', color='amber'), step('spacesState'), step('quit')])
assert states[0]['selectedSpace'] == 'Studio' and states[0]['selectedProject'] == 'Research', states
assert states[0]['visibleProjects'] == ['Research'], states
assert states[1]['selectedSpace'] == 'Personal' and states[1]['selectedProject'] == 'Studio', states
assert states[1]['visibleProjects'] == ['Studio'], states
assert 'Keep this Personal draft.' in states[1]['drafts'].values(), states
assert 'Keep this Work draft.' in states[1]['drafts'].values(), states
assert states[2]['selectedSpace'] == 'Ideas' and states[2]['selectedProject'] == '', states
new_project = root / 'NewApp'
new_project.mkdir()
empty = run('empty-restart', [step('wait', seconds=1), step('spacesState'),
                             step('open', path=str(new_project)), step('wait', seconds=.2), step('spacesState'), step('quit')])
assert empty[0]['selectedSpace'] == 'Ideas' and empty[0]['visibleProjects'] == [] and empty[0]['selectedProject'] == '', empty
assert empty[1]['selectedSpace'] == 'Ideas' and empty[1]['visibleProjects'] == ['NewApp'] and empty[1]['selectedProject'] == 'NewApp', empty
restored = run('new-project-restart', [step('wait', seconds=1), step('spacesState'), step('quit')])
assert restored[0]['selectedSpace'] == 'Ideas' and restored[0]['selectedProject'] == 'NewApp', restored
print('Spaces controls, project scoping, active work, drafts and restart checks passed. Screenshots and logs:', root)
