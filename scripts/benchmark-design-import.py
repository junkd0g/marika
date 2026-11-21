#!/usr/bin/env python3
"""Render framework-specific references and optionally measure a live agent import."""
import argparse
from contextlib import contextmanager
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from threading import Thread
import uuid

LABELS = {
    'index.html': ['Welcome back', 'Your workspace is ready.', 'Continue'],
    'App.tsx': ['Release checklist', '3 checks passed · 1 pending', 'Open release'],
    'Screen.vue': ['Service status', 'API and worker are healthy.', 'View services'],
    'Screen.swift': ['Project settings', 'Configure your workspace.', 'Save preferences'],
    'Screen.kt': ['Build complete', 'Artifacts are ready to review.', 'View artifacts'],
}
SOURCES = list(LABELS)
REPO = Path(__file__).resolve().parents[1]
FIXTURES = REPO / 'Tests/Fixtures/DesignImport'


@contextmanager
def preview(folder):
    class Handler(SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

    with ThreadingHTTPServer(('127.0.0.1', 0), partial(Handler, directory=folder)) as server:
        thread = Thread(target=server.serve_forever)
        thread.start()
        try:
            yield f'http://127.0.0.1:{server.server_port}/'
        finally:
            server.shutdown()
            thread.join()


def reference(source, project, root):
    """Return the reference PNG or a directory containing the compiled web app."""
    if source == 'index.html':
        return project
    if source == 'Screen.swift':
        destination = root / 'SwiftUI-reference.png'
        binary = root / 'swiftui-reference'
        subprocess.run(['swiftc', str(FIXTURES / 'render/SwiftUIReference.swift'), str(project / source),
                        '-o', str(binary)], check=True)
        subprocess.run([str(binary), str(destination)], check=True)
        return destination
    if source == 'Screen.kt':
        destination = root / 'Compose-reference.png'
        renderer = root / 'compose-renderer'
        sources = renderer / 'src/main/kotlin'
        sources.mkdir(parents=True)
        shutil.copy(FIXTURES / 'render/build.gradle.kts', renderer)
        shutil.copy(FIXTURES / 'render/ComposeReference.kt', sources)
        shutil.copy(project / source, sources)
        subprocess.run([os.environ.get('MARIKA_BENCHMARK_GRADLE', 'gradle'), '--no-daemon', 'run',
                        '-PreferencePath=' + str(destination)], cwd=renderer, check=True, timeout=600)
        return destination
    web = root / 'web-renderer'
    web.mkdir()
    shutil.copy(project / source, web)
    dependencies = {'vite': '7.1.2'}
    if source == 'App.tsx':
        dependencies.update({'react': '19.1.1', 'react-dom': '19.1.1'})
        entry = """import React from 'react';
import { createRoot } from 'react-dom/client';
import Screen from './App.tsx';
createRoot(document.getElementById('app')).render(<Screen />);
"""
    else:
        dependencies.update({'vue': '3.5.18', '@vitejs/plugin-vue': '6.0.1'})
        (web / 'vite.config.mjs').write_text("import vue from '@vitejs/plugin-vue'; export default { plugins: [vue()] };\n")
        entry = """import { createApp } from 'vue';
import Screen from './Screen.vue';
createApp(Screen).mount('#app');
"""
    (web / 'main.tsx').write_text(entry)
    (web / 'package.json').write_text(json.dumps({'private': True, 'type': 'module', 'dependencies': dependencies}))
    (web / 'index.html').write_text("""<!doctype html><meta charset="utf-8"><title>Design import fixture</title>
<style>body{margin:0;font:16px -apple-system,sans-serif;background:#f4f4f8;color:#202020}</style>
<div id="app"></div><script type="module" src="/main.tsx"></script>
""")
    subprocess.run(['npm', 'install', '--no-audit', '--no-fund'], cwd=web, check=True, timeout=180)
    subprocess.run(['npm', 'exec', '--', 'vite', 'build'], cwd=web, check=True, timeout=90)
    return web / 'dist'


def source_checks(root, project, source):
    proposal = json.loads((root / 'proposal.json').read_text())
    nodes = proposal['document']['nodes']
    lines = (project / source).read_text().splitlines()
    labels = LABELS[source]
    missing, wrong_line = [], []
    for label in labels:
        matching = [node for node in nodes if node.get('text', '').strip() == label]
        if not matching:
            missing.append(label)
            continue
        links = [link for node in matching for link in node.get('links', [])]
        if not any(link.get('target') == source and isinstance(link.get('line'), int)
                   and 1 <= link['line'] <= len(lines) and label in lines[link['line'] - 1]
                   for link in links):
            wrong_line.append(label)
    return {'fixtureLabels': len(labels), 'linkedToExpectedLine': len(labels) - len(missing) - len(wrong_line),
            'missingFixtureLabels': missing, 'labelsWithMissingOrIncorrectLine': wrong_line}


def run_fixture(source, args, root):
    project, data = root / 'Benchmark', root / 'data'
    project.mkdir(parents=True)
    data.mkdir()
    shutil.copy(FIXTURES / source, project)
    rendered = reference(source, project, root)
    if args.references_only and rendered.is_file():
        return {'source': source, 'reference': str(rendered)}
    pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
    stamp = '2026-11-19T12:00:00Z'
    (data / 'workspace.json').write_text(json.dumps(dict(
        projects=[dict(id=pid, path=str(project), name='Import benchmark', conversationSessionID=sid)],
        sessions=[dict(id=sid, projectID=pid, agent=args.agent, title='Benchmark', mode='ask',
                       createdAt=stamp, updatedAt=stamp)])))

    def step(op, **kw):
        return dict(op=op, **kw)

    def run(address=None):
        steps = [step('wait', seconds=1), step('size', width=1500, height=1000), step('appearance', dark=False)]
        if address:
            steps += [step('browserOpen', url=address), step('browserWait'), step('wait', seconds=.4)]
        if args.references_only:
            steps.append(step('sixCaptureImportReference', path=str(root / 'reference.png')))
        else:
            steps += [step('sixImportReference', source=source, agent=args.agent, model=args.model,
                           **({'screenshot': str(rendered)} if rendered.is_file() else {})),
                      step('designImportWait', status='ready', stopOnFailure=True),
                      step('sixImportExport', directory=str(root))]
        (root / 'steps.json').write_text(json.dumps(steps + [step('quit')]))
        with (root / 'driver.log').open('w') as log:
            result = subprocess.run([str(REPO / '.build/debug/Marika')], cwd=REPO,
                env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(root / 'steps.json')),
                stdout=log, stderr=subprocess.STDOUT, timeout=300)
        if result.returncode or '[driver] FAILED' in (root / 'driver.log').read_text():
            raise RuntimeError('Inspect ' + str(root / 'driver.log'))

    if rendered.is_dir():
        with preview(rendered) as address:
            run(address)
    else:
        run()
    if args.references_only:
        return {'source': source, 'reference': str(root / 'reference.png')}
    return {'source': source, **json.loads((root / 'measurements.json').read_text()),
            **source_checks(root, project, source)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--agent', choices=['claude', 'codex'], default='claude')
    parser.add_argument('--model', help='Override the installed agent’s default model')
    parser.add_argument('--source', choices=SOURCES + ['all'], default='index.html')
    parser.add_argument('--references-only', action='store_true')
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix='marika-import-benchmark-'))
    print('Benchmark output:', root, flush=True)
    results = []
    for source in SOURCES if args.source == 'all' else [args.source]:
        try:
            results.append(run_fixture(source, args, root / source.replace(".", "-")))
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            results.append({'source': source, 'error': str(error)})
    output = json.dumps(results, indent=2)
    (root / 'results.json').write_text(output + '\n')
    print(output)
    return int(any('error' in result for result in results))


if __name__ == '__main__':
    raise SystemExit(main())
