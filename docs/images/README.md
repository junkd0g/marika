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
| `split-workspace.jpg` | Chat beside Code | Feature-tour fixture, Chat → Code tab context menu → Split Code right |
| `stacked-workspace.jpg` | Chat above Code | Feature-tour fixture, Code tab context menu → Split Code bottom |

The first three images come from the existing Copper demo capture. The other six were captured
from the current debug app on 8 November 2026. They contain preloaded sample task outcomes and a
sample review; no model generated those results during capture. The two split images document
the layouts created by the context-menu actions, rather than a verified drag gesture.

Prepare the feature-tour fixture as described in the [development guide](../development.md#feature-tour-screenshots).
Capture the app window through native screenshot controls, review the image at full size, and
save the image in the format indicated by its filename. Keep the complete workspace visible so the tab and view
controls are understandable. Verify the captions and relative links in the tour after replacing
an image.
