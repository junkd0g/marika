#!/usr/bin/env python3
"""Exercise the complete project workflow without calling a model."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-workbench-ui-'))
project = root / 'Workbench'
data = root / 'data'
(project / 'Sources').mkdir(parents=True)
data.mkdir()
(project / 'Sources/Main.swift').write_text('import SwiftUI\n// Needle: open this line\nstruct Main {}\n')
(project / 'Sources/Theme.swift').write_text('import SwiftUI\nenum Theme {}\n')
(project / 'index.html').write_text('<!doctype html><title>Workbench preview</title><h1>A running project preview</h1>')
(project / 'preview.py').write_text("import http.server\ns=http.server.ThreadingHTTPServer(('127.0.0.1',0),http.server.SimpleHTTPRequestHandler)\nprint('http://127.0.0.1:%s'%s.server_port,flush=True)\ns.serve_forever()\n")
for args in [['init', '-b', 'main'], ['config', 'user.name', 'UI Test'], ['config', 'user.email', 'ui@marika.local'], ['add', '.'], ['commit', '-m', 'Initial project']]:
    subprocess.run(['git', '-C', str(project)] + args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
(data / 'workspace.json').write_text(json.dumps({'projects':[{'id':pid,'path':str(project),'name':'Workbench'}],
    'sessions':[{'id':sid,'projectID':pid,'agent':'codex','title':'Project conversation','createdAt':'2026-11-05T12:00:00Z','updatedAt':'2026-11-05T12:00:00Z','mode':'ask'}]}))
def s(op, **kw): return dict(op=op, **kw)
def run(steps, name):
    script=root/(name+'.json'); script.write_text(json.dumps(steps))
    logpath=root/(name+'.log')
    with logpath.open('w') as log:
        process=subprocess.run([str(repo/'.build/debug/Marika')],env=dict(os.environ,MARIKA_DATA=str(data),MARIKA_DRIVER=str(script)),stdout=log,stderr=subprocess.STDOUT,timeout=60)
    lines=logpath.read_text().splitlines()
    assert process.returncode==0 and not any('[driver] FAILED' in l for l in lines), logpath
    return lines
steps=[s('wait',seconds=1.1),s('size',width=1240,height=820),s('agentsMock',seconds=.15),s('inspector',show=False),
    s('codeOpen',path='Sources/Main.swift'),s('wait',seconds=.25),s('codeInsert',text='// local unsaved draft\n'),
    s('codeOpen',path='Sources/Theme.swift'),s('browserOpen',url=(project/'index.html').as_uri()),s('browserWait'),
    s('shortcut',key='2'),s('split',panel='browser',fraction=.55),s('wait',seconds=.25),s('layoutState'),
    s('shortcut',key='k'),s('wait',seconds=.25),s('toolQuery',text='Search Project'),s('wait',seconds=.1),s('key',code=36),
    s('wait',seconds=.35),s('toolQuery',text='Needle'),s('wait',seconds=.4),s('key',code=36),s('wait',seconds=.35),s('codeState'),
    s('previewConfig',command='/usr/bin/python3 -u preview.py',address='http://localhost:1'),s('previewStart'),s('previewWait'),
    s('wait',seconds=.4),s('previewState'),s('layoutState'),s('shot',path=str(root/'split-preview.png')),
    s('previewStop'),s('agentsLaunch',agent='codex',task='Review the main view'),s('wait',seconds=.4),
    s('agentWorktreeEdit',path='Sources/Main.swift',text='import SwiftUI\n// Changed in isolated agent worktree\nstruct Main {}\n'),
    s('agentReview'),s('wait',seconds=.7),s('shot',path=str(root/'review.png'),sheet=True),s('reviewApply'),s('wait',seconds=.5),
    s('assertMarker',name='agent-review-error'),s('layoutState'),
    s('clickMarker',name='agent-review-close'),
    s('agentWorktreeEdit',path='Sources/Main.swift',text='import SwiftUI\n// Needle: open this line\nstruct Main {}\n'),
    s('agentWorktreeEdit',path='Sources/Theme.swift',text='import SwiftUI\n// Changed in isolated agent worktree\nenum Theme {}\n'),
    s('agentReview'),s('wait',seconds=.5),s('reviewApply'),s('wait',seconds=.5),
    s('assertMarker',name='agent-review-error',present=False),s('shortcut',key='3',exactMenu=True),
    s('wait',seconds=.2),s('layoutState'),s('checkpoint'),s('quit')]
lines=run(steps,'workflow')
def records(lines, prefix): return [json.loads(l.split(prefix,1)[1]) for l in lines if prefix in l]
layouts=records(lines,'[driver] layout ')
assert layouts[0]['primary']=='Code' and layouts[0]['secondary']=='Browser',layouts
assert layouts[1]['primary']=='Browser' and layouts[1]['secondary']=='Code',layouts
assert '// local unsaved draft' in layouts[2]['draft'] and not layouts[2]['conflict'],layouts[2]
assert '// local unsaved draft' in layouts[-1]['draft'] and not layouts[-1]['conflict'],layouts[-1]
preview=records(lines,'[driver] preview ')[0]
assert preview['state']=='running' and '127.0.0.1:' in preview['url'],preview
assert 'Changed in isolated agent worktree' in (project/'Sources/Theme.swift').read_text()
assert 'local unsaved draft' not in (project/'Sources/Main.swift').read_text()
saved=json.loads((data/'workspace.json').read_text())
assert saved['sessions'][-1]['agentTask']['workspace']['status']=='reviewed',saved['sessions'][-1]
restarted=run([s('wait',seconds=1.2),s('layoutState'),s('quit')],'restore')
restored=records(restarted,'[driver] layout ')[0]
assert restored['primary']=='Browser' and restored['secondary']=='Code',restored
assert len(restored['files'])==2 and '// local unsaved draft' in restored['draft'] and not restored['conflict'],restored
assert restored['browserURLs'] and restored['browserURLs'][0].startswith('http://127.0.0.1:'),restored
print('Complete workbench flow passed. Screenshots and logs:',root)
