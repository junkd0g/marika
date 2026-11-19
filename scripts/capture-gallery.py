#!/usr/bin/env python3
"""Assemble README's complete feature gallery from native regression captures.

Run ui-checks.py, capture-readme.py and capture-readme-extras.py first. This script
copies real screenshots, writes a coverage manifest, and updates README in place.
"""
import argparse
import json
from pathlib import Path
import shutil

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--artifacts',type=Path,default=Path('build/ui-checks'))
parser.add_argument('--extras',type=Path,required=True)
args=parser.parse_args()
repo=Path(__file__).resolve().parents[1]
images=repo/'docs/images'
items=[
 ('Getting started and settings','welcome','welcome/**/ready-light-wide.png','Welcome checklist and provider readiness'),
 ('Getting started and settings','settings','extra:settings.png','Settings, provider configuration and editor preferences'),
 ('Projects, chats and agent work','chat-controls','codex-style/**/chat-light.png','Project conversation, model, reasoning and speed controls'),
 ('Projects, chats and agent work','attention','attention/**/inbox-dark.png','Approvals, blocked work and results needing attention'),
 ('Projects, chats and agent work','chat-history','history-updates/**/history-results.png','Search saved messages across projects'),
 ('Notes and tickets','notes','space-content/**/notes-dark.png','Editable notes with headings, lists and checklists'),
 ('Notes and tickets','tickets','space-content/**/ticket-board-dark.png','Ticket board, priorities and project links'),
 ('Notes and tickets','ticket-work','ticket-work/**/accepted-light.png','Ticket work, checks, acceptance and linked agent activity'),
 ('Code, review and debugging','markdown','extra:markdown-split.png','Markdown source and rendered preview together'),
 ('Code, review and debugging','code-tests','extra:tests.png','Native test explorer, results and coverage'),
 ('Code, review and debugging','debugger','extra:debugger.png','Breakpoints, paused execution and watch values'),
 ('Code, review and debugging','changes-review','workbench/**/review.png','Review and accept isolated agent changes'),
 ('Code, review and debugging','terminal','extra:terminal.png','Interactive project terminal'),
 ('Browser, APIs and pipelines','pipelines','extra:pipelines.png','Pipeline discovery and saved run output; sample history'),
 ('Browser, APIs and pipelines','api-playground','deep-workflows/**/api-light.png','API request editing and local response inspection'),
 ('Research, knowledge and deliverables','compare-models','extra:compare-models.png','Compare independent answers and their synthesis; sample analysis'),
 ('Research, knowledge and deliverables','knowledge','deep-workflows/**/knowledge.png','Search and review project knowledge'),
 ('Research, knowledge and deliverables','report','extra:report.png','Report preview, review comments and export'),
 ('Research, knowledge and deliverables','spreadsheet','extra:spreadsheet.png','Spreadsheet deliverable preview and export'),
 ('Research, knowledge and deliverables','presentation','extra:presentation.png','Presentation deliverable preview and export'),
 ('Design and source import','design-editor','design/**/wide-light-selected.png','Editable design layers, reusable components and inspector controls'),
 ('Design and source import','engineering-components','design/**/engineering-components.png','Engineering component library and connected diagrams'),
 ('Design and source import','design-system','workspace-six/**/design-system.png','Shared color, type and spacing tokens; reusable components and variants'),
 ('Design and source import','design-layout','workspace-six/**/design-system-canvas.png','Reusable instances and automatic frame layout'),
 ('Design and source import','design-import','design-import/**/review.png','Source-to-design draft review before adding editable layers'),
 ('Design and source import','selective-import','design-import/**/selective-review.png','Selective re-import, source changes and preserved manual edits'),
 ('Design and source import','design-health','design-intelligence/**/health-light.png','Source-link health checks and actionable design findings'),
 ('Containers and observability','docker-map','containers/**/docker-map.png','Docker containers, images and network relationships'),
 ('Containers and observability','kubernetes-map','containers/**/kubernetes-map.png','Kubernetes workloads, services and pods'),
 ('Containers and observability','cluster-health','containers/**/cluster-health-light.png','Cluster health and failing workloads'),
 ('Containers and observability','container-logs','containers/**/logs-structured.png','Searchable runtime logs and structured fields'),
 ('Containers and observability','loki-history','containers/**/loki-history.png','Retained Loki history and LogQL queries'),
 ('Containers and observability','container-metrics','workspace-six/**/container-metrics.png','CPU, memory, restarts, latency, errors and correlated events; sample data'),
 ('Containers and observability','container-recovery','containers/**/rollback-review.png','Review a deployment rollback before applying it'),
 ('Layouts, recovery and updates','saved-layouts','workspace-six/**/design-layout.png','Named layouts and focused split workspaces'),
 ('Layouts, recovery and updates','draft-recovery','recovery/**/recovered-draft.png','Restore unsaved editor work after restart'),
 ('Layouts, recovery and updates','app-updates','history-updates/**/updates-available.png','Version details, release notes and update review; fixture feed'),
]
records=[]
for group,name,pattern,caption in items:
    if pattern.startswith('extra:'):
        candidates=[args.extras/pattern.removeprefix('extra:')]
    else:
        candidates=sorted(args.artifacts.glob(pattern))
    if not candidates or not candidates[-1].is_file():
        raise SystemExit('Missing screenshot for '+name+': '+pattern)
    source=candidates[-1]
    if source.stat().st_size<3000: raise SystemExit('Empty screenshot: '+str(source))
    destination=images/(name+'.png')
    shutil.copy2(source,destination)
    records.append(dict(group=group,feature=name,caption=caption,image='docs/images/'+destination.name,capture=pattern))

