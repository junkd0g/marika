# Marika

**A native macOS workspace for Codex and Claude Code.**

Keep conversations, code, local previews and agent reviews in one window. Organize projects
into spaces, open the tools you need as tabs, and return to your work with drafts intact.

A quiet, rounded workspace keeps the focus on your work, with matching light and dark
appearances and compact controls for smaller windows.

[![macOS checks](https://github.com/junkd0g/marika/actions/workflows/ci.yml/badge.svg)](https://github.com/junkd0g/marika/actions/workflows/ci.yml)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-24292f)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

[Get started](#get-started) · [Design & Kubernetes](#design-and-infrastructure-in-action) · [Screenshot tour](#complete-screenshot-gallery) · [Documentation](docs/README.md) · [Development](#development)

![Marika in dark mode: a project conversation, named view shortcuts, open tabs and spaces in the sidebar](docs/images/workspace.png)

*Screenshots show the real app using a local demo project and sample conversations.*

## Design and infrastructure in action

Draw editable systems, turn designs into implementation work, and inspect the services that run them.
These are native app captures with isolated demo projects and sample monitoring data. Click an image to view it full size.

| Design an editable architecture | Explore Kubernetes resources |
| --- | --- |
| [![Editable service architecture with clients, a gateway, workers and data stores](docs/images/design-architecture.png)](docs/images/design-architecture.png) | [![Kubernetes services, workloads and pods connected in a topology map](docs/images/kubernetes-map.png)](docs/images/kubernetes-map.png) |
| **Manage components and design tokens** | **Compare metrics with deployment events** |
| [![Shared colors, typography, spacing and reusable component variants](docs/images/design-system.png)](docs/images/design-system.png) | [![CPU, memory, restarts, latency and errors with a selected deployment time](docs/images/metrics-events.png)](docs/images/metrics-events.png) |
| **Turn a design into implementation work** | **Inspect workload state and controls** |
| [![Requirements and acceptance criteria linked to selected design elements](docs/images/design-to-ticket.png)](docs/images/design-to-ticket.png) | [![Kubernetes workload list with deployment details and replica controls](docs/images/kubernetes-workload.png)](docs/images/kubernetes-workload.png) |
| **Import a design from project source** | **Review a rollback before applying it** |
| [![Source file selection and screenshot references for design import](docs/images/design-source-picker.png)](docs/images/design-source-picker.png) | [![Current and selected Deployment revisions in a rollback review](docs/images/kubernetes-rollback.png)](docs/images/kubernetes-rollback.png) |

[See every workflow in the complete gallery](#complete-screenshot-gallery).

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

When a task finishes, inline result actions open changed files, run checks and launch the preview.
The Browser preview bar shows server status and opens logs beside the page.

Permission modes differ between providers. See [approval modes](docs/approval-modes.md)
for the behavior implemented by each runtime.

## Workspace tour

### A place for each project

**Spaces** group related projects in the sidebar. Choose a name, color and icon, then switch
using the named rows in the sidebar's Spaces list. Each space remembers its last project; projects retain their
conversations, open tabs and editor drafts. Right-click a project to move it to another space.

Each space also has **Notes** with headings, checklists and other editable blocks, and **Tickets**
with a board, priorities, assignees and project links. Both save automatically and support archive/restore.
Link notes to a ticket and choose **Start work** to launch an agent with that context. The ticket's
**Work** tab tracks activity, approvals, blockers, changes and checks. **Accept result** marks it
Done after review; continuing the agent reopens the ticket.
Select text in a note and choose **Create ticket**, or use a block's menu to create one from a
checklist item. Review the prefilled text, choose a project and create it. The source note stays
linked and shows its related tickets with live status.

**Needs attention** brings approvals, blocked agents, failed checks and results awaiting review
into one inbox. Filter to this space or all spaces, open the relevant ticket or chat, and dismiss
handled updates. Resolved issues clear automatically; new failures return. Open it with **⇧⌘I**.

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
through Marika's MCP bridge. Agent access requires explicit sharing permission for each project; the clickable
**Agent access** control turns it off or on for the project and remembers your choice.

![Marika's built-in browser previewing the Copper demo task board, with Chat, Code and Browser tabs open](docs/images/browser-preview.png)

| View | What you can do |
| --- | --- |
| **Chat** | Project channels, agent conversations, attachments, approvals and history search. |
| **Code** | Edit files, preview Markdown, use language tools, and run tests or debug sessions. |
| **Browser** | Preview local work, inspect elements, and send visual feedback to chat. |
| **Agents** | Launch or queue tasks, follow progress and activity, and review isolated changes. |
| **Research** | Inspect sources, compare Claude and Codex, search project knowledge, and turn findings into tasks. |
| **Stats** | Request a code-health review with findings linked to source locations. |
| **Design** | Edit diagrams and screens, manage reusable components and style tokens, and import UI from code with screenshot references. |
| **Containers** | Explore Docker and Kubernetes resources, health, logs, metrics and reviewed recovery actions. |
| **QA** | Review test cases, record browser journeys, run manual or WebKit checks, compare screenshots, file evidence-backed bugs and retest releases. |
| **Changes** | Review diffs, stage hunks, commit, push, and open pull requests. |
| **Terminal** | Run interactive shells in projects and agent worktrees. |
| **Pipelines** | Run supported GitHub Actions jobs locally or native Swift checks. |
| **API** | Work with generated HTTP, GraphQL and gRPC collections and project environments. |

Save named workspace layouts from the layout button beside **+**, or select Design, Debug, Services and Review in the command palette.

Every tool remains available from the **+** menu at any window size.

<!-- gallery:start -->
## Complete screenshot gallery

Every major workspace area is shown below. Expand a workflow to see its screenshots. Captures use disposable demo projects; agent answers, monitoring history and update feeds are sample data.

<details>
<summary>Getting started and settings</summary>

**Welcome checklist and provider readiness**

![Welcome checklist and provider readiness](docs/images/welcome.png)

**Settings, provider configuration and editor preferences**

![Settings, provider configuration and editor preferences](docs/images/settings.png)

**MCP connections, configuration and connection checks**

![MCP connections, configuration and connection checks](docs/images/connections.jpg)

</details>

<details>
<summary>Projects, chats and agent work</summary>

**A centered new conversation and project-aware draft composer**

![A centered new conversation and project-aware draft composer](docs/images/chat-start.png)

**Project conversation, model, reasoning and speed controls**

![Project conversation, model, reasoning and speed controls](docs/images/chat-controls.png)

**Approvals, blocked work and results needing attention**

![Approvals, blocked work and results needing attention](docs/images/attention.png)

**Search saved messages across projects**

![Search saved messages across projects](docs/images/chat-history.png)

**Named agents and distinct completed, failed and stopped outcomes**

![Named agents and distinct completed, failed and stopped outcomes](docs/images/agents.jpg)

**Agent task details, plan, verification and deliverables**

![Agent task details, plan, verification and deliverables](docs/images/agent-task.jpg)

**Persistent task queue and explicit resume controls**

![Persistent task queue and explicit resume controls](docs/images/task-queue.jpg)

**Task activity, approvals and result history**

![Task activity, approvals and result history](docs/images/task-activity.jpg)

</details>

<details>
<summary>Notes and tickets</summary>

**Editable notes with headings, lists and checklists**

![Editable notes with headings, lists and checklists](docs/images/notes.png)

**Ticket board, priorities and project links**

![Ticket board, priorities and project links](docs/images/tickets.png)

**Ticket work, checks, acceptance and linked agent activity**

![Ticket work, checks, acceptance and linked agent activity](docs/images/ticket-work.png)

</details>

<details>
<summary>Code, review and debugging</summary>

**Markdown source and rendered preview together**

![Markdown source and rendered preview together](docs/images/markdown.png)

**Native test explorer, results and coverage**

![Native test explorer, results and coverage](docs/images/code-tests.png)

**Breakpoints, paused execution and watch values**

![Breakpoints, paused execution and watch values](docs/images/debugger.png)

**Review and accept isolated agent changes**

![Review and accept isolated agent changes](docs/images/changes-review.png)

**Interactive project terminal**

![Interactive project terminal](docs/images/terminal.png)

</details>

<details>
<summary>Browser, APIs and pipelines</summary>

**Pipeline discovery and saved run output; sample history**

![Pipeline discovery and saved run output; sample history](docs/images/pipelines.png)

**API request editing and local response inspection**

![API request editing and local response inspection](docs/images/api-playground.png)

</details>

<details>
<summary>Research, knowledge and deliverables</summary>

**Compare independent answers and their synthesis; sample analysis**

![Compare independent answers and their synthesis; sample analysis](docs/images/compare-models.png)

**Search and review project knowledge**

![Search and review project knowledge](docs/images/knowledge.png)

**Report preview, review comments and export**

![Report preview, review comments and export](docs/images/report.png)

**Spreadsheet deliverable preview and export**

![Spreadsheet deliverable preview and export](docs/images/spreadsheet.png)

**Presentation deliverable preview and export**

![Presentation deliverable preview and export](docs/images/presentation.png)

**Research findings linked to source evidence**

![Research findings linked to source evidence](docs/images/research.jpg)

</details>

<details>
<summary>Design and source import</summary>

**Editable service architecture from a built-in template**

![Editable service architecture from a built-in template](docs/images/design-architecture.png)

**Templates for system context, service architecture, request flow and deployment**

![Templates for system context, service architecture, request flow and deployment](docs/images/design-templates.png)

**Review requirements and acceptance criteria linked to selected design elements**

![Review requirements and acceptance criteria linked to selected design elements](docs/images/design-to-ticket.png)

**Choose source files and screenshot references before generating a design draft**

![Choose source files and screenshot references before generating a design draft](docs/images/design-source-picker.png)

**Editable design layers, reusable components and inspector controls**

![Editable design layers, reusable components and inspector controls](docs/images/design-editor.png)

**Engineering component library and connected diagrams**

![Engineering component library and connected diagrams](docs/images/engineering-components.png)

**Shared color, type and spacing tokens; reusable components and variants**

![Shared color, type and spacing tokens; reusable components and variants](docs/images/design-system.png)

**Reusable instances and automatic frame layout**

![Reusable instances and automatic frame layout](docs/images/design-layout.png)

**Source-to-design draft review before adding editable layers**

![Source-to-design draft review before adding editable layers](docs/images/design-import.png)

**Selective re-import, source changes and preserved manual edits**

![Selective re-import, source changes and preserved manual edits](docs/images/selective-import.png)

**Source-link health checks and actionable design findings**

![Source-link health checks and actionable design findings](docs/images/design-health.png)

</details>

<details>
<summary>Quality assurance</summary>

**Recorded browser journey with verified checkpoints and visual comparison**

![Recorded browser journey with verified checkpoints and visual comparison](docs/images/qa-replay.jpg)

**Manual test results with screenshot evidence and linked bugs**

![Manual test results with screenshot evidence and linked bugs](docs/images/qa-manual-run.jpg)

**Release coverage includes draft, untested and outdated cases**

![Release coverage includes draft, untested and outdated cases](docs/images/qa-release.jpg)

**Inspect highlighted visual changes against an approved baseline**

![Inspect highlighted visual changes against an approved baseline](docs/images/qa-visual.jpg)

</details>

<details>
<summary>Containers and observability</summary>

**Inspect Kubernetes workload status, images, replicas and available actions**

![Inspect Kubernetes workload status, images, replicas and available actions](docs/images/kubernetes-workload.png)

**Read pod logs and related events while investigating a failure**

![Read pod logs and related events while investigating a failure](docs/images/kubernetes-diagnostics.png)

**Compare the current Deployment with a selected revision before confirming rollback**

![Compare the current Deployment with a selected revision before confirming rollback](docs/images/kubernetes-rollback.png)

**Compare resource metrics with deployment events; sample monitoring history**

![Compare resource metrics with deployment events; sample monitoring history](docs/images/metrics-events.png)

**Runtime log controls and entries in a 900 by 600 window**

![Runtime log controls and entries in a 900 by 600 window](docs/images/logs-compact.png)

**Docker containers, images and network relationships**

![Docker containers, images and network relationships](docs/images/docker-map.png)

**Kubernetes workloads, services and pods**

![Kubernetes workloads, services and pods](docs/images/kubernetes-map.png)

**Cluster health and failing workloads**

![Cluster health and failing workloads](docs/images/cluster-health.png)

**Searchable runtime logs and structured fields**

![Searchable runtime logs and structured fields](docs/images/container-logs.png)

**Retained Loki history and LogQL queries**

![Retained Loki history and LogQL queries](docs/images/loki-history.png)

**CPU, memory, restarts, latency, errors and correlated events; sample data**

![CPU, memory, restarts, latency, errors and correlated events; sample data](docs/images/container-metrics.png)

**Review a deployment rollback before applying it**

![Review a deployment rollback before applying it](docs/images/container-recovery.png)

</details>

<details>
<summary>Layouts, recovery and updates</summary>

**Named layouts and focused split workspaces**

![Named layouts and focused split workspaces](docs/images/saved-layouts.png)

**Restore unsaved editor work after restart**

![Restore unsaved editor work after restart](docs/images/draft-recovery.png)

**Version details, release notes and update review; fixture feed**

![Version details, release notes and update review; fixture feed](docs/images/app-updates.png)

</details>

[Screenshot coverage and capture sources](docs/screenshot-coverage.json) · [Feature guides](docs/README.md)

<!-- gallery:end -->

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
