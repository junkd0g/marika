#!/usr/bin/env python3
"""Verify source-to-design analysis, review, restart, safe apply and cancellation with a fixture agent."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-design-import-'))
data, project = root / 'data', root / 'Product'
data.mkdir(); project.mkdir()
source = {
    'Screen.swift': 'import SwiftUI\nstruct Screen: View { var body: some View { Text("Welcome") } }\n',
    'Screen.kt': '@Composable fun Screen() { Text("Welcome") }\n',
    'index.html': '<main><h1>Welcome</h1><button>Continue</button></main>\n',
    'App.tsx': 'export const App = () => <main><h1>Welcome back</h1><button>Continue</button></main>;\n',
    'Screen.vue': '<template><main><h1>Welcome</h1></main></template>\n',
    'theme.css': ':root { --accent: #6254d9; --radius: 12px; }\n',
}
for name, text in source.items(): (project / name).write_text(text)
pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
date = '2026-11-11T12:00:00Z'
(data / 'workspace.json').write_text(json.dumps(dict(projects=[dict(id=pid, path=str(project), name='Product', conversationSessionID=sid)],
    sessions=[dict(id=sid, projectID=pid, agent='codex', title='Product chat', mode='ask', createdAt=date, updatedAt=date)])))

def node(id, kind, name, x, y, w, h, fill='#FFFFFF', text=None, source='App.tsx', **kw):
    return dict(id=id, kind=kind, name=name, x=x, y=y, width=w, height=h, fill=fill, text=name if text is None else text,
                description='Observed in the selected UI source.', links=[dict(kind='file', target=source, line=1)], **kw)
response = json.dumps(dict(summary='A welcome screen with its shared colour, typography and button styles.',
    notes=['Code-derived preview. Runtime data and responsive layouts need visual verification.'],
    design=dict(title='Product UI', nodes=[
        node('screen','frame','Welcome screen',0,0,480,480,text=''),
        node('title','text','Welcome back',40,80,380,55,fill='#202020',fontSize=32,fontWeight='bold'),
        node('copy','text','Sign in to continue',40,145,360,30,fill='#666666',fontSize=16),
        node('email','rectangle','Email address',40,210,400,50,fill='#F3F3F5',cornerRadius=12),
        node('continue','rectangle','Continue',40,290,400,50,fill='#6254D9',cornerRadius=12),
        node('system','frame','Design system',580,0,460,480,text='',source='theme.css'),
        node('accent','rectangle','',620,80,100,80,fill='#6254D9',cornerRadius=12,source='theme.css'),
        node('label','text','Accent · #6254D9',740,100,240,30,fill='#202020',fontSize=16,source='theme.css'),
        node('type','text','Heading / 32 bold',620,215,360,50,fill='#202020',fontSize=28,fontWeight='bold'),
        node('space','text','Spacing 8 · 16 · 24\nCorner radius 12',620,295,360,70,fill='#666666',fontSize=16,source='theme.css'),
    ], connections=[])))

def step(op, **values): return dict(op=op, **values)
def shot(name): return step('capture', path=str(root / (name + '.png')))
def start(output=response, delay=1):
    return [step('wait', seconds=1), step('size', width=1500, height=950), step('appearance', dark=False),
            step('designImportPrepare', response=output, delay=delay), step('wait', seconds=.4),
            step('clickMarker', name='design-import-toggle'), step('wait', seconds=.5)]
def run(name, steps):
    script, log = root / (name + '.json'), root / (name + '.log')
    script.write_text(json.dumps(steps))
    with log.open('w') as output:
        result = subprocess.run([str(repo / '.build/debug/Marika')], cwd=repo,
            env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script), MARIKA_DEMO='1'),
            stdout=output, stderr=subprocess.STDOUT, timeout=75)
    text = log.read_text()
    assert result.returncode == 0 and '[driver] FAILED' not in text, f'{log}\n{text[-4000:]}'

run('generate', start() + [shot('source-picker'), step('size', width=900, height=700), step('appearance', dark=True), step('wait', seconds=.3), shot('compact-dark'),
    step('size', width=1500, height=950), step('appearance', dark=False), step('clickMarker', name='design-import-generate'), step('wait', seconds=.3), shot('analysis'),
    step('designImportWait', status='ready'), step('designImportCheck', phase='preview'), shot('review'), step('quit')])
(project / 'App.tsx').write_text(source['App.tsx'] + '// changed while reviewing\n')
run('stale', start() + [step('clickMarker', name='design-import-apply'), step('wait', seconds=.3),
    step('assertMarker', name='design-import-error'), step('designImportCheck', phase='preview'), shot('stale-source'), step('quit')])
(project / 'App.tsx').write_text(source['App.tsx'])
run('apply', start() + [step('designImportCheck', phase='preview'), step('clickMarker', name='design-import-apply'), step('wait', seconds=.4),
    step('designImportCheck', phase='applied'), shot('imported-canvas'), step('quit')])
run('invalid', start('Not a design draft') + [step('clickMarker', name='design-import-generate'), step('designImportWait', status='failed'),
    step('designImportCheck', phase='failed'), shot('invalid-output'), step('quit')])
run('cancel', start(delay=3) + [step('clickMarker', name='design-import-generate'), step('wait', seconds=.3), step('clickMarker', name='design-import-stop'),
    step('wait', seconds=3.3), step('designImportCheck', phase='cancelled'), step('quit')])
print('Design import source selection, review, restart, stale-source rejection, undo, errors and cancellation passed. Screenshots and logs:', root)
