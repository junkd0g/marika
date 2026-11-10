#!/usr/bin/env python3
"""Create tickets from real native selections and verify source links across restart."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='marika-note-tickets-'))
data = root / 'data'; data.mkdir()
project = root / 'Product'; project.mkdir(); (project / 'README.md').write_text('# Product\n')
personal = '00000000-0000-0000-0000-000000000001'
pid, sid, nid, plain, checklist = [str(uuid.uuid4()).upper() for _ in range(5)]
date = '2026-11-10T12:00:00Z'
body = 'Ideas 💡: improve keyboard navigation. Keep this other sentence in the note.'
checktext = 'Add a clear setup checklist'
note = dict(id=nid, title='Product ideas', blocks=[dict(id=plain, kind='Text', text=body, checked=False),
    dict(id=checklist, kind='Checklist', text=checktext, checked=True)], pinned=False, archived=False, createdAt=date, updatedAt=date)
(data / 'workspace.json').write_text(json.dumps(dict(spaces=[dict(id=personal, name='Personal', notes=[note], section='Notes')],
    projects=[dict(id=pid, name='Product', path=str(project), spaceID=personal, conversationSessionID=sid, layout=dict(showsInspector=False))],
    sessions=[dict(id=sid, projectID=pid, agent='codex', title='Project chat', mode='ask', createdAt=date, updatedAt=date)], selectedSpaceID=personal)))

def s(op, **kw): return dict(op=op, **kw)
def run(name, steps):
    script, log = root / (name + '.json'), root / (name + '.log')
    script.write_text(json.dumps(steps))
    with log.open('w') as out:
        result = subprocess.run([str(repo / '.build/debug/Marika')], cwd=repo,
            env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script), MARIKA_DEMO='1',
                MARIKA_EDITOR_DEFAULTS_SUITE='app.marika.note-tickets.' + uuid.uuid4().hex), stdout=out, stderr=subprocess.STDOUT, timeout=100)
    assert result.returncode == 0 and '[driver] FAILED' not in log.read_text(), f'{log}\n{log.read_text()[-5000:]}'

def select(block=plain, text='improve keyboard navigation'):
    return [s('noteTicketSelect', name='space-note-block-' + block, text=text), s('assertMarker', name='note-selection-create-ticket'),
            s('clickMarker', name='note-selection-create-ticket'), s('assertMarker', name='note-ticket-create')]

run('cancel', [s('wait', seconds=1), s('agentsMock'), s('size', width=1000, height=760), s('noteTicketSaveGuard')] + select() +
    [s('shot', path=str(root / 'draft.png'), sheet=True), s('clickMarker', name='note-ticket-cancel'), s('assertMarker', name='note-ticket-create', present=False), s('quit')])
assert not json.loads((data / 'workspace.json').read_text())['spaces'][0].get('tickets'), 'Cancel created a ticket'
run('create', [s('wait', seconds=1), s('agentsMock'), s('size', width=1000, height=760)] + select() +
    [s('clickMarker', name='note-ticket-submit'), s('assertMarker', name='space-ticket-editor'),
     s('shot', path=str(root / 'ticket.png'), sheet=True), s('clickMarker', name='ticket-note-link-' + nid, scroll=True),
     s('assertMarker', name='space-notes'), s('assertMarker', name='note-linked-tickets'), s('shot', path=str(root / 'linked-dark.png')),
     s('appearance', dark=False), s('size', width=900, height=600), s('shot', path=str(root / 'linked-compact-light.png')), s('quit')])
saved = json.loads((data / 'workspace.json').read_text()); t = saved['spaces'][0]['tickets'][0]
assert t['title'] == 'improve keyboard navigation' and t['body'] == 'improve keyboard navigation', t
assert t['linkedNoteIDs'] == [nid] and t['projectID'] == pid, t
assert saved['spaces'][0]['notes'][0]['blocks'] == note['blocks'], 'Creating a ticket changed the note'
run('checklist', [s('wait', seconds=1), s('agentsMock'), s('clickMarker', name='note-linked-ticket-' + t['id'], scroll=True),
    s('assertMarker', name='space-ticket-editor'), s('spaceTicketFields', status='Done'),
    s('clickMarker', name='ticket-note-link-' + nid, scroll=True)] + select(checklist, checktext) +
    [s('clickMarker', name='note-ticket-submit'), s('assertMarker', name='space-ticket-editor'),
     s('clickMarker', name='ticket-note-link-' + nid, scroll=True), s('assertMarker', name='note-linked-tickets'), s('quit')])
saved = json.loads((data / 'workspace.json').read_text()); tickets = saved['spaces'][0]['tickets']
assert len(tickets) == 2 and tickets[0]['status'] == 'Done' and tickets[1]['body'] == checktext, tickets
assert saved['spaces'][0]['notes'][0]['blocks'] == note['blocks'], 'Checklist completion was changed'
run('archived-source', [s('wait', seconds=1), s('agentsMock'), s('clickMarker', name='space-note-archive'),
    s('clickMarker', name='space-open-tickets'), s('clickMarker', name='space-ticket-' + tickets[1]['id']),
    s('assertMarker', name='space-ticket-editor'),
    s('clickMarker', name='ticket-note-link-' + nid, scroll=True), s('assertMarker', name='space-notes'),
    s('assertMarker', name='space-note-title'), s('shot', path=str(root / 'archived-source.png')), s('quit')])
print('Native note selections, cancellation, ticket creation, checklist preservation and backlinks passed. Diagnostics:', root)
