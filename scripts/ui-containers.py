#!/usr/bin/env python3
"""Exercise the native Containers hub with isolated Docker/Kubernetes fixtures."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-containers-'))
data = root / 'data'; data.mkdir()
project = root / 'Studio'; project.mkdir()
pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
date = '2026-11-11T12:00:00Z'
(data / 'workspace.json').write_text(json.dumps(dict(projects=[dict(id=pid, name='Studio', path=str(project), conversationSessionID=sid, layout=dict(showsInspector=False))],
    sessions=[dict(id=sid, projectID=pid, agent='codex', title='Studio chat', mode='ask', createdAt=date, updatedAt=date)])))
(project / 'compose.yaml').write_text('services:\n  web:\n    image: nginx:alpine\n')
(project / 'deploy.yaml').write_text('apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: api\nspec:\n  replicas: 3\n')
(project / 'contexts.json').write_text(json.dumps([
    dict(Name='desktop-linux', DockerEndpoint='unix:///var/run/docker.sock', Current=True),
    dict(Name='remote', DockerEndpoint='ssh://example.test', Current=False)]))
containers = []
for letter, name, image, state, status, port in [('a', 'web', 'nginx:alpine', 'running', 'Up 2 hours (healthy)', '0.0.0.0:8080->80/tcp'),
    ('b', 'api', 'studio/api:dev', 'running', 'Up 2 hours (healthy)', '127.0.0.1:3000->3000/tcp'),
    ('c', 'postgres', 'postgres:17', 'running', 'Up 2 hours (healthy)', '5432/tcp'),
    ('d', 'worker', 'studio/api:dev', 'exited', 'Exited (1) 10 minutes ago', '')]:
    containers.append(dict(ID=letter * 64, Names=name, Image=image, State=state, Status=status, Ports=port,
        Networks='studio_default', Labels='com.docker.compose.project=studio,app=' + name))
(project / 'containers.json').write_text(json.dumps(containers))
(project / 'images.json').write_text(json.dumps([dict(ID='sha256:' + letter * 64, Repository=repo, Tag=tag, Size=size, CreatedSince='2 days ago')
    for letter, repo, tag, size in [('1', 'nginx', 'alpine', '46 MB'), ('2', 'studio/api', 'dev', '184 MB'), ('3', 'postgres', '17', '438 MB')]]))
items = []
def item(kind, name, uid, spec, status=None, owner=None, labels=None):
    meta = dict(name=name, uid=uid, namespace='studio')
    if owner: meta['ownerReferences'] = [dict(uid=owner, controller=True)]
    if labels: meta['labels'] = labels
    items.append(dict(kind=kind, metadata=meta, spec=spec, status=status or {}))
item('Service', 'api', 'api-service', dict(selector=dict(app='api'), type='ClusterIP', clusterIP='10.96.21.8', ports=[dict(port=80, targetPort=8080)]))
item('Service', 'postgres', 'db-service', dict(selector=dict(app='postgres'), type='ClusterIP', clusterIP='10.96.15.9', ports=[dict(port=5432)]))
item('Deployment', 'api', 'api-deploy', dict(replicas=2, template=dict(spec=dict(containers=[dict(name='api', image='studio/api:dev')]))), dict(readyReplicas=1))
items[-1]['metadata']['annotations'] = {'deployment.kubernetes.io/revision': '3'}
item('StatefulSet', 'postgres', 'db-stateful', dict(replicas=1, template=dict(spec=dict(containers=[dict(image='postgres:17')]))), dict(readyReplicas=1))
item('ReplicaSet', 'api-76c8', 'api-rs', dict(replicas=2), owner='api-deploy')
for name, uid, app, owner, image, ready, restarts in [('api-76c8-one', 'api-pod-1', 'api', 'api-rs', 'studio/api:dev', True, 0),
    ('api-76c8-two', 'api-pod-2', 'api', 'api-rs', 'studio/api:dev', False, 5),
    ('postgres-0', 'db-pod', 'postgres', 'db-stateful', 'postgres:17', True, 0)]:
    state = dict(running={}) if ready else dict(waiting=dict(reason='CrashLoopBackOff'))
    item('Pod', name, uid, dict(nodeName='studio-control-plane', containers=[dict(image=image, ports=[dict(containerPort=8080 if app == 'api' else 5432)])]),
        dict(phase='Running', containerStatuses=[dict(ready=ready, restartCount=restarts, state=state)]), owner=owner, labels=dict(app=app))
item('ReplicaSet', 'api-old', 'api-old-rs', dict(replicas=0, template=dict(spec=dict(containers=[dict(name='api', image='studio/api:old')]))), owner='api-deploy')
items[-1]['metadata']['annotations'] = {'deployment.kubernetes.io/revision': '2'}
cron_spec = dict(schedule='0 2 * * *', timeZone='Europe/London', jobTemplate=dict(spec=dict(template=dict(spec=dict(restartPolicy='Never', containers=[dict(name='worker', image='studio/import:dev')])))))
item('CronJob', 'nightly-import', 'cron-import', cron_spec, dict(lastScheduleTime='2026-11-11T02:00:00Z', lastSuccessfulTime='2026-11-10T02:00:04Z'))
for name, uid, spec, status in [('nightly-import-failed', 'job-failed', {}, dict(failed=2, conditions=[dict(type='Failed', status='True', reason='BackoffLimitExceeded', message='Upstream service returned HTTP 500')], startTime='2026-11-11T02:00:00Z')),
    ('recovered-import', 'job-complete', {}, dict(failed=1, succeeded=1, conditions=[dict(type='Complete', status='True')])),
    ('paused-import', 'job-paused', dict(suspend=True), dict(failed=1))]:
    item('Job', name, uid, dict(spec, backoffLimit=2, template=dict(spec=dict(restartPolicy='Never', containers=[dict(name='worker', image='studio/import:dev')]))), status, owner='cron-import')
    items[-1]['metadata']['ownerReferences'][0].update(kind='CronJob', name='nightly-import')
item('Pod', 'nightly-import-attempt', 'job-pod', dict(containers=[dict(name='worker', image='studio/import:dev')]),
    dict(phase='Failed', containerStatuses=[dict(name='worker', restartCount=2, ready=False, state=dict(terminated=dict(exitCode=1, reason='Error')))]), owner='job-failed')
items[-1]['metadata']['ownerReferences'][0].update(kind='Job', name='nightly-import-failed')
(project / 'kubernetes.json').write_text(json.dumps(dict(items=items)))
(project / 'events.json').write_text(json.dumps(dict(items=[dict(metadata=dict(uid='event-1'), involvedObject=dict(uid='api-pod-2'),
    type='Warning', reason='BackOff', message='Back-off restarting failed container api in pod api-76c8-two.')])))

def step(op, **values): return dict(op=op, **values)
def shot(name): return step('capture', path=str(root / (name + '.png')))
steps = [step('wait', seconds=1), step('size', width=1540, height=950), step('appearance', dark=False), step('containersPrepare'),
    step('clickMarker', name='sidebar-open-containers'), step('wait', seconds=.6), step('assertMarker', name='project-containers'),
    step('clickMarker', name='containers-engine', fraction=.75), step('wait', seconds=.4), step('containersCheck', phase='kubernetes'),
    step('clickMarker', name='containers-engine', fraction=.25), step('wait', seconds=.4), step('containersCheck', phase='docker'),
    shot('docker-map'), step('clickMarker', name='container-node-docker:' + 'a' * 64), step('containersCheck', phase='selected'), shot('docker-details'),
    step('clickMarker', name='containers-logs'), step('wait', seconds=.3), step('containersCheck', phase='logs'),
    step('captureMarker', name='container-output', path=str(root / 'container-logs.png')), step('key', code=53), step('wait', seconds=.4),
    step('clickMarker', name='containers-run'), step('wait', seconds=.4), step('assertMarker', name='container-creation-sheet'),
    step('captureMarker', name='container-creation-sheet', path=str(root / 'run-image.png')), step('clickMarker', name='container-create-submit'),
    step('wait', seconds=.5), step('containersCheck', phase='run'), step('containersCheck', phase='workflow'), step('wait', seconds=.4),
    shot('kubernetes-map'), step('appearance', dark=True), step('wait', seconds=.3), shot('kubernetes-dark'),
    step('containersCheck', phase='preview'), step('wait', seconds=.4),
    step('captureMarker', name='container-manifest-review', path=str(root / 'manifest-review.png')),
    step('clickMarker', name='container-apply-submit'), step('wait', seconds=.3), step('containersCheck', phase='applied'),
    step('containersCheck', phase='forward'), step('clickMarker', name='containers-view', fraction=.375), step('wait', seconds=.3), shot('kubernetes-list'),
    step('containersCheck', phase='health'), step('clickMarker', name='containers-view', fraction=.84), step('wait', seconds=.5), shot('cluster-health-dark'),
    step('appearance', dark=False), step('wait', seconds=.3), shot('cluster-health-light'),
    step('clickMarker', name='health-issue-kube:job-failed'), step('wait', seconds=.4), step('containersCheck', phase='health-selected'), shot('job-details'),
    step('clickMarker', name='container-diagnostics-open'), step('wait', seconds=.5), step('assertMarker', name='container-diagnostics'), shot('job-diagnostics'),
    step('clickMarker', name='container-previous-logs'), step('wait', seconds=.4), step('containersCheck', phase='previous-logs'), step('key', code=53), step('wait', seconds=.3),
    step('clickMarker', name='container-retry'), step('wait', seconds=.4), step('containersCheck', phase='no-recovery'), shot('retry-review'),
    step('key', code=53), step('wait', seconds=.3), step('containersCheck', phase='no-recovery'),
    step('clickMarker', name='container-retry'), step('wait', seconds=.4), step('clickMarker', name='container-recovery-confirm'), step('wait', seconds=.4), step('containersCheck', phase='retry-confirmed'),
    step('containersCheck', phase='select-deployment'), step('wait', seconds=.3), step('clickMarker', name='container-rollback'), step('wait', seconds=.4),
    step('clickMarker', name='container-revision-2'), step('clickMarker', name='container-revision-review'), step('wait', seconds=.4), shot('rollback-review'),
    step('clickMarker', name='container-recovery-confirm'), step('wait', seconds=.4), step('containersCheck', phase='rollback-confirmed'),
    step('containersCheck', phase='logs-prepare'), step('wait', seconds=.3), step('assertMarker', name='containers-logs-view'),
    step('clickMarker', name='log-run'), step('wait', seconds=.5), step('containersCheck', phase='logs-query'), shot('logs-query'), step('containersCheck', phase='logs-entry'), step('wait', seconds=.2), shot('logs-structured'),
    step('spaceContentText', name='log-search', text='upstream'), step('containersCheck', phase='logs-filter'), shot('logs-filtered'),
    step('clickMarker', name='log-live'), step('clickMarker', name='log-run'), step('wait', seconds=1), step('containersCheck', phase='logs-live'), shot('logs-live'),
    step('clickMarker', name='log-stop'), step('containersCheck', phase='logs-stopped'), step('size', width=900, height=700), step('wait', seconds=.3), shot('logs-compact'), step('size', width=1540, height=950), step('containersCheck', phase='logs-context'),
    step('containersCheck', phase='logs-loki'), step('wait', seconds=.3), step('clickMarker', name='log-run'), step('wait', seconds=.4), step('containersCheck', phase='logs-history'), shot('loki-history'), step('appearance', dark=True), step('wait', seconds=.3), shot('loki-history-dark'), step('appearance', dark=False),
    step('clickMarker', name='log-connections'), step('wait', seconds=.3), step('clickMarker', name='container-log-test-connection'), step('wait', seconds=.3), step('assertMarker', name='container-log-connected'), shot('log-connections'), step('key', code=53), step('wait', seconds=.3),
    step('clickMarker', name='containers-view', fraction=.84), step('size', width=900, height=700), step('wait', seconds=.4), shot('health-compact'),
    step('clickMarker', name='containers-view', fraction=.125), step('size', width=900, height=700), step('appearance', dark=False),
    step('wait', seconds=.4), shot('compact-map'), step('clickMarker', name='container-node-kube:api-service'), step('wait', seconds=.4),
    shot('compact-details'), step('key', code=53), step('quit')]
script = root / 'steps.json'; script.write_text(json.dumps(steps))
log = root / 'run.log'
with log.open('w') as output:
    result = subprocess.run([str(repo / '.build/debug/Marika')], cwd=repo,
        env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script), MARIKA_DEMO='1'),
        stdout=output, stderr=subprocess.STDOUT, timeout=120)
text = log.read_text()
assert result.returncode == 0 and '[driver] FAILED' not in text, f'{log}\n{text[-4000:]}'
saved = json.loads((data / 'workspace.json').read_text())
settings = saved['projects'][0]['containerHub']
assert settings['namespace'] == 'studio' and settings['provider'] == 'Kubernetes'
print('Containers native UI, scoped actions, logs, manifest review, forwarding cleanup, and persistence passed. Screenshots and logs:', root)
