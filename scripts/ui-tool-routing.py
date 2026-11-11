#!/usr/bin/env python3
"""Check tool routing and caller isolation in the native app without provider requests."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-tool-routing-'))
data = root / 'data'
data.mkdir()
projects, sessions = [], []
for name in ['Studio', 'Other']:
    folder = root / name
    folder.mkdir()
    (folder / 'README.md').write_text('# Routing fixture\n')
    pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
    projects.append(dict(id=pid, path=str(folder), name=name, conversationSessionID=sid))
    sessions.append(dict(id=sid, projectID=pid, agent='codex', title=name, mode='ask',
                         createdAt='2026-11-11T12:00:00Z', updatedAt='2026-11-11T12:00:00Z'))
(data / 'workspace.json').write_text(json.dumps(dict(projects=projects, sessions=sessions)))
script = root / 'steps.json'
script.write_text(json.dumps([dict(op='wait', seconds=1), dict(op='agentsMock'),
                              dict(op='toolRoutingTest'), dict(op='quit')]))
log = root / 'run.log'
with log.open('w') as output:
    result = subprocess.run([str(repo / '.build/debug/Marika')], cwd=repo,
                            env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script), MARIKA_DEMO='1'),
                            stdout=output, stderr=subprocess.STDOUT, timeout=60)
text = log.read_text()
assert result.returncode == 0 and '[driver] FAILED' not in text, f'{log}\n{text[-4000:]}'
print('Tool routing and caller-isolation checks passed. Logs:', root)
