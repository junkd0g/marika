#!/usr/bin/env python3
"""Prepare disposable feature-tour data without launching or controlling the app."""
import argparse
import json
from pathlib import Path
import shlex
import tempfile
import uuid


def prepare(root):
    data, project = root / 'data', root / 'Copper'
    (data / 'transcripts').mkdir(parents=True)
    (project / 'Sources').mkdir(parents=True)
    source = r'''import SwiftUI

struct TaskBoard: View {
    @State private var tasks: [String] = []
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Your next great idea.")
                .font(.largeTitle.bold())

            if isLoading {
                ProgressView("Loading tasks…")
            } else if tasks.isEmpty {
                Text("No tasks yet. Create your first task.")
            } else {
                ForEach(tasks, id: \.self) { task in
                    Label(task, systemImage: "checkmark.circle")
                }
            }
        }
        .padding(24)
    }
}
'''
    readme = ('# Copper\n\nA sample project for the Marika feature tour.\n\n## Tasks\n\n'
              '- [x] Add empty and loading states\n- [ ] Show failed requests with a retry action\n'
              '- [ ] Review the narrow layout\n')
    (project / 'Sources/TaskBoard.swift').write_text(source)
    (project / 'README.md').write_text(readme)
    pid, channel, completed, failed, stopped, scan = [str(uuid.uuid4()).upper() for _ in range(6)]
    space = '00000000-0000-0000-0000-000000000001'
    stamp = '2026-11-08T10:00:00Z'
    samples = [
        (channel, 'Plan the task board', None,
         'The board needs three clear states:\n\n- **Empty:** explain what to do next.\n'
         '- **Loading:** show that the request is in progress.\n- **Failed:** show the error and offer a retry.\n\n'
         'Open **Agents** for task outcomes, or **Code** to review the view.', 'completed'),
        (completed, 'Board states', 'Add clear empty and loading states to the task board.',
         'Added empty and loading states. The changes are ready for review.', 'completed'),
        (failed, 'Verify the board', 'Run the demo verification command.',
         'Demo verification could not start: sample-runner is unavailable.', 'failed'),
        (stopped, 'Layout review', 'Inspect the narrow layout and report findings.',
         'Inspected the initial layout before this task was stopped.', 'interrupted'),
    ]
    sessions = []
    for identity, title, prompt, reply, outcome in samples:
        meta = dict(id=identity, projectID=pid, agent='codex', title=title, mode='ask', createdAt=stamp, updatedAt=stamp)
        if prompt:
            meta['agentTask'] = dict(prompt=prompt, parentSessionID=channel)
        sessions.append(meta)

        def item(content):
            return dict(id=str(uuid.uuid4()), date=stamp, content=content)

        text = prompt or 'Make the board easy to scan. Give empty, loading and failed requests a clear next action.'
        items = [item(dict(user=dict(text=text, images=[])))]
        if identity == failed:
            items.append(item(dict(notice={'_0': dict(level='error', text=reply)})))
        else:
            items += [item(dict(assistant=dict(text=reply))),
                      item(dict(turnEnd={'_0': dict(outcome=outcome, durationMs=1200)}))]
        (data / 'transcripts' / (identity + '.json')).write_text(json.dumps(items))

    review = dict(summary='Sample review: the demo view shows empty and loading states, but a failed request still needs its own message and retry action.',
                  inspectedFiles=['Sources/TaskBoard.swift', 'README.md'], findings=[dict(
                      title='Show a failed request separately from an empty board', severity='medium', category='correctness',
                      path='Sources/TaskBoard.swift', line=15, evidence='} else if tasks.isEmpty {',
                      impact='When a request fails, the demo view can show No tasks yet instead of explaining the error.',
                      action='Render loadError before the empty state and offer a retry action. Add a test for a failed request with no cached tasks.')])
    lines = len(source.splitlines())
    inventory = dict(sourceLines=lines, testLines=0, testFiles=0, generatedLines=0, generatedFiles=0, excludedFiles=0,
                     modules={'Sources': lines}, largestFiles=[dict(path='Sources/TaskBoard.swift', lines=lines)], markers=[])
    layout = dict(panel='Agents', openTabs=['Conversation', 'Code', 'Agents', 'Stats'], showsInspector=False,
                  files=[dict(path='README.md', line=1, column=1), dict(path='Sources/TaskBoard.swift', line=1, column=1)],
                  selectedFile='Sources/TaskBoard.swift')
    project_meta = dict(id=pid, path=str(project), name='Copper', spaceID=space, conversationSessionID=channel,
                        chatSessionID=channel, layout=layout, chatReadDates={s['id']: stamp for s in sessions}, scans=[dict(
                            id=scan, date=stamp, agentSessionID=completed, files=2, linesByLanguage={'Swift': lines, 'Markdown': len(readme.splitlines())},
                            markerLines=0, skipped=0, limited=False, provider='codex', inventory=inventory, review=review)])
    workspace = dict(projects=[project_meta], sessions=sessions, selectedProjectID=pid, selectedSpaceID=space,
                     spaces=[dict(id=space, name='Demo', symbol='square.grid.2x2.fill', color='teal', lastProjectID=pid)])
    (data / 'workspace.json').write_text(json.dumps(workspace))
    (root / 'driver.json').write_text(json.dumps([dict(op='agentsMock', seconds=600)]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', nargs='?', type=Path, help='New or empty destination (defaults to a temporary directory).')
    args = parser.parse_args()
    root = args.directory.expanduser().resolve() if args.directory else Path(tempfile.mkdtemp(prefix='marika-feature-tour-'))
    if root.exists() and (not root.is_dir() or any(root.iterdir())):
        parser.error('Choose a new or empty directory; existing files will not be overwritten.')
    root.mkdir(parents=True, exist_ok=True)
    prepare(root)
    binary = Path(__file__).resolve().parents[1] / '.build/debug/Marika'
    print('Prepared sample feature-tour data:', root)
    print('After swift build, launch the isolated debug app with:')
    print('MARIKA_DEMO=1 MARIKA_DATA=' + shlex.quote(str(root / 'data'))
          + ' MARIKA_DRIVER=' + shlex.quote(str(root / 'driver.json'))
          + ' MARIKA_EDITOR_DEFAULTS_SUITE=' + shlex.quote('marika.feature-tour.' + str(uuid.uuid4()))
          + ' ' + shlex.quote(str(binary)))


if __name__ == '__main__':
    main()
