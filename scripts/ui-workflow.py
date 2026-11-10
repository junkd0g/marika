#!/usr/bin/env python3
"""Exercise task completion, real fixture tests, preview recovery and adjacent logs."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-workflow-'))
data, project = root / 'data', root / 'Preview Studio'
data.mkdir()
(project / 'Tests/FixtureTests').mkdir(parents=True)
(project / 'Sources/Fixture').mkdir(parents=True)
(project / 'index.html').write_text('<!doctype html><title>Workflow Preview</title><h1>Updated preview</h1>')
(project / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Fixture", targets: [.target(name: "Fixture"), .testTarget(name: "FixtureTests", dependencies: ["Fixture"])])
''')
(project / 'Sources/Fixture/Value.swift').write_text('public let expected = 42\n')
(project / 'Tests/FixtureTests/ValueTests.swift').write_text('import Testing\n@testable import Fixture\n@Test func value() { #expect(expected == 42) }\n')
conflict = socket.socket()
conflict.bind(('127.0.0.1', 0))
conflict.listen()
occupied = conflict.getsockname()[1]
with socket.socket() as available:
    available.bind(('127.0.0.1', 0))
    port = available.getsockname()[1]
pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
(data / 'workspace.json').write_text(json.dumps(dict(projects=[dict(id=pid, path=str(project), name='Preview Studio',
    conversationSessionID=sid, layout=dict(showsInspector=False))], sessions=[dict(id=sid, projectID=pid,
    agent='codex', title='Finish the preview', mode='ask', createdAt='2026-11-09T12:00:00Z', updatedAt='2026-11-09T12:00:00Z')])))


def s(op, **kw):
    return dict(op=op, **kw)


steps = [s('wait', seconds=1), s('agentsMock'), s('size', width=1100, height=800),
    s('taskCompletionFixture'), s('wait', seconds=.5),
    s('assertMarker', name='task-results'), s('assertMarker', name='task-review-work', present=False),
    s('taskCompletionCheck', verified=False),
    s('shot', path=str(root / 'completion-card.png')),
    s('size', width=900, height=600), s('appearance', dark=False), s('wait', seconds=.3),
    s('shot', path=str(root / 'results-compact-light.png')), s('appearance', dark=True),
    s('wait', seconds=.3), s('shot', path=str(root / 'results-compact-dark.png')),
    s('size', width=1100, height=800), s('clickMarker', name='task-results-checks'),
    s('taskVerificationWait'), s('taskCompletionCheck', verified=True, inline=True),
    s('verificationStatus', status='current', succeeded=True),
    s('shot', path=str(root / 'completion-checks.png')),
    s('clickMarker', name='task-results-close-checks'), s('wait', seconds=.3),
    s('codeOpen', path='Sources/Fixture/Value.swift'), s('wait', seconds=.4),
    s('codeInsert', text='public let expected = 43\n', replaceAll=True),
    s('shortcut', key='1', exactMenu=True), s('wait', seconds=.3),
    s('clickMarker', name='task-results-checks'), s('verificationStatus', status='outdated', succeeded=True),
    s('shot', path=str(root / 'checks-unsaved.png')),
    s('clickMarker', name='task-results-close-checks'), s('wait', seconds=.3),
    s('shortcut', key='2', exactMenu=True), s('wait', seconds=.3),
    s('codeInsert', text='public let expected = 42\n', replaceAll=True),
    s('shortcut', key='1', exactMenu=True), s('wait', seconds=.3),
    s('clickMarker', name='task-results-checks'), s('verificationStatus', status='current', succeeded=True),

    s('verificationEdit', path='Sources/Fixture/Value.swift', text='public let expected = 43\n'),
    s('verificationStatus', status='outdated', succeeded=True),
    s('shot', path=str(root / 'checks-outdated.png')),
    s('clickMarker', name='task-results-run-checks'), s('taskVerificationWait'),
    s('verificationStatus', status='current', succeeded=False),
    s('shot', path=str(root / 'checks-failed.png')),
    s('verificationEdit', path='Sources/Fixture/Value.swift', text='public let expected = 42\n'),
    s('verificationStatus', status='outdated', succeeded=False),
    s('clickMarker', name='task-results-run-checks'), s('taskVerificationWait'),
    s('verificationStatus', status='current', succeeded=True),
    s('verificationEdit', path='Tests/FixtureTests/ValueTests.swift', text='import Testing\n@testable import Fixture\n@Test func value() async throws { try await Task.sleep(for: .seconds(2)); #expect(expected == 42) }\n'),
    s('clickMarker', name='task-results-run-checks'), s('wait', seconds=1),
    s('verificationEdit', path='Sources/Fixture/Value.swift', text='public let expected = 43\n'),
    s('taskVerificationWait'), s('verificationStatus', status='outdated', incomplete=True),
    s('verificationEdit', path='Tests/FixtureTests/ValueTests.swift', text='import Testing\n@testable import Fixture\n@Test func value() { #expect(expected == 42) }\n'),
    s('verificationEdit', path='Sources/Fixture/Value.swift', text='public let expected = 42\n'),
    s('clickMarker', name='task-results-run-checks'), s('taskVerificationWait'),
    s('verificationStatus', status='current', succeeded=True),
    s('clickMarker', name='task-results-changes'), s('wait', seconds=.3), s('projectTabsState'),
    s('shortcut', key='1', exactMenu=True), s('wait', seconds=.3),
    s('clickMarker', name='task-results-checks'), s('wait', seconds=.3),
    s('previewConfig', command=f'/usr/bin/python3 -m http.server {occupied} --bind 127.0.0.1', address=f'http://127.0.0.1:{occupied}'),
    s('clickMarker', name='task-results-preview'), s('wait', seconds=.4), s('previewCheck', state='failed', errorContains='already in use'),
    s('previewConfig', command=f'/usr/bin/python3 -m http.server {port} --bind 127.0.0.1', address=f'http://127.0.0.1:{port}'),
    s('clickMarker', name='task-results-preview'), s('previewWait'), s('browserWait'), s('browserCheck', title='Workflow Preview'),
    s('clickMarker', name='preview-toggle-logs'), s('shot', path=str(root / 'preview-with-logs.png')),
    s('previewStop'), s('previewCheck', state='stopped'), s('quit')]
script, log = root / 'steps.json', root / 'driver.log'
script.write_text(json.dumps(steps))
try:
    with log.open('w') as out:
        result = subprocess.run([str(repo / '.build/debug/Marika')], cwd=repo,
            env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script), MARIKA_DEMO='1',
                     MARIKA_EDITOR_DEFAULTS_SUITE='app.marika.workflow.' + uuid.uuid4().hex),
            stdout=out, stderr=subprocess.STDOUT, timeout=180)
    assert result.returncode == 0 and '[driver] FAILED' not in log.read_text(), f'{log}\n{log.read_text()[-5000:]}'
    states = [json.loads(line.split('[driver] projectTabs ', 1)[1]) for line in log.read_text().splitlines() if '[driver] projectTabs ' in line]
    assert states[0]['selected'] == 'Changes', states
    restart_steps = [s('wait', seconds=1), s('agentsMock'), s('shortcut', key='1', exactMenu=True),
        s('wait', seconds=.3), s('verificationStatus', status='current', succeeded=True),
        s('verificationEdit', path='Sources/Fixture/Value.swift', text='public let expected = 43\n'),
        s('verificationStatus', status='outdated', succeeded=True), s('newSession'), s('wait', seconds=.3),
        s('taskCompletionFixture', changes=False), s('wait', seconds=.3),
        s('assertMarker', name='task-results', present=False), s('quit')]
    restart_script, restart_log = root / 'restart.json', root / 'restart.log'
    restart_script.write_text(json.dumps(restart_steps))
    with restart_log.open('w') as out:
        restarted = subprocess.run([str(repo / '.build/debug/Marika')], cwd=repo,
            env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(restart_script), MARIKA_DEMO='1',
                     MARIKA_EDITOR_DEFAULTS_SUITE='app.marika.workflow.' + uuid.uuid4().hex),
            stdout=out, stderr=subprocess.STDOUT, timeout=60)
    assert restarted.returncode == 0 and '[driver] FAILED' not in restart_log.read_text(), f'{restart_log}\n{restart_log.read_text()[-5000:]}'
    print('Completion, current/outdated/failed checks, restart freshness, preview recovery and logs passed. Diagnostics:', root)
finally:
    conflict.close()
