#!/usr/bin/env python3
"""Exercise design tokens/variants, preset persistence and metric charts using isolated native fixtures."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-workspace-six-'))
data, project = root / 'data', root / 'Copper'
data.mkdir(); project.mkdir(); (project / 'README.md').write_text('# Copper\nSample project\n')
pid, sid = [str(uuid.uuid4()) for _ in range(2)]
stamp = '2026-11-19T12:00:00Z'
(data / 'workspace.json').write_text(json.dumps(dict(projects=[dict(id=pid, name='Copper', path=str(project), conversationSessionID=sid)],
    sessions=[dict(id=sid, projectID=pid, agent='codex', title='Copper chat', mode='ask', createdAt=stamp, updatedAt=stamp)])))
def step(op, **kw): return dict(op=op, **kw)
def shot(name): return step('capture', path=str(root / (name + '.png')))
def run(name, steps):
    script, log = root / (name + '.json'), root / (name + '.log')
    script.write_text(json.dumps(steps))
    with log.open('w') as output:
        result = subprocess.run([str(repo / '.build/debug/Marika')], cwd=repo,
            env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script), MARIKA_DEMO='1'), stdout=output, stderr=subprocess.STDOUT, timeout=90)
    assert result.returncode == 0 and '[driver] FAILED' not in log.read_text(), str(log) + '\n' + log.read_text()[-5000:]
run('design', [step('wait', seconds=1), step('agentsMock'), step('size', width=1500, height=1000), step('appearance', dark=False),
    step('sixDesign'), step('wait', seconds=.5), shot('design-system-canvas'), step('sixDesign', system=True), step('wait', seconds=.3),
    step('assertMarker', name='design-system'), shot('design-system'), step('key', code=53), step('sixLayout', name='Design'),
    step('wait', seconds=.4), shot('design-layout'), step('sixLayout', name='Review'), step('wait', seconds=.3), shot('review-layout'), step('quit')])
run('metrics', [step('wait', seconds=1), step('agentsMock'), step('size', width=1500, height=1000), step('appearance', dark=True),
    step('sixMetrics'), step('wait', seconds=.4), step('assertMarker', name='container-metrics'), shot('container-metrics'), step('quit')])
workspace = json.loads((data / 'workspace.json').read_text())
assert any(p.get('viewPresets') for p in workspace['projects']), 'Saved layouts did not persist'
print('Design system, saved layouts and container metrics passed. Screenshots and logs:', root)
