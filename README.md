# Marika

**A native macOS workspace for Codex and Claude Code.**

Keep conversations, code, local previews and agent reviews in one window. Organize projects
into spaces, open the tools you need as tabs, and return to your work with drafts intact.

[![macOS checks](https://github.com/junkd0g/marika/actions/workflows/ci.yml/badge.svg)](https://github.com/junkd0g/marika/actions/workflows/ci.yml)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-24292f)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

[Get started](#get-started) · [Screenshot tour](docs/screenshots.md) · [Documentation](docs/README.md) · [Development](#development)

![Marika in dark mode: a project conversation, named view shortcuts, open tabs and spaces in the sidebar](docs/images/workspace.png)

*Screenshots show the real app using a local demo project and sample conversations.*

## Get started

### 1. Set up your Mac

You need **macOS 15 or later**, **Xcode 26.3 or newer**, and at least one installed agent:

- [Codex CLI](https://developers.openai.com/codex/cli) — install and sign in through Codex.
- [Claude Code](https://code.claude.com/docs/en/overview) — install and sign in through Claude Code.

Marika launches the official CLIs installed on your Mac. Each conversation can use either
provider and keeps its own model and permission settings.

### 2. Build and open Marika

```bash
git clone https://github.com/junkd0g/marika.git
cd marika
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/build-app.sh release
open build/Marika.app
```

The build script uses a local Apple Development identity when available and signs ad hoc
otherwise. You do not need a signing identity to build locally.

### 3. Open your first project

On first launch, the Welcome checklist helps you install and sign in to one agent, choose a
project folder, and open Chat with **Start Working**. **Explore in Editor** opens the project
before an agent is connected. Return to the checklist through **Help → Getting Started**.
If another agent is already ready, **Use Claude/Codex** switches setup to it. CLI sign-in
shows waiting and verification progress, with **Check Again** and **Retry Sign In** when needed.

1. Choose **Open Project** or press **⌘O**, then select a folder.
2. Open **Settings → Agents** to check agent availability and sign-in status.
3. Choose the provider, model and permission mode in Chat, then send your task.
4. Use **+** in the tab row to open **Code**, **Browser**, **Stats**, or another view. Keyboard shortcuts and dragging tabs into splits are supported.

When a task finishes, **Review Work** brings reported files, recorded checks, and preview actions
together. The Browser preview bar shows server status and opens logs beside the page.

Permission modes differ between providers. See [approval modes](docs/approval-modes.md)
for the behavior implemented by each runtime.

## Workspace tour

### A place for each project

**Spaces** group related projects in the sidebar. Choose a name, color and icon, then switch
using the named rows in the sidebar's Spaces list. Each space remembers its last project; projects retain their
conversations, open tabs and editor drafts. Right-click a project to move it to another space.

Each space also has **Notes** with headings, checklists and other editable blocks, and **Tickets**
with a board, priorities, assignees and project links. Both save automatically and support archive/restore.

The **+** menu in the tab row opens tools. **Chat** stays visible on the left; tool tabs can be
closed, reordered and reopened. Closing a tab keeps its unsaved files and running tasks.
Keyboard shortcuts open views directly. Drag a tab to a workspace edge to arrange a split,
or use the tab's directional **Split** context-menu actions.

### From a conversation to working code

Use Claude or Codex per conversation, follow tool activity and approvals, and keep separate
agent chats within a project. Codex exposes model, reasoning effort and speed as separate
controls. Search saved messages across projects with **⇧⌘H** and jump to the original message.

The editor includes file tabs, syntax highlighting, language-server assistance, Markdown
preview and split editing. **Changes** provides Git diffs, staging, commits and pushes.
Task agents can work in isolated Git worktrees, with changes reviewed and accepted per hunk.

![Marika in light mode: a Swift file open in Code, with project spaces, file navigation and labeled tool buttons](docs/images/code-editor.png)

### Preview, review and iterate

Open a local server or project HTML file in **Browser**, check desktop or mobile layouts,
and attach element feedback or screenshots to a chat draft. Agents can use the same browser
through Marika's MCP bridge; access to external sites is controlled in the browser toolbar.

![Marika's built-in browser previewing the Copper demo task board, with Chat, Code and Browser tabs open](docs/images/browser-preview.png)

| View | What you can do |
| --- | --- |
| **Chat** | Project channels, agent conversations, attachments, approvals and history search. |
| **Code** | Edit files, preview Markdown, use language tools, and run tests or debug sessions. |
| **Browser** | Preview local work, inspect elements, and send visual feedback to chat. |
| **Agents** | Launch or queue tasks, follow progress and activity, and review isolated changes. |
| **Research** | Inspect sources, compare Claude and Codex, search project knowledge, and turn findings into tasks. |
| **Stats** | Request a code-health review with findings linked to source locations. |
| **Changes** | Review diffs, stage hunks, commit, push, and open pull requests. |
| **Terminal** | Run interactive shells in projects and agent worktrees. |
| **Pipelines** | Run supported GitHub Actions jobs locally or native Swift checks. |
| **API** | Work with generated HTTP, GraphQL and gRPC collections and project environments. |

Every tool remains available from the **+** menu at any window size.

## Useful shortcuts

| Action | Shortcut |
| --- | --- |
| Open a project | **⌘O** |
| Find a file / search project contents | **⌘P** / **⇧⌘F** |
| Search chat history | **⇧⌘H** |
| Open the command palette | **⌘K** |
| Cycle open project tabs | **⌃Tab** / **⌃⇧Tab** |
| Open or select a project view | **⌘1–9** · **⌘0** for Research |
| Switch spaces | **⌃⌥←** / **⌃⌥→** |
| Launch an agent | **⇧⌘N** |
| Save / find in the current file | **⌘S** / **⌘F** |

## Documentation

Use [Compare models](docs/tools.md#compare-models), maintain [project knowledge](docs/tools.md#project-knowledge-and-reviewed-memory),
and create [reports, spreadsheets and presentations](docs/tools.md#rich-deliverables-and-exports) with native previews and exports.

Start with the [documentation index](docs/README.md) or the [feature tour in screenshots](docs/screenshots.md).

| Guide | Covers |
| --- | --- |
| [Spaces, conversations and agents](docs/workspace.md) | Project navigation, models, jobs, delegation, MCP, memory and remote workspaces. |
| [Editing, reviewing and debugging](docs/editor.md) | Files, Markdown, language tools, Git review, terminals, tests and debugging. |
| [Browser, reviews, APIs and pipelines](docs/tools.md) | Local previews, browser access, code-health reviews, API collections and local CI. |
| [Saved work, recovery and updates](docs/recovery-and-updates.md) | Draft recovery, backups, checkpoints, artifacts, version information and update checks. |
| [Approval modes](docs/approval-modes.md) | What each provider's permissions mean in Marika. |
| [Development, testing and releases](docs/development.md) | Architecture, fixtures, screenshot capture, signing and update packaging. |

## Development

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --no-parallel
scripts/build-app.sh release
codesign --verify --deep --strict build/Marika.app
```

Core tests use temporary projects and fixtures. Live provider tests are opt-in. Native UI
checks cover spaces, tabs, editor drafts, chat history and responsive layouts. See the
[development guide](docs/development.md) for the full test commands and screenshot workflow.

## Project status and contributing

Marika is in **early development (0.1.0)** and is currently built from source. Version information,
release notes and manual update checks are available in the app. Signed in-app installation
requires a configured update feed and published signed release; see the
[release instructions](docs/development.md#signed-app-updates).

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md), use
[GitHub issues](https://github.com/junkd0g/marika/issues) for bugs and feature requests, and follow
[SECURITY.md](SECURITY.md) for private vulnerability reports.

**MIT licensed.** See [LICENSE](LICENSE) and the third-party notices in [Resources](Resources).
