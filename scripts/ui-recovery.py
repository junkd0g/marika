#!/usr/bin/env python3
"""Check recovery and failed-save retries in the native app, without provider requests."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import uuid

repo = Path(__file__).resolve().parents[1]
binary = repo / '.build/debug/Marika'
root = Path(tempfile.mkdtemp(prefix='marika-ui-recovery-'))
project = root / 'project'
project.mkdir()


def step(op, **values):
    return dict(op=op, **values)


def fixture(name, recovered_draft=False):
    data = root / name
    data.mkdir()
    pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
    layout = {'panel': 'Code' if recovered_draft else 'Conversation'}
    if recovered_draft:
        layout.update(files=[{'path': 'missing.swift', 'draft': '// recovered unsaved work', 'baseText': '// old file', 'line': 1, 'column': 1}], selectedFile='missing.swift')
    workspace = {'projects': [{'id': pid, 'path': str(project), 'name': 'Recovery check', 'layout': layout}],
                 'sessions': [{'id': sid, 'projectID': pid, 'agent': 'codex', 'title': 'Recovery test',
                               'createdAt': '2026-11-05T12:00:00Z', 'updatedAt': '2026-11-05T12:00:00Z', 'mode': 'ask'}]}
    (data / 'workspace.json').write_text(json.dumps(workspace))
    return data, sid


def records(lines, kind):
    marker = '[driver] ' + kind + ' '
    return [json.loads(line.split(marker, 1)[1]) for line in lines if marker in line]


def run(name, data, steps, on_storage=None):
    script = root / (name + '.json')
    script.write_text(json.dumps(steps))
    log_path = root / (name + '.log')
    lines = []
    with log_path.open('w') as log:
        process = subprocess.Popen([str(binary)], env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script)),
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        watchdog = threading.Timer(45, process.kill)
        watchdog.start()
        try:
            for line in process.stdout:
                log.write(line)
                log.flush()
                lines.append(line)
                if on_storage and '[driver] storage ' in line:
                    on_storage(json.loads(line.split('[driver] storage ', 1)[1]))
            process.wait(timeout=10)
        finally:
            watchdog.cancel()
            if process.poll() is None:
                process.kill()
                process.wait()
    assert process.returncode == 0 and not any('[driver] FAILED' in line for line in lines), log_path
    return lines


data, _ = fixture('draft', recovered_draft=True)
lines = run('draft', data, [step('wait', seconds=1), step('agentsMock', seconds=.1), step('layoutState'),
                          step('checkpoint'), step('shot', path=str(root / 'recovered-draft.png')), step('quit')])
layout = records(lines, 'layout')[0]
assert layout['draft'] == '// recovered unsaved work' and layout['conflict'], layout
saved = json.loads((data / 'workspace.json').read_text())
assert saved['projects'][0]['layout']['files'][0]['draft'] == '// recovered unsaved work'
assert not (project / 'missing.swift').exists()

backup_data, _ = fixture('backup', recovered_draft=True)
(backup_data / 'workspace.json.bak').write_bytes((backup_data / 'workspace.json').read_bytes())
(backup_data / 'workspace.json').write_text('damaged original')
lines = run('backup', backup_data, [step('wait', seconds=1), step('storageState'), step('layoutState'),
                                  step('shot', path=str(root / 'backup-recovery.png')), step('quit')])
state = records(lines, 'storage')[0]
assert state['recovery'] and not state['loadFailed'] and not state['error'], state
assert records(lines, 'layout')[0]['draft'] == '// recovered unsaved work'
assert any(path.read_text() == 'damaged original' for path in backup_data.glob('workspace.corrupt-*.json'))

broken, _ = fixture('unrecoverable')
(broken / 'workspace.json').write_text('keep this damaged file')
lines = run('unrecoverable', broken, [step('wait', seconds=.7), step('storageState'),
                                    step('shot', path=str(root / 'unrecoverable.png')), step('quit')])
state = records(lines, 'storage')[0]
assert state['loadFailed'] and state['error'], state
assert (broken / 'workspace.json').read_text() == 'keep this damaged file'

retry_data, sid = fixture('retry')
transcripts = retry_data / 'transcripts'
held = retry_data / 'transcripts-held'


def block_and_repair(state):
    if state['label'] == 'block':
        transcripts.rename(held)
        transcripts.write_text('temporary write failure')
    elif state['label'] == 'repair':
        assert state['error'], state
        transcripts.unlink()
        held.rename(transcripts)


lines = run('retry', retry_data,
            [step('wait', seconds=1), step('agentsMock', seconds=.1), step('send', text='first mock turn'),
             step('wait', seconds=.3), step('checkpoint'), step('storageState', label='block'), step('wait', seconds=1),
             step('send', text='second mock turn'), step('wait', seconds=.3), step('checkpoint'),
             step('storageState', label='repair'), step('shot', path=str(root / 'failed-save.png')), step('wait', seconds=1),
             step('storageRetry'), step('storageState', label='retried'), step('quit')], block_and_repair)
assert not records(lines, 'storage')[-1]['error'], records(lines, 'storage')[-1]
assert 'second mock turn' in (transcripts / (sid.upper() + '.json')).read_text()
print('Native recovery checks passed. Screenshots and logs:', root)
