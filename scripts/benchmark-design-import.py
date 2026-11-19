#!/usr/bin/env python3
"""Opt-in live CLI import, with a local rendered reference and exported measurements."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--agent', choices=['claude', 'codex'], default='claude')
parser.add_argument('--source', choices=['index.html', 'Screen.swift', 'Screen.kt', 'App.tsx', 'Screen.vue'], default='index.html')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-import-benchmark-'))
project, data = root / 'Benchmark', root / 'data'
shutil.copytree(repo / 'Tests/Fixtures/DesignImport', project); data.mkdir()
pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
stamp = '2026-11-19T12:00:00Z'
(data / 'workspace.json').write_text(json.dumps(dict(projects=[dict(id=pid,path=str(project),name='Import benchmark',conversationSessionID=sid)],
    sessions=[dict(id=sid,projectID=pid,agent=args.agent,title='Benchmark',mode='ask',createdAt=stamp,updatedAt=stamp)])))
def s(op, **kw): return dict(op=op, **kw)
steps = [s('wait', seconds=1), s('size', width=1500, height=1000), s('appearance', dark=False),
    s('browserOpen', url=(project / 'index.html').as_uri()), s('browserWait'), s('wait', seconds=.4),
    s('capture', path=str(root / 'browser.png')), s('sixImportReference', source=args.source, agent=args.agent),
    s('designImportWait', status='ready'), s('clickMarker', name='design-import-toggle'), s('wait', seconds=.4),
    s('capture', path=str(root / 'review.png')), s('sixImportExport', directory=str(root)), s('quit')]
(root / 'steps.json').write_text(json.dumps(steps))
with (root / 'driver.log').open('w') as log:
    result = subprocess.run([str(repo / '.build/debug/Marika')], cwd=repo,
        env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(root / 'steps.json')),
        stdout=log, stderr=subprocess.STDOUT, timeout=240)
print('Live benchmark output:', root)
if result.returncode or '[driver] FAILED' in (root / 'driver.log').read_text():
    raise SystemExit('Benchmark failed; inspect driver.log for provider or validation details.')
print((root / 'measurements.json').read_text())
