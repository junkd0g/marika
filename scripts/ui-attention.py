#!/usr/bin/env python3
"""Exercise attention priority, scope, routes, resolution, dismissal and restart."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-attention-'))
data = root / 'data'; data.mkdir()
project = root / 'Product'; project.mkdir(); (project / 'README.md').write_text('# Inbox fixture\n')
personal = '00000000-0000-0000-0000-000000000001'
other, pid, foreign, ticket = [str(uuid.uuid4()).upper() for _ in range(4)]
date = '2026-11-09T12:00:00Z'
ids = {name: str(uuid.uuid4()).upper() for name in ['Approval agent', 'Blocked agent', 'Review ticket', 'Failed checks', 'Other space result', 'Ordinary reply']}
sessions = [dict(id=sid, projectID=foreign if title == 'Other space result' else pid, agent='codex', title=title,
                 mode='ask', createdAt=date, updatedAt=date,
                 **({} if title in ['Ordinary reply', 'Approval agent'] else {'agentTask':dict(prompt=title, **({'ticketID':ticket} if title == 'Review ticket' else {}))}))
            for title, sid in ids.items()]
spaces = [dict(id=personal, name='Personal', tickets=[dict(id=ticket, key='PERSON-1', title='Review navigation changes', body='Review the new project navigation.',
    status='In Progress', priority='Medium', kind='Task', assignee='', projectID=pid, archived=False, createdAt=date, updatedAt=date)]), dict(id=other, name='Team')]
(data / 'workspace.json').write_text(json.dumps(dict(spaces=spaces, projects=[dict(id=pid, name='Product', path=str(project), spaceID=personal,
    conversationSessionID=ids['Ordinary reply'], layout=dict(showsInspector=False)), dict(id=foreign, name='Team product', path=str(project), spaceID=other)], sessions=sessions, selectedSpaceID=personal)))
# The digest is computed inside the app so ticket context exactly matches its saved run.

def s(op, **kw): return dict(op=op, **kw)

def run(name, steps):
    script, log = root / (name + '.json'), root / (name + '.log')
    script.write_text(json.dumps(steps))
    with log.open('w') as out:
        result = subprocess.run([str(repo / '.build/debug/Marika')], cwd=repo,
            env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script), MARIKA_DEMO='1',
                     MARIKA_EDITOR_DEFAULTS_SUITE='app.marika.attention.' + uuid.uuid4().hex), stdout=out, stderr=subprocess.STDOUT, timeout=100)
    assert result.returncode == 0 and '[driver] FAILED' not in log.read_text(), f'{log}\n{log.read_text()[-5000:]}'

run('inbox', [s('wait', seconds=1), s('agentsMock'), s('size', width=1120, height=820),
    s('attentionTest', phase='fixture'), s('clickMarker', name='space-open-attention'), s('assertMarker', name='attention-inbox'),
    s('assertMarker', name='attention-item-' + ids['Other space result'], present=False), s('appearance', dark=True),
    s('shot', path=str(root / 'inbox-dark.png')), s('size', width=900, height=600), s('appearance', dark=False),
    s('shot', path=str(root / 'inbox-compact-light.png')),
    s('clickMarker', name='attention-open-' + ids['Approval agent']), s('assertMarker', name='workspace-header'),
    s('attentionTest', phase='approvalResolved', count=4), s('clickMarker', name='space-open-attention'),
    s('assertMarker', name='attention-item-' + ids['Approval agent'], present=False),
    s('clickMarker', name='attention-open-' + ids['Review ticket'], scroll=True), s('assertMarker', name='space-ticket-editor'),
    s('attentionTest', phase='accepted', count=3), s('clickMarker', name='space-ticket-done'),
    s('clickMarker', name='space-open-attention'), s('assertMarker', name='attention-item-' + ids['Review ticket'], present=False),
    s('clickMarker', name='attention-open-' + ids['Failed checks'], scroll=True), s('assertMarker', name='task-completion-view'),
    s('attentionTest', phase='checksPassed', count=3), s('clickMarker', name='completion-done'), s('clickMarker', name='space-open-attention'),
    s('clickMarker', name='attention-dismiss-' + ids['Blocked agent']), s('assertMarker', name='attention-item-' + ids['Blocked agent'], present=False),
    s('quit')])
run('restart', [s('wait', seconds=1), s('agentsMock'), s('attentionTest', phase='restored'),
    s('clickMarker', name='space-open-attention'), s('attentionTest', phase='newFailure', count=3),
    s('assertMarker', name='attention-item-' + ids['Blocked agent']), s('quit')])
print('Attention scope, routing, resolution, dismissal and restart passed. Diagnostics:', root)
