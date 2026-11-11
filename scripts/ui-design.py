#!/usr/bin/env python3
"""Drive the Design canvas with real input, check chat integration, and capture it wide, compact, light and dark."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-design-'))
data = root / 'data'
data.mkdir()


def color(value, alpha=1):
    return dict(red=int(value[0:2], 16) / 255, green=int(value[2:4], 16) / 255, blue=int(value[4:6], 16) / 255, alpha=alpha)


def node(kind, name, x, y, width, height, fill='FFFFFF', text=None, **extra):
    return dict(dict(id=str(uuid.uuid4()).upper(), kind=kind, name=name, x=x, y=y, width=width, height=height, fill=color(fill),
                     strokeWidth=1, cornerRadius=0, opacity=1, text=name if text is None else text, fontSize=15,
                     isLocked=False, isHidden=False), **extra)


nodes = [
    node('Frame', 'Clients', 0, 0, 300, 420, text=''),
    node('Rectangle', 'Web app', 40, 60, 220, 90, 'E8EFFF', cornerRadius=12),
    node('Rectangle', 'Mobile app', 40, 190, 220, 90, 'E8EFFF', cornerRadius=12, description='Offline first. Sync when the connection returns.'),
    node('Text', 'Sign-in note', 40, 320, 220, 44, '5A5A66', text='Everyone signs in with SSO', fontSize=13),
    node('Frame', 'Platform', 400, 0, 560, 420, text=''),
    node('Rectangle', 'API gateway', 440, 60, 200, 90, '6254D9', cornerRadius=12, fontWeight='semibold',
         shadow=dict(color=color('000000', 0.25), x=0, y=6, blur=16)),
    node('Polygon', 'Auth check', 460, 210, 160, 130, 'FFE9B8', text='Signed in?', sides=4, stroke=color('C98A00'), strokeWidth=2),
    node('Ellipse', 'Queue', 720, 70, 180, 70, 'D9F5E5'),
    node('Rectangle', 'Worker', 720, 230, 200, 90, 'FFFFFF', cornerRadius=8, stroke=color('8A8A99'), strokeWidth=2, strokeStyle='dashed'),
    node('Star', 'New', 896, 18, 46, 46, 'FFC83D', text='', rotation=15),
    node('Arrow', 'Release flow', 40, 462, 880, 16, '1A1A1F', text='', stroke=color('8A8A99'), strokeWidth=2),
    node('Text', 'Caption', 40, 486, 300, 24, '5A5A66', text='Requests flow left to right', fontSize=13),
]
ids = {item['name']: item['id'] for item in nodes}
connections = [dict(id=str(uuid.uuid4()).upper(), **{'from': ids[a], 'to': ids[b]}, label=label) for a, b, label in [
    ('Web app', 'API gateway', 'HTTPS'), ('Mobile app', 'API gateway', ''), ('API gateway', 'Auth check', ''),
    ('API gateway', 'Queue', 'enqueue'), ('Queue', 'Worker', '')]]
design = dict(title='Service architecture', nodes=nodes, connections=connections)

projects, sessions = [], []
for index, name in enumerate(['Studio', 'Research']):
    folder = root / name
    folder.mkdir()
    (folder / 'README.md').write_text('# ' + name + '\n')
    pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
    projects.append(dict(id=pid, path=str(folder), name=name, conversationSessionID=sid, layout=dict(showsInspector=False), design=design))
    sessions.append(dict(id=sid, projectID=pid, agent='codex', title=name + ' chat', mode='ask',
                         createdAt=f'2026-11-0{6 - index}T12:00:00Z', updatedAt=f'2026-11-0{6 - index}T12:00:00Z'))
(data / 'workspace.json').write_text(json.dumps(dict(projects=projects, sessions=sessions)))
exports = root / 'exports'
exports.mkdir()


def step(op, **values):
    return dict(op=op, **values)


def run(name, steps):
    script, log = root / (name + '.json'), root / (name + '.log')
    script.write_text(json.dumps(steps))
    with log.open('w') as output:
        result = subprocess.run([str(repo / '.build/debug/Marika')], cwd=repo,
                                env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script), MARIKA_DEMO='1'),
                                stdout=output, stderr=subprocess.STDOUT, timeout=120)
    text = log.read_text()
    assert result.returncode == 0 and '[driver] FAILED' not in text, f'{log}\n{text[-4000:]}'
    return text


def shot(name):
    return step('capture', path=str(root / (name + '.png')))


text = run('canvas', [step('wait', seconds=1), step('agentsMock'), step('size', width=1440, height=900), step('designCanvasTest'), step('quit')])
print(next(line for line in text.splitlines() if 'Design canvas passed' in line))
text = run('visual', [step('wait', seconds=1), step('agentsMock'), step('designVisualTest', directory=str(root)),
                      step('designLayerState', count=12),
                      step('clickMarker', name='design-disclosure-' + ids['Clients']), step('designLayerState', count=9),
                      step('designSelect', names=['Web app']), step('designLayerState', count=12, selected=['Web app']),
                      step('clickMarker', name='design-layer-' + ids['Mobile app']),
                      step('designLayerState', count=12, selected=['Mobile app']),
                      step('size', width=900, height=600), step('wait', seconds=.4),
                      step('clickMarker', name='design-properties-toggle'),
                      step('editorPopoverShot', name='design-inspector', path=str(root / 'compact-properties.png')),
                      step('key', code=53), step('wait', seconds=.2),
                      step('clickMarker', name='design-layers-toggle'),
                      step('editorPopoverShot', name='design-layers', path=str(root / 'compact-layers.png')),
                      step('key', code=53), step('quit')])
print(next(line for line in text.splitlines() if 'Design visuals passed' in line))
run('looks', [step('wait', seconds=1), step('agentsMock'), step('appearance', dark=False), step('size', width=1440, height=900),
              step('designSelect', names=[]), shot('wide-light'),
              step('designSelect', names=['API gateway']), shot('wide-light-selected'),
              step('designSelect', names=['Web app', 'Mobile app', 'Sign-in note']), shot('wide-light-multiple'),
              step('designSelect', names=['Release flow']), shot('wide-light-line'),
              step('designSelect', names=[], connection=True), shot('wide-light-connection'),
              step('designSelect', names=['New'], tool='Rectangle'), step('appearance', dark=True), shot('wide-dark'),
              step('size', width=1040, height=700), step('designSelect', names=['Auth check']), shot('medium-dark'),
              step('size', width=900, height=600), step('appearance', dark=False), step('designSelect', names=['Worker']), shot('compact-light'),
              step('size', width=820, height=640), step('designSelect', names=['Web app'], editing=True), step('wait', seconds=.4), shot('narrow-editing'),
              step('designSelect', names=[], clear=True), step('appearance', dark=True), shot('narrow-empty-dark'),
              step('exitWithoutSaving')])
run('integration', [step('wait', seconds=1), step('agentsMock'), step('designIntegrationTest'), step('designDescriptionsTest'),
                    step('designSelect', names=[]), step('designExportTest', directory=str(exports)), step('quit')])
assert (exports / 'canvas.png').stat().st_size > 2000 and (exports / 'selection.png').stat().st_size > 500
saved = json.loads((data / 'workspace.json').read_text())
kinds = {item['kind'] for project in saved['projects'] for item in project['design']['nodes']}
assert {'Frame', 'Polygon', 'Star', 'Arrow', 'Text'} <= kinds, kinds
text = run('components', [step('wait', seconds=1), step('agentsMock'), step('size', width=1440, height=900),
                          step('appearance', dark=False), step('designComponentsPrepare'), step('wait', seconds=.3),
                          step('clickMarker', name='design-components-toggle'),
                          step('captureMarker', name='design-component-library', path=str(root / 'component-library.png')),
                          step('clickMarker', name='design-component-service'),
                          step('designComponentsCheck', directory=str(exports)), step('wait', seconds=.4),
                          step('designComponentsCapture', path=str(root / 'engineering-components.png')),
                          step('appearance', dark=True), step('wait', seconds=.4),
                          step('designComponentsCapture', path=str(root / 'engineering-components-dark.png')), step('quit')])
print(next(line for line in text.splitlines() if 'Engineering components passed' in line))
text = run('workflows', [step('wait', seconds=1), step('agentsMock'), step('size', width=1440, height=900),
                         step('appearance', dark=False), step('designWorkflowPrepare'), step('wait', seconds=.4),
                         shot('diagram-templates'), step('clickMarker', name='design-template-services'), step('wait', seconds=.3),
                         step('designWorkflowCheck'), step('wait', seconds=.4), shot('diagram-ticket-review'),
                         step('clickMarker', name='design-create-ticket'), step('wait', seconds=.8),
                         step('designWorkflowTicket'), step('wait', seconds=.5), shot('diagram-version-diff'),
                         step('clickMarker', name='design-restore-version'), step('wait', seconds=.3),
                         step('designWorkflowFinish', directory=str(exports)), step('wait', seconds=.5), shot('diagram-workflow'),
                         step('appearance', dark=True), step('wait', seconds=.4), shot('diagram-workflow-dark'), step('quit')])
print(next(line for line in text.splitlines() if 'Design workflows passed' in line))
saved = json.loads((data / 'workspace.json').read_text())
assert any(p.get('designVersions') for p in saved['projects'])
assert any(t.get('designSource') for s in saved['spaces'] for t in s.get('tickets', []))
assert (exports / 'architecture.svg').stat().st_size > 2000
print('Design canvas input, chat integration, export and layouts passed. Screenshots and logs:', root)
