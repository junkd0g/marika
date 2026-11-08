# Documentation images

[Screenshot tour](../screenshots.md) · [Development guide](../development.md#refresh-the-screenshots)

All images are native app captures with sample data. Do not replace them with captures of
personal workspaces, account details, real chats, tokens or private source code.

| Image | Subject | Refresh source |
| --- | --- | --- |
| `workspace.png` | Spaces, project navigation and Chat | `scripts/capture-readme.py` |
| `code-editor.png` | Code editor in light appearance | `scripts/capture-readme.py` |
| `browser-preview.png` | Local browser preview | `scripts/capture-readme.py` |
| `chat-agents.jpg` | Project channel and named agent conversations | Feature-tour fixture, Chat tab |
| `agents.jpg` | Completed, failed and stopped sample tasks | Feature-tour fixture, Agents → All |
| `agents-attention.jpg` | Failed task needing attention | Feature-tour fixture, Agents → Needs attention |
| `code-health.jpg` | Published sample review | Feature-tour fixture, Stats tab |
| `research.jpg` | Answer, source excerpt and a linked implementation task | Isolated Copper product-flow QA fixture, Research |
| `connections.jpg` | Catalog, connection actions and status | Copper QA fixture, Project Settings → Connections |
| `agent-task.jpg` | Task plan, reported changes, test result and deliverables | Copper QA fixture, Agents → Task details, scrolled to results |
| `task-queue.jpg` | Persisted waiting task, paused after restart | Disposable Queue Fixture, Agents → Queue |
| `task-activity.jpg` | Read state, completed turns and a launch failure | Disposable Queue Fixture, Agents → Activity |
| `api-playground.jpg` | Request editor and a real local HTTP response | Copper QA fixture, API with a synthetic loopback server |
| `split-workspace.jpg` | Chat beside Code | Feature-tour fixture, Chat → Code tab context menu → Split Code right |
| `stacked-workspace.jpg` | Chat above Code | Feature-tour fixture, Code tab context menu → Split Code bottom |

The first three images come from the existing Copper demo capture. The original six feature-tour images were captured
from the debug app on 8 November 2026. They contain preloaded sample task outcomes and a
sample review; no model generated those results during capture. The two split images document
the layouts created by the context-menu actions, rather than a verified drag gesture.

Prepare the feature-tour fixture as described in the [development guide](../development.md#feature-tour-screenshots).
The three product-flow captures extend that disposable Copper data with a preloaded research
report, a saved plan and walkthrough, and a tiny Go module. The research and task reports were
authored fixture data. The Go test result was actually run through the task page; it does not
verify the sample SwiftUI changes. The connection catalog was captured without external
authorization or testing the vendor endpoints. Use only synthetic content when refreshing them.
The API capture shows an actual successful response from a temporary loopback server using
synthetic task data.

The two queue captures use a separate disposable project and local synthetic agent runners.
Queue order, four-agent capacity, waiting-task pickup, pause/cancel, launch failure, requeue,
read state and restart persistence were exercised through the native app. The failure came
from attempting an isolated launch before the fixture's first Git commit. No model or external
account generated the displayed queue outcomes.

Capture the app window through native screenshot controls, review the image at full size, and
save the image in the format indicated by its filename. Keep the complete workspace visible so the tab and view
controls are understandable. Verify the captions and relative links in the tour after replacing
an image.
