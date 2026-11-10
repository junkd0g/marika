#!/usr/bin/env python3
"""Exercise ticket launch, progress, approvals, saved results, checks and acceptance."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-ticket-work-'))
data = root / 'data'; data.mkdir()
project = root / 'Product'; (project / 'Sources/Fixture').mkdir(parents=True); (project / 'Tests/FixtureTests').mkdir(parents=True)
(project / 'Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "Fixture", targets: [.target(name: "Fixture"), .testTarget(name: "FixtureTests", dependencies: ["Fixture"])])\n')
(project / 'Sources/Fixture/Value.swift').write_text('public let expected = 42\n')
(project / 'Tests/FixtureTests/ValueTests.swift').write_text('import Testing\n@testable import Fixture\n@Test func value() { #expect(expected == 42) }\n')
(project / 'README.md').write_text('# Product\n'); (project / '.gitignore').write_text('.build/\n.swiftpm/\n')
subprocess.run(['git', 'init', '-q', str(project)], check=True)
subprocess.run(['git', '-C', str(project), 'add', '.'], check=True)
subprocess.run(['git', '-C', str(project), '-c', 'user.name=QA', '-c', 'user.email=qa@example.invalid', 'commit', '-qm', 'Fixture'], check=True)
personal = '00000000-0000-0000-0000-000000000001'
pid, sid, ticket, note, second = [str(uuid.uuid4()).upper() for _ in range(5)]
date = '2026-11-09T12:00:00Z'
notes = [dict(id=nid, title=title, blocks=[dict(id=str(uuid.uuid4()), kind='Text', text=text, checked=False)],
              pinned=False, archived=False, createdAt=date, updatedAt=date)
         for nid, title, text in [(note, 'Design plan', 'Selected design context'), (second, 'Unselected note', 'Unselected context')]]
(data / 'workspace.json').write_text(json.dumps(dict(
    spaces=[dict(id=personal, name='Personal', notes=notes, tickets=[dict(id=ticket, key='PERSON-1', title='Improve the welcome screen',
        body='## Acceptance criteria\nShow the next setup step and keep the project context.', status='To Do', priority='High', kind='Feature',
        assignee='Jordan', projectID=pid, linkedNoteIDs=[note], archived=False, createdAt=date, updatedAt=date)])],
    projects=[dict(id=pid, path=str(project), name='Product', spaceID=personal, conversationSessionID=sid, layout=dict(showsInspector=False))],
    sessions=[dict(id=sid, projectID=pid, agent='codex', title='Project chat', mode='ask', createdAt=date, updatedAt=date)], selectedSpaceID=personal)))

def s(op, **kw): return dict(op=op, **kw)

def run(name, steps):
    script, log = root / (name + '.json'), root / (name + '.log')
    script.write_text(json.dumps(steps))
    with log.open('w') as out:
        result = subprocess.run([str(repo / '.build/debug/Marika')], cwd=repo,
            env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script), MARIKA_DEMO='1',
                     MARIKA_EDITOR_DEFAULTS_SUITE='app.marika.ticket-work.' + uuid.uuid4().hex),
            stdout=out, stderr=subprocess.STDOUT, timeout=180)
    assert result.returncode == 0 and '[driver] FAILED' not in log.read_text(), f'{log}\n{log.read_text()[-5000:]}'

def launch():
    return [s('clickMarker', name='space-ticket-start-work'), s('assertMarker', name='ticket-launch-form'),
            s('wait', seconds=.4), s('clickMarker', name='agent-launch-isolated'), s('clickMarker', name='ticket-launch-submit'),
            s('assertMarker', name='ticket-launch-form', present=False), s('assertMarker', name='ticket-work-view')]

run('work', [s('wait', seconds=1), s('agentsMock', seconds=600), s('size', width=1240, height=820), s('appearance', dark=True),
    s('clickMarker', name='space-open-tickets'), s('ticketWorkTest', phase='launchGuards'),
    s('clickMarker', name='space-ticket-' + ticket)] + launch() + [s('ticketWorkTest', phase='started'),
    s('shot', path=str(root / 'working.png'), sheet=True), s('ticketWorkTest', phase='approval'), s('wait', seconds=.2),
    s('shot', path=str(root / 'approval.png'), sheet=True), s('ticketWorkTest', phase='blocked'), s('wait', seconds=.2),
    s('shot', path=str(root / 'blocked.png'), sheet=True)] + launch() + [s('ticketWorkTest', phase='complete'),
    s('assertMarker', name='ticket-work-run-checks'),
    s('ticketWorkTest', phase='value', value=43), s('clickMarker', name='ticket-work-run-checks', scroll=True),
    s('ticketWorkTest', phase='checks', passed=False), s('shot', path=str(root / 'checks-failed.png'), sheet=True),
    s('ticketWorkTest', phase='value', value=42), s('clickMarker', name='ticket-work-run-checks', scroll=True),
    s('ticketWorkTest', phase='checks', passed=True), s('ticketWorkTest', phase='contextGuard'),
    s('shot', path=str(root / 'ready.png'), sheet=True), s('clickMarker', name='space-ticket-done'), s('quit')])
saved = json.loads((data / 'workspace.json').read_text())['spaces'][0]['tickets'][0]
assert saved['status'] == 'In Progress' and len(saved['work']) == 2 and not saved['work'][-1].get('acceptedAt'), saved
assert saved['work'][-1]['result']['verification']['succeeded'], saved
run('accept', [s('wait', seconds=1), s('agentsMock', seconds=600), s('size', width=1100, height=800),
    s('clickMarker', name='space-ticket-' + ticket), s('ticketWorkTest', phase='restored'),
    s('clickMarker', name='ticket-work-open-agent'), s('assertMarker', name='workspace-header'),
    s('assertMarker', name='task-results-ticket'), s('clickMarker', name='task-results-ticket'),
    s('assertMarker', name='space-ticket-editor'), s('clickMarker', name='ticket-work-accept', scroll=True),
    s('assertMarker', name='ticket-work-accepted'), s('ticketWorkTest', phase='accepted'),
    s('shot', path=str(root / 'accepted-dark.png'), sheet=True), s('appearance', dark=False),
    s('shot', path=str(root / 'accepted-light.png'), sheet=True), s('clickMarker', name='space-ticket-done'), s('quit')])
run('restart', [s('wait', seconds=1), s('agentsMock'), s('ticketWorkTest', phase='accepted'), s('quit')])
run('isolated-and-resume', [s('wait', seconds=1), s('agentsMock', seconds=600), s('ticketWorkTest', phase='isolated'),
    s('ticketWorkTest', phase='resume'), s('quit')])
resumed = json.loads((data / 'workspace.json').read_text())['spaces'][0]['tickets'][0]
assert resumed['status'] == 'In Progress' and not resumed['work'][-1].get('acceptedAt'), resumed
print('Ticket context, guarded launch, approval/blocker states, checks, result review, acceptance and restart passed. Diagnostics:', root)
