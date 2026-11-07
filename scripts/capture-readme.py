#!/usr/bin/env python3
"""Capture the real app with disposable demo projects and sample conversations.

Build with `swift build` first. Uses no AI provider requests or personal app data.
"""
import functools
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import uuid

repo = Path(__file__).resolve().parents[1]
output = repo / 'docs/images'
output.mkdir(parents=True, exist_ok=True)

swift_source = '''import SwiftUI

struct TaskListView: View {
    @State private var selectedStatus: TaskStatus = .all
    private let tasks = Task.samples

    private var visibleTasks: [Task] {
        tasks.filter { selectedStatus == .all || $0.status == selectedStatus }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Your next great idea.")
                    .font(.largeTitle.bold())
                Spacer()
                Button("New task", systemImage: "plus") { }
            }

            Picker("Status", selection: $selectedStatus) {
                ForEach(TaskStatus.allCases) { status in
                    Text(status.title).tag(status)
                }
            }
            .pickerStyle(.segmented)

            ForEach(visibleTasks) { task in
                TaskCard(task: task)
                    .accessibilityLabel(task.title)
            }
        }
        .padding(32)
    }
}
'''

preview = '''<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Copper — Project board</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#faf9f6;color:#25282b;font:15px -apple-system,BlinkMacSystemFont,sans-serif}
main{max-width:1050px;margin:auto;padding:42px}.nav{display:flex;align-items:center;justify-content:space-between;padding-bottom:48px}
.brand{font-size:22px;font-weight:750;letter-spacing:-1px}.mark{display:inline-grid;place-items:center;color:white;background:#c07555;border-radius:11px;width:34px;height:34px;margin-right:9px}
.nav small,.muted{color:#81817a}.eyebrow{font-size:12px;color:#ad6a4c;text-transform:uppercase;letter-spacing:2px;font-weight:650}
h1{font-size:44px;line-height:1.12;letter-spacing:-2px;margin:12px 0}p{color:#777972;line-height:1.6}.heading{display:flex;justify-content:space-between;align-items:center}
button{border:0;background:#303c37;color:white;padding:12px 18px;border-radius:9px;font:inherit;font-size:13px}.filters{display:flex;gap:8px;margin:27px 0}
.filter{padding:8px 14px;border:1px solid #e5e3dc;border-radius:8px;color:#74766f;font-size:12px}.active{background:#e9ede7;color:#35493e;border-color:#d6ded1}
.cards{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:16px}.card{min-width:0;background:white;border:1px solid #e7e5de;border-radius:14px;padding:22px;min-height:230px;display:flex;flex-direction:column}
.tag{font-size:11px;width:max-content;padding:5px 9px;border-radius:6px;background:#f4e8dc;color:#a16b3b}.green{background:#e7eee4;color:#5c7652}.blue{background:#e7ecf5;color:#58719b}
.card h2{font-size:19px;line-height:1.35;margin-top:22px;overflow-wrap:anywhere}.card p{font-size:13px;margin-top:0}.footer{display:flex;align-items:center;justify-content:space-between;font-size:11px;color:#99998e;margin-top:auto;padding-top:22px}
.avatar{width:26px;height:26px;border-radius:50%;background:#eddfd4;color:#9d6d4f;display:grid;place-items:center;font-weight:650}.note{font-size:12px;color:#96998d;margin-top:28px}
@media(max-width:700px){main{padding:28px}.cards{grid-template-columns:1fr}.heading{display:block}h1{font-size:36px}.nav{padding-bottom:32px}}
</style><main>
<div class="nav"><div class="brand"><span class="mark">c</span>copper</div><small>Workspace / Product design</small></div>
<div class="heading"><div><div class="eyebrow">Make space for good work</div><h1>Your next great idea.</h1><p>A little clarity for everything you're building.</p></div><button>＋ New task</button></div>
<div class="filters"><span class="filter active">All tasks · 3</span><span class="filter">In progress</span><span class="filter">In review</span><span class="filter">Done</span></div>
<div class="cards">
<article class="card"><span class="tag">In progress</span><h2>A calmer project overview</h2><p>Give every task a clear status, owner, and next step.</p><div class="footer"><span class="avatar">AL</span><span>Product · Today</span></div></article>
<article class="card"><span class="tag blue">In review</span><h2>Keyboard-friendly navigation</h2><p>Move between projects and keep unfinished work close.</p><div class="footer"><span class="avatar">SK</span><span>Engineering · Tomorrow</span></div></article>
<article class="card"><span class="tag green">Ready to ship</span><h2>Details that feel right</h2><p>A final pass on spacing, contrast, and the small things.</p><div class="footer"><span class="avatar">MR</span><span>Design · Friday</span></div></article>
</div><div class="note">A small team. A shared direction. Room to focus.</div></main></html>'''


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


