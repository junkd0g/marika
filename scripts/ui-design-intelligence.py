#!/usr/bin/env python3
"""Check semantic Design links with the real Go language server and inspect health UI."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-design-intelligence-'))
data = root / 'data'; data.mkdir()
project = root / 'Project'; project.mkdir()
pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
date = '2026-11-11T12:00:00Z'
(data / 'workspace.json').write_text(json.dumps(dict(projects=[dict(id=pid, name='Design intelligence', path=str(project), conversationSessionID=sid, layout=dict(showsInspector=False))],
    sessions=[dict(id=sid, projectID=pid, agent='codex', title='Project chat', mode='ask', createdAt=date, updatedAt=date)])))
steps = [dict(op='wait', seconds=1), dict(op='size', width=1440, height=900), dict(op='appearance', dark=False),
    dict(op='designIntelligenceTest'), dict(op='wait', seconds=1), dict(op='capture', path=str(root / 'health-light.png')),
    dict(op='appearance', dark=True), dict(op='wait', seconds=.4), dict(op='capture', path=str(root / 'health-dark.png')),
    dict(op='clickMarker', name='design-health-show-missingFile'), dict(op='wait', seconds=.3), dict(op='designIntelligenceSelection'),
    dict(op='capture', path=str(root / 'health-selection.png')), dict(op='clickMarker', name='design-manage-links'), dict(op='wait', seconds=.3),
    dict(op='capture', path=str(root / 'symbol-links.png')),
    dict(op='clickMarker', name='design-link-kind', fraction=.375),
    dict(op='spaceContentText', name='design-link-target', text='main.go'),
    dict(op='clickMarker', name='design-find-declarations'), dict(op='wait', seconds=.8),
    dict(op='capture', path=str(root / 'symbol-picker.png')), dict(op='clickMarker', name='design-symbol-row'),
    dict(op='clickMarker', name='design-link-add'), dict(op='key', code=53),
    dict(op='designIntelligenceSelection', added=True),
    dict(op='wait', seconds=.5), dict(op='clickMarker', name='design-health-toggle'), dict(op='wait', seconds=.8),
    dict(op='assertMarker', name='design-health-panel'), dict(op='size', width=900, height=700), dict(op='wait', seconds=.4),
    dict(op='capture', path=str(root / 'health-compact.png')), dict(op='key', code=53), dict(op='quit')]
script = root / 'steps.json'; script.write_text(json.dumps(steps))
log = root / 'run.log'
with log.open('w') as output:
    result = subprocess.run([str(repo / '.build/debug/Marika')], cwd=repo,
        env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script), MARIKA_DEMO='1'),
        stdout=output, stderr=subprocess.STDOUT, timeout=120)
text = log.read_text()
assert result.returncode == 0 and '[driver] FAILED' not in text, f'{log}\n{text[-4000:]}'
saved = json.loads((data / 'workspace.json').read_text())
assert any(link.get('symbolIdentity') for p in saved['projects'] for node in p['design']['nodes'] for link in node.get('links', []))
print('Design semantic links and health checks passed. Screenshots and logs:', root)
