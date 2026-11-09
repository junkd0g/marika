#!/usr/bin/env python3
"""Check first-run setup, provider selection and restart recovery with synthetic statuses."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-welcome-'))
data = root / 'data'
data.mkdir()
project = root / 'Welcome Demo'
project.mkdir()
(project / 'README.md').write_text('# Welcome Demo\n\nA temporary project for setup checks.\n')


def step(op, **values):
    return dict(op=op, **values)


def run(name, steps):
    script, log = root / (name + '.json'), root / (name + '.log')
    script.write_text(json.dumps(steps))
    with log.open('w') as output:
        result = subprocess.run([str(repo / '.build/debug/Marika')], cwd=repo,
                                env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DEMO='1',
                                         MARIKA_EDITOR_DEFAULTS_SUITE='app.marika.welcome-tests.' + uuid.uuid4().hex,
                                         MARIKA_DRIVER=str(script)), stdout=output, stderr=subprocess.STDOUT, timeout=60)
    lines = log.read_text().splitlines()
    assert result.returncode == 0 and not any('[driver] FAILED' in line for line in lines), log
    return [json.loads(line.split('[driver] welcome ', 1)[1]) for line in lines if '[driver] welcome ' in line]


states = run('setup', [step('wait', seconds=.5), step('welcomeStatus', claude='checking', codex='checking'),
    step('welcomeState'), step('welcomeStatus'), step('welcomeState'),
    step('size', width=900, height=600), step('appearance', dark=True), step('wait', seconds=.2),
    step('shot', path=str(root / 'missing-dark-compact.png')),
    step('welcomeAgent', agent='codex'), step('welcomeStatus', codex='signedOut'), step('welcomeState'),
    step('wait', seconds=.2), step('shot', path=str(root / 'signed-out.png')),
    step('welcomeStatus', codex='unavailable'), step('wait', seconds=.2), step('shot', path=str(root / 'check-failed.png')),
    step('welcomeStatus', codex='ready'), step('welcomeState'), step('welcomeFinish', succeeds=False),
    step('open', path=str(project)), step('wait', seconds=.2), step('welcomeState'),
    step('appearance', dark=False), step('wait', seconds=.2), step('shot', path=str(root / 'ready-light-compact.png')),
    step('size', width=1240, height=820), step('wait', seconds=.2), step('shot', path=str(root / 'ready-light-wide.png')),
    step('appearance', dark=True), step('wait', seconds=.2), step('shot', path=str(root / 'ready-dark-wide.png')), step('quit')])
assert [state['completedSteps'] for state in states] == [0, 0, 1, 2, 3], states
assert all(state['shown'] and not state['completed'] for state in states), states
assert states[-1]['ready'] and states[-1]['agent'] == 'codex', states

states = run('restart', [step('wait', seconds=.5), step('welcomeStatus', codex='ready'), step('welcomeState'),
    step('welcomeFinish'), step('welcomeState'), step('draft', text='Keep this unsent setup draft.'),
    step('welcomeShow'), step('welcomeAgent', agent='claude'), step('welcomeStatus', claude='ready'),
    step('welcomeFinish'), step('welcomeState'), step('state'), step('quit')])
assert states[0]['shown'] and states[0]['ready'] and not states[0]['completed'], states
assert states[1]['completed'] and not states[1]['shown'] and states[1]['sessionAgent'] == 'codex', states
assert states[2]['completed'] and not states[2]['shown'] and states[2]['sessionAgent'] == 'claude', states
saved = json.loads((data / 'workspace.json').read_text())
assert saved['sessions'][0]['draft']['text'] == 'Keep this unsent setup draft.', saved

states = run('explore', [step('wait', seconds=.5), step('welcomeState'), step('welcomeStatus'),
    step('welcomeShow'), step('welcomeFinish', succeeds=False), step('welcomeFinish', explore=True),
    step('welcomeState'), step('quit')])
assert not states[0]['shown'] and states[0]['completed'], states
assert not states[-1]['shown'] and states[-1]['completed'] and not states[-1]['ready'], states
saved = json.loads((data / 'workspace.json').read_text())
assert saved['projects'][0]['layout']['panel'] == 'Code', saved
print('Welcome setup, provider selection, drafts, restart restoration and editor access passed. Diagnostics:', root)