# These existing real-app captures cover agent and research screens independently.
for group,name,file,caption in [
 ('Projects, chats and agent work','agents','agents.jpg','Named agents and distinct completed, failed and stopped outcomes'),
 ('Projects, chats and agent work','agent-task','agent-task.jpg','Agent task details, plan, verification and deliverables'),
 ('Projects, chats and agent work','task-queue','task-queue.jpg','Persistent task queue and explicit resume controls'),
 ('Projects, chats and agent work','task-activity','task-activity.jpg','Task activity, approvals and result history'),
 ('Research, knowledge and deliverables','research','research.jpg','Research findings linked to source evidence'),
 ('Getting started and settings','connections','connections.jpg','MCP connections, configuration and connection checks')]:
    if not (images/file).is_file(): raise SystemExit('Missing existing capture: '+file)
    records.append(dict(group=group,feature=name,caption=caption,image='docs/images/'+file,capture='existing native fixture capture'))

for group, name, caption in [
 ('Projects, chats and agent work', 'chat-start', 'A centered new conversation and project-aware draft composer'),
 ('Containers and observability', 'logs-compact', 'Runtime log controls and entries in a 900 by 600 window')]:
    if (images/(name+'.png')).is_file():
        records.append(dict(group=group,feature=name,caption=caption,image='docs/images/'+name+'.png',capture='native visual review with isolated sample data'))

(repo/'docs/screenshot-coverage.json').write_text(json.dumps(dict(note='Real native UI; isolated local projects, sample agent output, fixture monitoring data. No production credentials or clusters.',screenshots=records),indent=2)+'\n')
section=['<!-- gallery:start -->','## Complete screenshot gallery','','Every major workspace area is shown below. Expand a workflow to see its screenshots. Captures use disposable demo projects; agent answers, monitoring history and update feeds are sample data.','']
for group in dict.fromkeys(item[0] for item in items):
    section.extend(['<details>','<summary>'+group+'</summary>',''])
    for record in records:
        if record['group']==group:
            section.extend(['**'+record['caption']+'**','','!['+record['caption']+']('+record['image']+')',''])
    section.extend(['</details>',''])
section.extend(['[Screenshot coverage and capture sources](docs/screenshot-coverage.json) · [Feature guides](docs/README.md)','','<!-- gallery:end -->'])
readme=repo/'README.md';text=readme.read_text();gallery='\n'.join(section)
if '<!-- gallery:start -->' in text:
    start=text.index('<!-- gallery:start -->');end=text.index('<!-- gallery:end -->')+len('<!-- gallery:end -->');text=text[:start]+gallery+text[end:]
else:text=text.replace('## Useful shortcuts',gallery+'\n\n## Useful shortcuts')
readme.write_text(text)
print('Added',len(records),'feature screenshots to README; coverage: docs/screenshot-coverage.json')
