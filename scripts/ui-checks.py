#!/usr/bin/env python3
"""Run native regression suites serially and retain isolated fixtures and diagnostics.

Build the debug app first. No installed agent or provider account is needed.
"""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import uuid

repo = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--artifacts', type=Path, default=repo / 'build/ui-checks')
args = parser.parse_args()
artifacts = args.artifacts.resolve()
artifacts.mkdir(parents=True, exist_ok=True)
failed = []

for suite in ['welcome', 'followups', 'workflow', 'codex-style', 'smoke', 'recovery', 'project-tabs', 'spaces', 'space-content', 'navigation-qa', 'deep-workflows', 'projects', 'workbench', 'history-updates', 'browser']:
    directory = artifacts / suite
    directory.mkdir(exist_ok=True)
    environment = dict(os.environ, TMPDIR=str(directory), MARIKA_DEMO='1',
                       MARIKA_EDITOR_DEFAULTS_SUITE='app.marika.ui-checks.' + uuid.uuid4().hex)
    log_path = directory / 'suite.log'
    print(f'Running {suite}; diagnostics: {directory}', flush=True)
    with log_path.open('w') as log:
        process = subprocess.Popen([sys.executable, str(repo / f'scripts/ui-{suite}.py')], cwd=repo,
                                   env=environment, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            status = process.wait(timeout=300)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            status = -1
    if status:
        failed.append(suite)
        print(log_path.read_text()[-6000:], file=sys.stderr, flush=True)
    else:
        print(f'Passed {suite}', flush=True)

if failed:
    raise SystemExit('Native UI checks failed: ' + ', '.join(failed))
print(f'All native UI checks passed. Screenshots and logs: {artifacts}')
