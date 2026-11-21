#!/usr/bin/env python3
"""Exercise Playwright evidence and project shutdown through an isolated Marika workspace."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
playwright = Path(sys.argv[1]).absolute()
root = Path(tempfile.mkdtemp(prefix='marika-workspace-evidence-'))
print('Fixture:', root, flush=True)
data = root / 'workspace'
data.mkdir()
directories = (root / 'Alpha', root / 'Beta')
ids = [(str(uuid.uuid4()), str(uuid.uuid4())) for _ in directories]
stamp = '2026-11-21T12:00:00Z'
projects, sessions = [], []
for directory, (pid, sid) in zip(directories, ids):
    directory.mkdir()
    projects.append(dict(id=pid, path=str(directory), name=directory.name, conversationSessionID=sid))
    sessions.append(dict(id=sid, projectID=pid, agent='codex', title='Fixture', mode='ask', createdAt=stamp, updatedAt=stamp))
(data / 'workspace.json').write_text(json.dumps(dict(projects=projects, sessions=sessions)))


def run(name, action):
    log = root / (name + '.log')
    driver = root / (name + '.json')
    driver.write_text(json.dumps([dict(op='wait', seconds=1), action, dict(op='quit')]))
    with log.open('w') as output:
        subprocess.run([str(repo / '.build/debug/Marika')],
                       env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(driver)),
                       stdout=output, stderr=subprocess.STDOUT, check=True, timeout=90)
    assert '[driver] FAILED' not in log.read_text(), log


run('export', dict(op='qaPrepareCIFixture', directory=str(root)))
test_env = dict(os.environ, PLAYWRIGHT_JSON_OUTPUT_NAME=str(root / 'report.json'))
(root / 'playwright.config.cjs').write_text('''
module.exports = {
  projects: [{name: 'chromium-fixture', use: {browserName: 'chromium', trace: 'retain-on-failure'}}],
  timeout: 5000,
  reporter: 'json'
};
''')
# Resolve @playwright/test for the actual Marika-exported test.
(root / 'node_modules').symlink_to(playwright.parent.parent)
result = subprocess.run([str(playwright), 'test'], cwd=root, env=test_env, timeout=60)
assert result.returncode == 1, 'Expected the missing button to fail'
trace = next((root / 'test-results').rglob('trace.zip'))
run('import', dict(op='qaImportCIFixture', report=str(root / 'report.json'), trace=str(trace)))
run('incident', dict(op='incidentAndShutdownTest'))
print('Playwright CI failure, trace, bug link, Kubernetes incident, and isolated project shutdown passed.')
