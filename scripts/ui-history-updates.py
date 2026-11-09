#!/usr/bin/env python3
"""Test local cross-project message search and update UI with isolated app data."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-history-updates-'))
data = root / 'data'; data.mkdir()
projects, sessions = [], []
personal, work = '00000000-0000-0000-0000-000000000001', str(uuid.uuid4())
for name, agent in [('Studio', 'codex'), ('Research', 'claude')]:
    folder = root / name; folder.mkdir()
    project_id, session_id = str(uuid.uuid4()), str(uuid.uuid4())
    projects.append(dict(id=project_id, path=str(folder), name=name, conversationSessionID=session_id, spaceID=personal if name == 'Studio' else work,
                         layout=dict(showsInspector=False)))
    sessions.append(dict(id=session_id, projectID=project_id, agent=agent, title=name + ' conversation', mode='ask',
                         createdAt='2026-11-07T13:00:00Z', updatedAt='2026-11-07T13:00:00Z'))
(data / 'workspace.json').write_text(json.dumps(dict(projects=projects, sessions=sessions, selectedSpaceID=personal,
    spaces=[dict(id=personal, name='Personal', color='blue'), dict(id=work, name='Work', color='teal')])))
steps = [dict(op='wait', seconds=1), dict(op='agentsMock', seconds=.1), dict(op='appearance', dark=True),
         dict(op='size', width=1100, height=760), dict(op='wait', seconds=.3),
         dict(op='chatHistoryUpdatesTest', directory=str(root), liveUpdates=os.environ.get('MARIKA_LIVE_UPDATES') == '1'), dict(op='quit')]
# Bootstrap selects the most recent project; the test deliberately searches the other one.
(root / 'steps.json').write_text(json.dumps(steps))
log = root / 'driver.log'
with log.open('w') as output:
    result = subprocess.run([str(repo / '.build/debug/Marika')],
        env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(root / 'steps.json')),
        stdout=output, stderr=subprocess.STDOUT, timeout=75)
lines = log.read_text()
assert result.returncode == 0 and '[driver] FAILED' not in lines, log
assert 'Chat history and updates passed:' in lines, log
print('Chat history and updates UI checks passed. Screenshots and logs:', root)