with tempfile.TemporaryDirectory(prefix='marika-readme-') as temporary:
    root = Path(temporary)
    data, project = root / 'data', root / 'Copper'
    (data / 'transcripts').mkdir(parents=True)
    (project / 'Sources').mkdir(parents=True)
    (project / 'Sources/TaskListView.swift').write_text(swift_source)
    (project / 'Sources/Task.swift').write_text('''import Foundation

enum TaskStatus: String, CaseIterable, Identifiable {
    case all, inProgress, inReview, done
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All tasks"
        case .inProgress: "In progress"
        case .inReview: "In review"
        case .done: "Done"
        }
    }
}

struct Task: Identifiable {
    let id = UUID()
    let title: String
    let status: TaskStatus
    static let samples = [
        Task(title: "A calmer project overview", status: .inProgress),
        Task(title: "Keyboard-friendly navigation", status: .inReview),
        Task(title: "Details that feel right", status: .done),
    ]
}
''')
    (project / 'Sources/TaskCard.swift').write_text('''import SwiftUI

struct TaskCard: View {
    let task: Task
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(task.status.title).font(.caption).foregroundStyle(.secondary)
            Text(task.title).font(.headline)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }
}
''')
    (project / 'README.md').write_text('# Copper\n\nA little clarity for everything you are building.\n\n## This week\n\n- [x] Simplify the project overview\n- [x] Add status filters\n- [ ] Review the mobile layout\n')
    (project / 'index.html').write_text(preview)
    work, personal = str(uuid.uuid4()), '00000000-0000-0000-0000-000000000001'
    pid, sid = str(uuid.uuid4()), str(uuid.uuid4())
    projects = [dict(id=pid, path=str(project), name='Copper', spaceID=work, conversationSessionID=sid,
                     layout=dict(panel='Conversation', openTabs=['Conversation', 'Code', 'Browser'], showsInspector=False))]
    for name, space in [('Fieldnotes', work), ('Weekend', personal)]:
        folder = root / name
        folder.mkdir()
        projects.append(dict(id=str(uuid.uuid4()), path=str(folder), name=name, spaceID=space))
    stamp = '2026-11-07T10:00:00Z'
    workspace = dict(projects=projects, selectedSpaceID=work, selectedProjectID=pid,
                     spaces=[dict(id=personal, name='Personal', color='teal', symbol='house.fill'),
                             dict(id=work, name='Work', color='violet', symbol='briefcase.fill', lastProjectID=pid)],
                     sessions=[dict(id=sid, projectID=pid, agent='codex', title='A calmer project overview',
                                    mode='ask', createdAt=stamp, updatedAt=stamp)])
    (data / 'workspace.json').write_text(json.dumps(workspace))
    messages = [
        dict(id='demo-user', date=stamp, content=dict(user=dict(text='Make the task board easier to scan. Give each card a clear status, owner, and next step.', images=[]))),
        dict(id='demo-read', date=stamp, content=dict(tool={'_0': dict(id='demo-read', name='read_file', kind='read', title='Read TaskListView.swift',
            detail='Sources/TaskListView.swift', input=dict(path='Sources/TaskListView.swift'), output=swift_source,
            status='succeeded', diff=[], startedAt=stamp, finishedAt=stamp)})),
        dict(id='demo-answer', date=stamp, content=dict(assistant=dict(text='The board now has a clearer hierarchy:\n\n- **Status first** — a small color-coded label on every card.\n- **Less visual noise** — consistent spacing and one clear title.\n- **Useful details** — owner and timing grouped at the bottom.\n\nOpen **Code** to review the view, or **Browser** to try the layout.'))),
    ]
    (data / 'transcripts' / (sid + '.json')).write_text(json.dumps(messages))
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(QuietHandler, directory=str(project)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = 'http://127.0.0.1:' + str(server.server_port)
    steps = [dict(op='wait', seconds=.8), dict(op='agentsMock'), dict(op='composerMock'), dict(op='size', width=1280, height=700),
             dict(op='appearance', dark=True), dict(op='shortcut', key='1'), dict(op='state'), dict(op='wait', seconds=.3),
             dict(op='shot', path=str(output / 'workspace.png')),
             dict(op='size', width=1280, height=760),
             dict(op='codeOpen', path='README.md'), dict(op='codeOpen', path='Sources/TaskListView.swift'),
             dict(op='appearance', dark=False), dict(op='shortcut', key='2'), dict(op='wait', seconds=.5), dict(op='shot', path=str(output / 'code-editor.png')),
             dict(op='size', width=1280, height=840),
             dict(op='browserOpen', url=url), dict(op='browserWait'), dict(op='appearance', dark=True), dict(op='shortcut', key='3'),
             dict(op='browserJS', script="if (document.documentElement.scrollWidth > innerWidth + 1) { throw new Error('Demo layout overflows'); }"),
             dict(op='wait', seconds=.4), dict(op='shot', path=str(output / 'browser-preview.png')), dict(op='quit')]
    script = root / 'steps.json'
    script.write_text(json.dumps(steps))
    log = repo / 'build/readme-capture.log'
    log.parent.mkdir(exist_ok=True)
    try:
        with log.open('w') as stream:
            result = subprocess.run([str(repo / '.build/debug/Marika')],
                env=dict(os.environ, MARIKA_DATA=str(data), MARIKA_DRIVER=str(script), MARIKA_DEMO='1',
                         MARIKA_EDITOR_DEFAULTS_SUITE='marika.readme.' + str(uuid.uuid4())),
                stdout=stream, stderr=subprocess.STDOUT, timeout=75)
        content = log.read_text()
        assert result.returncode == 0 and '[driver] FAILED' not in content, log
        assert '"items":3' in content.replace(' ', ''), 'Sample conversation did not load: ' + str(log)
        for name in ['workspace.png', 'code-editor.png', 'browser-preview.png']:
            assert (output / name).stat().st_size > 20_000, 'Screenshot is missing or empty: ' + name
            print('Captured', output / name)
    finally:
        server.shutdown()
        server.server_close()
