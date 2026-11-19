#!/usr/bin/env python3
"""Capture populated feature screens missing from the small README introduction."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-readme-extras-'))
data, project = root / 'data', root / 'Copper'
data.mkdir(); project.mkdir(); (project / '.github/workflows').mkdir(parents=True)
(project / '.github/workflows/check.yml').write_text('name: Check\non: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo "check the project"\n')
(project / 'README.md').write_text('# Copper\n\nA focused project workspace.\n\n- [x] Review the interface\n- [ ] Ship the next iteration\n')
(project / 'main.go').write_text('package main\nimport "fmt"\nfunc add(a, b int) int { return a + b }\nfunc main() {\n value := add(2, 3)\n fmt.Println(value)\n}\n')
(project / 'go.mod').write_text('module example.test/copper\n\ngo 1.24\n')
(project / 'main_test.go').write_text('package main\nimport "testing"\nfunc TestAdd(t *testing.T) { if add(2, 3) != 5 { t.Fatal("sum") } }\n')
subprocess.run(['git','init','-q',str(project)],check=True)
subprocess.run(['git','-C',str(project),'add','.'],check=True)
subprocess.run(['git','-C',str(project),'-c','user.name=Demo','-c','user.email=demo@example.test','commit','-qm','Sample project'],check=True)
pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
stamp = '2026-11-19T12:00:00Z'
def artifact(title, kind, **kw):
    return dict(id=str(uuid.uuid4()),sessionID=sid,date=stamp,title=title,kind=kind,body='',approved=False,comments=[],images=[],**kw)
artifacts = [artifact('Release brief', 'Deliverable', deliverable=dict(kind='report',title='Release brief',body='# Release brief\n\nThe next release focuses on clearer tasks and reliable reviews.\n\n## Acceptance checks\n\n- Drafts survive restart.\n- Each task links to its source.\n- Checks report actual outcomes.')),
    artifact('Launch checklist', 'Deliverable', deliverable=dict(kind='spreadsheet', title='Launch checklist', sheets=[dict(name='Readiness',columns=['Area','Owner','Status'],rows=[['Interface','Design','Reviewed'],['Tests','Engineering','Passing'],['Docs','Product','Ready']])])),
    artifact('Product direction', 'Deliverable', deliverable=dict(kind='presentation',title='Product direction',slides=[dict(title='A calmer way to build',bullets=['One project workspace','Traceable decisions','Reviewable agent work']),dict(title='Release priorities',bullets=['Reliability','Design reuse','Observability'])]))]
answer=lambda text:dict(conclusion=text,reasoning='Sample analysis, provided for this interface capture.',uncertainties=['Production performance needs measurement.'],sources=[])
comparison=dict(id=str(uuid.uuid4()),date=stamp,question='Should the project use a single service or split services?',synthesizer='codex',claudeID=str(uuid.uuid4()),codexID=str(uuid.uuid4()),answers={'claude':answer('Keep one service until a separate scaling boundary is measured.'),'codex':answer('Use modules with clear interfaces and deploy them together initially.')},synthesis=dict(agreements=['Keep domain boundaries explicit.','Measure before adding operational complexity.'],disagreements=[],recommendation='Start with a modular service and revisit the deployment boundary after load testing.',checks=['Measure tail latency under load.','Track independent deployment needs.']))
metadata=dict(id=pid,path=str(project),name='Copper',conversationSessionID=sid,layout=dict(showsInspector=False),comparisons=[comparison],artifacts=artifacts,
    pipelineRuns=[dict(id=str(uuid.uuid4()),date=stamp,title='Local package checks',runner='Local Mac',status='Passed · sample saved run',log='Sample recorded output\n\n✓ Unit tests passed\n✓ Release build completed\n✓ Signature verified\n\nReal runs retain their command output and exit status.')])
def save():
    (data / 'workspace.json').write_text(json.dumps(dict(projects=[metadata],sessions=[dict(id=sid,projectID=pid,agent='codex',title='Copper chat',mode='ask',createdAt=stamp,updatedAt=stamp)])))
def s(op, **kw): return dict(op=op, **kw)
def shot(name, **kw): return s('shot',path=str(root/(name+'.png')),**kw)
def run(name, steps):
    save()
    script,log = root/(name+'.json'), root/(name+'.log')
    script.write_text(json.dumps([s('wait',seconds=1),s('agentsMock'),s('size',width=1450,height=950),s('appearance',dark=False)] + steps + [s('quit')]))
    with log.open('w') as stream:
        result=subprocess.run([str(repo/'.build/debug/Marika')],cwd=repo,env=dict(os.environ,MARIKA_DATA=str(data),MARIKA_DRIVER=str(script),MARIKA_DEMO='1'),stdout=stream,stderr=subprocess.STDOUT,timeout=150)
    assert result.returncode==0 and '[driver] FAILED' not in log.read_text(), str(log)+'\n'+log.read_text()[-3000:]
run('views',[s('shortcut',key='6'),s('wait',seconds=.8),shot('pipelines'),s('terminalTest'),shot('terminal'),
    s('researchSection',index=1),s('wait',seconds=.4),shot('compare-models'),s('markdownTest',directory=str(root)),
    s('settingsWindow'),shot('settings',window='Settings')])
for i,kind in enumerate(['report','spreadsheet','presentation']):
    for index,entry in enumerate(artifacts): entry['date']='2026-11-19T'+('13' if i==index else '12')+':00:00Z'
    run(kind,[s('experience',section='Artifacts'),s('wait',seconds=.5),shot(kind,sheet=True)])
run('ide',[s('ideTest',directory=str(root))])
print('Additional feature screenshots:',root)
