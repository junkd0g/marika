#!/usr/bin/env python3
"""Check project tool tabs, closing with active work, and restoration using isolated data."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-project-tabs-'))
data = root / 'data'
data.mkdir()
projects, sessions = [], []
for index, name in enumerate(['Studio', 'Research']):
    folder = root / name
    folder.mkdir()
    (folder / 'README.md').write_text('# ' + name + '\n')
    pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
    projects.append(dict(id=pid, path=str(folder), name=name, conversationSessionID=sid, layout=dict(showsInspector=False)))
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
    return lines


run('controls', [step('wait', seconds=1), step('projectTabsTest', directory=str(root)), step('quit')])
lines = run('restart', [step('wait', seconds=1), step('projectTabsState'),
                        step('projectClick', name='Research'), step('wait', seconds=.2), step('projectTabsState'),
                        step('projectClick', name='Studio'), step('wait', seconds=.2), step('projectTabsState'),
                        step('shortcut', key='2'), step('wait', seconds=.5), step('codeState'), step('state'), step('quit')])
states = [json.loads(line.split('[driver] projectTabs ', 1)[1]) for line in lines if '[driver] projectTabs ' in line]
assert [(state['project'], state['selected'], state['tabs']) for state in states] == [
    ('Studio', 'Stats', ['Conversation', 'Code', 'Stats']),
    ('Research', 'Browser', ['Conversation', 'Browser']),
    ('Studio', 'Stats', ['Conversation', 'Code', 'Stats'])], states
assert all(state['sessions'] == 2 and state['split'] == '' for state in states), states
editor = next(json.loads(line.split('[driver] code ', 1)[1]) for line in lines if '[driver] code ' in line)
chat = next(json.loads(line.split('[driver] state ', 1)[1]) for line in lines if '[driver] state ' in line)
assert editor['path'] == 'README.md' and editor['modified'], editor
assert chat['draft'] == 'Keep this chat draft when closing tools.', chat
print('Project tabs, native closing, active work, drafts and restart checks passed. Screenshots and logs:', root)
