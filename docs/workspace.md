# Spaces, conversations and agents

[← Back to Marika](../README.md)

Use spaces to group projects, keep conversations with their work, and launch Claude or Codex tasks from the same workspace.

## Spaces and project navigation

Organize projects into **spaces** in the left sidebar. Click anywhere on a named row in the
**Spaces** list to switch; **+** creates one. The active space has a tinted row and checkmark.
Each space remembers its last project, chat, and editor state. New
projects belong to the current space. Right-click a project and choose **Move to Space**.
Use a space's menu to edit its name, icon and color, change its position,
or delete it. Deleting a space moves its projects, notes and tickets to the space named in the confirmation;
files, conversations and ticket IDs are kept. Existing projects start in **Personal**. **⌃⌥← / ⌃⌥→** switch
spaces, and **Navigate → Switch Space** and the command palette list them by name. Running
agents keep working when you switch, with activity dots beside their spaces.

## Notes and tickets in each space

Select **Notes** or **Tickets** in the sidebar. They belong to the selected space and work even
before it contains a project or a connected agent. Content saves automatically with the workspace;
each space remembers which section you last opened.

**Notes** are pages made of editable blocks. Create a note, give it a title, and use **Add Block**
for text, headings, bullet lists, checklists, quotes or code. The block's menu changes its type,
moves it up or down, duplicates it, or removes it. Return creates the next block; Shift-Return
adds a line inside one. Pin notes, search titles and contents, or use **Copy Markdown** to export
text through the clipboard. **Archive** hides a note; open the archive and choose **Restore**
to bring it back.

Select text inside a note block to reveal **Create ticket** in the note toolbar. A block's **…** menu
also offers **Create ticket** for the entire block, including a checklist item. Review the prefilled
title and Markdown description, choose a project from the same space (or leave it unassigned), then
create the ticket. Cancel keeps the note unchanged and creates nothing. Checklist completion stays
as it was. The source note is linked automatically and can be included as context when starting an agent.

Notes show **Linked tickets** below their blocks, with current status and archive labels. Open a
ticket from there, or follow its linked note back to the source. Links and the ticket's copied text
survive restart; editing the note later does not rewrite the ticket description.
Links to archived source notes open the archive automatically; restore the note to edit it again.

**Tickets** have a stable key, title, Markdown description, status, priority, type, assignee text,
and optional project link. Switch between the board and list, search, or filter by priority and
project. Use the card’s menu to move it between Backlog, To Do, In Progress and Done, or change its status
in the editor. Archive/restore tickets without deleting their history. Ticket keys stay the same when
a space is renamed or its content is moved. Moving a project to another space clears old ticket
links to that project; the tickets stay in their own space.

In a ticket's Properties, choose a project and **Link notes** from the same space. **Start work**
opens the agent launch form with the ticket and selected notes included automatically; add optional
instructions, choose a provider and permissions, then start. The ticket moves to In Progress and
its **Work** tab shows live activity, approvals and blockers. Open the agent to respond to an approval
or continue the conversation. The chat's result actions link back to the ticket.

When the agent finishes, review its reply and changed files, then run checks from Work. Failed,
incomplete or outdated checks prevent acceptance. **Accept result** marks the ticket Done; if no
checks have been run, the tab says so and acceptance remains an explicit manual review. Isolated
changes must be applied or rejected in the worktree review before acceptance. Changes to the ticket
title, description, project or linked notes require a new run with the updated context. Continuing an
accepted agent reopens the ticket, including when an older run is resumed. Previous runs and their
saved results stay attached across restarts and after an agent chat is removed.

Notes and tickets are stored locally in Marika's workspace and included in its saved-data backup.

## Design from chat

**Design** sits below **Tickets** in the left sidebar and opens the current project's editable
canvas. You can also open it with **⌘G** or the project tab menu. Shapes, labels and connections
save with the project.

Select an element and fill in **Description** in Properties to explain its purpose, behavior,
or implementation requirements. These notes are separate from the visible label and save with
the element. **Use in Chat** adds the selected elements, descriptions, and visual properties
to the project's chat draft; existing draft text is preserved. With nothing selected, it uses
the visible canvas. Add your request and send it when ready. Agents also receive descriptions
through `project_get_design` and preserve them when updating existing elements.

Ask either Claude or Codex, for example: **“In Design, draw this project's architecture.”**
The agent can read the canvas with `project_get_design` and update it with
`project_publish_design`. Architecture diagrams use labeled shapes and directed connections;
moving or resizing a shape keeps its connections attached. The agent can inspect the project
and publish into Design without creating a report or opening an external design service.
The chat's tool result includes **Open Design**. Canvas edits from another turn or from you
invalidate the agent's previous revision, so it must read again before publishing.

### Importing UI design from source

Open a local project, choose **Design → Import**, and select the UI source files to analyze.
The importer recognizes Swift/SwiftUI/UIKit, Kotlin/Compose, Android XML, HTML/CSS, React
and Vue files. Dependencies and build output are excluded. You can filter the file list,
choose up to 40 files, select your configured Claude or Codex agent/model, and describe a
screen or component to focus on. Imports use saved source; unsaved editor buffers are not sent.

**Generate design draft** runs a dedicated read-only analysis against copies of the selected
files, without loading the project's hooks or MCP configuration. It reconstructs screens,
reusable controls, colors, typography and spacing as native editable layers, with source
links and descriptions. The preview includes the agent's limitations and inferred details;
runtime data and unavailable images can appear as labeled placeholders. This is a
code-derived reconstruction, so inspect the preview against the running UI when fidelity matters.

You can close the sheet while analysis runs, open its conversation for progress or approvals,
and reopen **Import** to review the saved draft. **Add to canvas** places it in a new movable
section beside the existing artwork, saves a version of the previous canvas, and supports
one-step undo. Existing layers are preserved. If selected source changes before acceptance,
generate a fresh draft; a stale analysis cannot be added. Failed or stopped runs leave the
canvas unchanged and can be retried.

### Drawing on the canvas

Tools float at the bottom of the canvas: **Move** (V), **Hand** (H, or hold Space), **Frame** (F),
shapes (**Rectangle** R, **Ellipse** O, **Polygon**, **Star**, **Line** L, **Arrow** ⇧L),
**Text** (T) and **Connector** (C). Drag to draw; hold ⇧ for a square or a 45° line and ⌥ to
draw from the center. Scroll to pan, and pinch or ⌘-scroll to zoom at the pointer. The zoom menu
above the inspector fits the canvas (⇧1) or the selection (⇧2).

- **Engineering components.** Open **Components** above the canvas and search for a service,
  API, worker, database, cache, message queue, object storage, client app, gateway, or external
  system. Click to insert, or drag a card to a position on the canvas. Each component has a
  native icon, editable label and styling, and a starter description marked as a placeholder.
  Components support the same connections, resizing, copy/paste, undo, and export as shapes.
  The component role also reaches chat; agents can publish it with the optional `component`
  field. **Use plain shape** removes the icon and role while keeping the rest of the element.
- **Select and arrange.** Click, ⇧-click or drag a marquee. Drag handles to resize one layer
  or several together (⇧ keeps proportions, ⌥ resizes from the center), drag the knob above a
  layer to rotate it (⇧ for 15° steps), and drag a line's ends to re-aim it. Moving and
  resizing snap to the edges and centers of other layers and show guides; hold ⌘ to place freely.
  ⌥-drag or ⌘D duplicates, arrows nudge, and ⌘C, ⌘X and ⌘V copy between canvases.
- **Text.** Double-click a shape, or press Return, to type its label in place. Click with the
  Text tool to type a new line of text. Return or Escape finishes; ⌥Return adds a line.
- **Frames.** A frame holds the layers drawn above it that sit inside its bounds. Drag a
  frame by its title to move everything in it; clicking inside selects its contents. ⌥⌘G
  wraps the selection in a frame and ⇧⌘G removes a frame but keeps its contents. Deleting,
  duplicating, exporting or using a frame in chat includes what it holds.
- **Connections.** With the Connector tool, drag from one layer to another. Click a
  connection to label, reverse or delete it; it stays attached when its layers move.
  Properties offers automatic or explicit left/right/top/bottom ports and **HTTP / RPC**,
  **Event**, or **Data flow** styles. Drag a label along its route to position it. Connections
  route around nearby boxes; turn off **Route around shapes** for a simpler path. Dense or
  overlapping diagrams can still require moving a box or choosing different ports.
- **Inspector.** Position, size, rotation, opacity, corner radius, text size, weight and
  alignment, fill, stroke (solid, dashed or dotted) and shadow apply to every selected layer;
  a field reads **Mixed** where they differ. Drag a field's label to scrub its value. A single
  layer inside a frame aligns to that frame; three or more layers can be spaced evenly.
- **Layers.** Frames expand into a nested list of their contents. Use the disclosure arrow to
  collapse a frame; selecting a child on the canvas reveals it in the list. Click a row to
  select it, ⌘-click to toggle it, or ⇧-click to select a range. Drag within a frame
  to reorder siblings (moving a frame carries its contents), double-click to rename, and hover
  a row to hide or lock it. A secondary click on the canvas or a layer lists the same actions
  with their shortcuts. Locked contents prevent their frame from being reordered.

At compact widths, **Layers** and **Properties** open as popovers, leaving more space for the
artwork. Zoom and Export remain above the canvas. On wider windows, the panels stay open beside
the canvas. Connections draw above frame backgrounds, so arrows remain visible inside frames
both on screen and in exported PNGs.

Undo history stays with the project while switching tabs or projects, as do zoom and selection.
Locked layers cannot be edited or deleted by the canvas or by chat; unlock them in Layers before
changing them. **Export** saves PNG or SVG, or copies a PNG, of the selection or of every visible
layer. SVG includes editable vector shapes, text, icons, and connections without linked assets;
large PNG exports scale down to keep image memory bounded. Canvases saved by earlier versions open
unchanged.
After updating Marika, restart the app so existing agent connections load the new tools.

### From diagrams to implementation

The **Diagram** menu above the canvas contains four editable templates: **System context**,
**Service architecture**, **Request flow**, and **Deployment**. Insertion places the template
beside existing content and is undoable. Template descriptions identify their components as
proposed examples; adapt them to the actual project.

Use **Diagram → Tidy layout** to arrange the canvas or selected layers from left to right or
top to bottom. Connections determine the order. Frames keep their contents, locked subtrees
stay put, and Undo restores the previous arrangement. You can continue placing layers by hand.

Select a layer and use **Code and documentation → Manage links** in Properties to attach a
project file, a symbol with an optional line number, an API collection endpoint, or an HTTP(S)
documentation URL. File links open Code, endpoint links open API, and documentation opens
Browser. For a symbol link, choose its file, click **Find declarations**, and pick the exact
declaration reported by the configured language server. Its name, container, kind, and
signature identify it independently of its line number. **Open** resolves its current
location; **References** opens the code references panel. Older symbol links still load and
resolve by exact declaration name; ambiguous names require picking a declaration again.
Missing targets and unavailable servers show an error instead of guessing from a text match.
Links persist with copied elements and are included in agent context.

Open **Health** above the canvas to check missing files, unresolved or ambiguous symbols,
removed API endpoints, and disconnected engineering components. **Show element** selects the
affected element so its links can be reviewed in Properties. A server that cannot run or does
not support symbols is reported as **unverified**, separately from broken links. Checks use
open editor contents, including unsaved edits, for symbol lookup. The panel marks results
out of date when the design, open edited code, or endpoint collection changes; use **Check
again** after changes on disk. Documentation URLs are validated without visiting them. The
audit is read-only, and disconnected components may be intentional. Local file checks on SSH
projects are reported as unverified.

Select the elements to implement and choose **Diagram → Create implementation ticket**.
Review and edit the requirements and acceptance criteria before creating it. Creation saves
a linked ticket without launching an agent. The ticket's existing **Start work** and review
workflow uses the latest element descriptions, links, and connections. Changes to that context
invalidate an older launch or acceptance. Tickets display their status on linked diagram
elements, using a compact status dot when zoomed out; click a badge or dot to open the ticket. **Open linked Design** returns from the
ticket to its source elements.

**Diagram → Versions and changes** saves up to ten named snapshots with the project. Select
a version to compare it with the current canvas: green marks additions, orange marks changes,
and red marks removals, including connections. Restore replaces the current canvas and can be
undone. Locked layers must match the snapshot or be unlocked before restoring it. These are
local design snapshots, separate from Git history.

## Needs attention

Open **Needs attention** in the sidebar or press **⇧⌘I**. The inbox shows pending approvals and
input requests first, then blocked agents, failed or incomplete checks, and results awaiting review.
Use **This space / All spaces**, update-type filters and search to narrow the list. Opening an update
routes to its ticket, chat or result details, including work in another space.

Approvals disappear when resolved. Busy agents hide older failures; passing checks clear their
failure update, and accepted tickets or reviewed worktrees clear their review request. **Dismiss**
hides a handled update across restarts without deleting the agent or changing ticket status. A new
failure or run returns to the inbox. Live approval and input requests cannot be dismissed. An agent
that was working when the app closed offers a link to continue its chat after restart.

## Project tabs

Use the **+** menu in the tab row to open **Code**, **Stats**, **Browser**, **Agents**,
**Changes**, **Terminal**, **Pipelines**, or **API**. The same menu is available at every window size.
**Chat** stays pinned at the beginning. Opening a view again selects its existing tab.
Each tool tab has an **×** to close it; its context menu can
close other tabs or move it left or right. Each project remembers its open tabs, order and selected
view across restarts. Closing a tool tab keeps unsaved editor files and running tasks available
when you reopen it. **⌃Tab / ⌃⇧Tab** cycle through open tabs; **⌘1–9** open or select a view directly.

## Split workspace

Open a view from **+**, then drag its tab toward an edge of the workspace content. The outer
quarter at each edge is a drop target; the center does not change the layout. A highlighted half
shows the proposed placement. Drop at **left** or **right** for side-by-side views, or **top** or
**bottom** to stack them. A split contains two different views; moving an existing pane retains
its partner where possible. Replaced views remain available as tabs.

For the same placement without dragging, right-click a tab and choose **Split Code right**,
**Split Browser bottom**, or another directional action. Drag the divider to resize the panes.
Use the split menu in the toolbar to change orientation or **Close Split**. Files, drafts and
browser pages stay with the project. See the [split screenshots](screenshots.md#side-by-side-workspace).

## Project channels and agent conversations

Chat includes a **#project** channel and direct conversations with the project's agents, with live status, unread replies and agent search. Type **@** to choose an agent, then send a message to its conversation. Drafts and attachments stay with each chat, and switching projects or tabs restores your last conversation. The outer sidebar remains project-only.

Select text across a reply's paragraphs, lists and code blocks and press **⌘C** to copy it.
The visible Copy button below a reply copies its entire Markdown source, including all paragraphs
and code blocks. Your messages and individual code blocks also have their own Copy buttons.

## Run a proposed terminal command

Shell blocks in assistant replies have a **▶ Run** button beside Copy. Click it to run the
whole block in a new Terminal tab. The terminal displays the command, output and exit status,
and keeps that output available after the command finishes. Existing shells stay separate.
Commands run in the originating chat's project folder, or the task agent's isolated worktree.
Remote projects route the command through their configured runtime.

The button supports blocks labeled `sh`, `bash`, `zsh`, `shell` or `shellscript`. Prompt-only
examples such as `$ npm test` also work in console or unlabeled blocks; copied output mixed
with prompts is not runnable. Source-code blocks and Markdown files do not get a Run button.
Run is disabled while the agent is still responding. Reading a reply never starts a command;
execution happens when you click Run.

## Models, effort and speed

Switch an existing conversation or task agent between **Claude Agent** and **Codex** from the
composer's always-visible provider menu. During a running turn, the choice is queued until that
turn finishes; the banner offers **Cancel switch**. The current provider continues handling the
turn and any steering messages. The chat, draft, @mention and worktree stay with the same task;
the new provider uses its default model, effort and speed with the existing permission mode.
An unfinished queued choice is kept across app restarts and applied when the chat is idle.

The next message starts a fresh provider conversation with the original task and recent visible
messages and tool results as context. Older text may be omitted to fit the handoff size limit;
private thinking and old image attachments are not transferred. Switching back works the same
way. The visible conversation remains available locally, and the switch survives app restart.

The chat composer has separate **model**, **reasoning effort**, and **speed** controls for Codex.
Speed offers Standard plus the faster tiers advertised by the selected model, including Fast
or Ultrafast when available. **Default speed** follows your Codex configuration. Each chat keeps
its own choice across restarts; changes apply to the next turn. Narrow windows wrap the controls
onto additional rows so the selectors remain accessible. Light and dark chat layouts use quiet
project navigation, neutral message bubbles, and a rounded composer.

## Search past conversations

Use **Search chat history** in the chat header, or **⇧⌘H**, to search messages across all projects
in a separate window overlay. Filter by project and open a result to jump to the original message,
highlighted in its conversation. **Latest** returns to the end of the chat. Search reads saved and
live conversations locally; it sends no messages to a provider and leaves your drafts intact.

## Launch and review task agents

Choose **New Agent** (⇧⌘N) to give Claude or Codex a task in a separate chat. Choose its
model and permissions, optionally include the selected file, and monitor progress from Agents.
Set an optional agent name when launching; otherwise Marika suggests a short name from the task.
The pencil beside the agent name in Agents or its Chat header renames it without changing its
stable @mention. Completed cards preview the latest assistant result instead of repeating the task.
Open an agent's chat to answer approval requests or give further instructions. Each agent keeps
its own conversation. Git projects use isolated worktrees by default. Choose **Review Changes**
to open a before/after diff in the code editor. Accept or reject each hunk, or accept all remaining
changes. New, deleted and binary files are reviewed as whole files. Acceptance protects unsaved
editor drafts and refuses stale reviews; refresh if the project or agent's proposal changed.
**Run tests** runs the relevant Go packages or the project's Swift, Rust, JavaScript or Python
test command in the agent's worktree. Send review feedback and failed test output directly to
that agent. Agents in non-Git folders share the project files. Up to four agent tasks can run at once.

Choose **Task details** on an agent to see its current activity, approval or failure blockers,
latest reported plan, changed files, verification and published deliverables together. Plans are
kept across restarts. Successful tool edits provide an observed file list; an idle isolated task
also loads its full worktree review. **Review changes** opens the existing hunk review.

The task page's **Run tests** runs the detected project test command in that task's worktree or
shared project folder. It is disabled while the agent is working. Its dated result and output
are saved with the chat; later edits are not verified automatically. Commands observed in the
transcript appear separately and are not treated as proof that tests passed. Expand deliverables
to read published plans, walkthroughs and browser evidence, or open the full artifact review.

## Task queue and activity

Choose **Queue task** in **New Agent** to save work for the next free slot. Each project can run
four task agents at once. The queue uses the chosen provider, model, permissions and isolation
setting; work starts automatically while its queue is running. Open **Queue** in Agents, or
**Task Queue** in the workspace menu or command palette, to pause/resume, reorder waiting work,
cancel a waiting task or open a created agent.

Pausing stops future starts and leaves running agents alone. A launch failure pauses the queue
and shows the prerequisite or error. Fix it, select **Requeue**, then **Resume queue**. Queues
reopen paused after restarting Marika. A launch interrupted before its outcome was saved is
linked to an existing agent when possible; otherwise it needs explicit review and requeueing.
The queue holds up to 50 pending/failed tasks and retains 30 recent starts or cancellations.
Queued work runs while Marika is open and the Mac is awake.

**Activity** in Agents keeps approvals, finished/failed/stopped tasks and queue launch failures.
Open an entry to reach its chat, task page or queue. Mark entries read individually or together,
and use **Unread** to focus on new events. The last 100 events and their read state are saved
with the project, including events received while Marika is active.

When Marika is in the background, task completion, failure and approval banners use macOS
notification permission. Clicking a banner opens the relevant task or approval. **Settings →
General → Task notification banners** controls banners; the activity inbox remains available
when banners are disabled or macOS permission is denied.

## Task status and filters

Chat and Agents share the same task status and colors. Working and approval states take priority
while a task is active; the latest turn determines its settled outcome.

| Filter | Includes |
| --- | --- |
| **All** | Every task in the project, including unstarted tasks marked Ready. |
| **Active** | Working and Needs approval. |
| **Needs attention** | Failed and Needs approval. |
| **Finished** | Completed, Stopped and Archived. |

Failures show the error and an **Open Chat** action. Pending approvals offer **Review Approval**.
Stopped means the task was interrupted; Archived means its isolated workspace was discarded.
The [screenshot tour](screenshots.md#agent-outcomes) shows examples of the settled outcomes.

## Delegate between agents

Agents can also delegate from chat through `agent_spawn`, `agent_list`, `agent_status`, `agent_wait`,
`agent_send`, and `agent_stop`. Child agents inherit the parent's permission mode and can only be
managed by their parent or an ancestor chat. Delegation is limited to three levels. The MCP
connection is specific to each chat and is refreshed when that chat's agent process restarts.

## Scheduled jobs and project setup

**Project → Project Settings** (⇧⌘,) contains worktree setup, reusable actions, schedules,
playbooks and MCP connections. Setup runs before each isolated agent starts and a setup failure
stops that launch. **Chat → Scheduled jobs** manages recurring agent tasks, with fixed hourly
intervals or five-field cron expressions, time zones, presets and a next-run preview. For example,
`0 9 * * MON-FRI` runs at 9am on weekdays in the chosen time zone. Edit, pause, resume or run jobs
manually and open their saved run conversations to follow up. The latest 12 runs are linked from
each job; their transcripts remain saved in the project. Jobs use isolated worktrees in Git
repositories and request approval when needed. They run while Marika is open and the Mac is awake,
catch up one missed run after reopening, and don't overlap runs of the same job. Cron supports
lists, ranges, steps, month/day names and calendar aliases such as `@daily`; missing DST times
are skipped and repeated local times run once. Keep the app running for scheduled work.

## Playbooks and MCP connections

Enabled project playbooks are sent to Claude and Codex on their next process connection. Import
an existing SKILL.md or create instructions in the editor. Open **Project → Connections** to add,
edit, enable or disable connections for this project. The searchable catalog includes
[Context7](https://context7.com/docs/resources/all-clients),
[Linear](https://linear.app/docs/mcp) and
[Notion](https://developers.notion.com/guides/mcp/get-started-with-mcp), using their documented
remote endpoints. **Connect** shows the expected access and official setup guide before adding
the connection; services that require OAuth continue to browser sign-in. Save Project Settings
to keep the configuration. Use **Configured** to search existing servers, including custom ones.

Connect custom local commands or HTTP endpoints with **Add server** or **Import JSON**;
**Test connection** initializes a temporary connection and lists tools, resources and prompts
without executing tools. Status distinguishes configured, disabled, signed-in and successfully
tested connections. Expand **Permissions and tools** after a test to inspect server-reported
read-only, write or destructive access. Missing annotations are labeled unspecified; those labels
describe tools and do not impose an extra permission restriction. Use Advanced JSON for extra options.
Use `${ENVIRONMENT_VARIABLE}` references for existing credentials. Changes reconnect idle agents
and take effect after active work finishes. CLI-level skills and configured tools also remain
available through their respective agent runtimes.

HTTP servers that publish OAuth metadata offer **Sign in**. Marika opens the authorization page
in your browser, uses PKCE, and stores access and refresh tokens in macOS Keychain. Servers can
register a public client automatically or use the optional client ID in the server editor.
Tokens refresh before agent connections and connection checks; **Sign out** removes the local
credential. The project stores only an opaque credential reference. OAuth credentials are local
to this Mac and project. Existing provider consent is managed at the provider.

### Additional catalog connections

The catalog also includes GitHub, Slack, Gmail, Google Calendar, Google Drive and Google Sheets.
Each entry shows its access and setup requirements before adding configuration:

- **GitHub** uses a personal access token stored in Keychain. Project JSON contains only an opaque
  credential reference. Select minimal repository permissions, then use **Test connection**.
  **Sign out** removes the local credential; revoke the token at GitHub to invalidate it.
- **Slack** uses its vendor-hosted MCP endpoint and requires an approved, PKCE-enabled internal or
  directory app. Supply its public client ID and register the exact loopback redirect displayed
  in the Connect form (default `http://127.0.0.1:8765/oauth/slack`). The port must be available.
  Workspace administrators may need to approve access. Slack does not offer dynamic registration.
- **Google services** use separate, service-scoped recipes through `@googleworkspace/cli@0.5.0`,
  a pinned release with an MCP server. The googleworkspace project is not an officially supported
  Google product. Node.js 18+ and your own Google Cloud Desktop OAuth client are prerequisites.
  Follow the linked authentication guide and run the displayed service-specific sign-in command
  in Terminal. The first test or agent connection downloads the pinned package if necessary.
  Credentials are managed by `gws`, separately from Marika. Adding a recipe alone grants no access.

The setup cards link to [GitHub's server guide](https://github.com/github/github-mcp-server/blob/main/docs/remote-server.md),
[Slack's server guide](https://docs.slack.dev/ai/slack-mcp-server/), and the
[versioned Workspace CLI guide](https://github.com/googleworkspace/cli/tree/v0.5.0#authentication).
A catalog entry means a configuration recipe is available; **Connected** appears only after a
successful discovery check. Live access still depends on provider policy, account permissions
and the credentials you authorize. Custom MCP servers remain available through **Add server**.

## Attached repositories

Use the folder button in the workspace toolbar to attach repositories to a project and switch
their editors and Git review. Open files and unsaved drafts are saved separately per repository.
The project conversation can work across attached folders; isolated task agents stay inside their
own worktree. Scans and generated API collections continue to belong to the primary repository.

## Memory, hooks and editor suggestions

Project Settings also contains **Memory**, **Hooks**, **Remote**, and **Editor**. Memory is shared
with new Claude and Codex connections. Hooks run explicitly configured commands before or after
turns. Remote entries use your SSH configuration to open a shell or the remote machine's installed
agent CLI; they do not synchronize files or mirror the remote conversation into Marika's chat.
Use the editor's sparkles button for an AI suggestion, Tab to insert it, and Escape to dismiss it.
Automatic suggestions are opt-in and use the selected agent and model's existing CLI account.

## Remote workspaces and containers

**Remote → Open workspace** opens SSH files directly, with comparison checks before writes;
Python 3 and key-based SSH access are required on the host. Language tools, tests, and installed
agent CLIs run there. The development-container action mounts the project into a user-selected
image; the image must include the required tools. Local browser MCP tools and local checkpoints
are not bridged to remote agent sessions. Generic remote debug adapters use stdio; automatic
Delve TCP launching currently runs locally. Live SSH connectivity requires your own host and was
not exercised by the automated fixtures.

## Containers, Docker and Kubernetes

Open **Containers** below Design in the sidebar, or press **⌘E**. Each project remembers
its engine, context, namespace and Compose file. The hub uses your installed `docker`
and `kubectl` commands and their existing credentials. Start Docker Desktop (or another
Docker-compatible engine) before connecting; **Refresh** discovers new contexts.

The **Map** shows Compose stacks, containers and images for Docker, or services,
workloads and pods for Kubernetes. Colors show readiness, pending work and failures.
Kubernetes dashed lines follow service selectors to pods; solid lines show workload
ownership. Select a resource to inspect ports, images, labels, readiness and recent
Kubernetes events. **List** and the resource filter help with larger environments.
Resources refresh every ten seconds while the tab is visible. The map displays up to
90 resources; filtering narrows it. On compact windows, details open in a sheet.

- **Docker:** use **Run image** to start a named container, or **New → Pull image** to
  download an image reference. Optional published ports bind to `127.0.0.1`. Existing
  containers have start, stop, restart and recent logs controls. A Compose file at the
  project root enables **Start stack** and **Stop stack**; stopping does not remove volumes.
- **Kubernetes:** select a context and namespace (`*` shows all namespaces). Deployments
  and StatefulSets support scaling; controllers support rolling restarts. Pods expose
  recent logs, and pods/services support local port forwarding. Port forwards stop when
  their context changes or Marika closes. **Open** sends the local port to the project browser.
- **Local clusters:** install `kind`, choose a local Docker context, then choose
  **New → Create local Kubernetes cluster**. Marika keeps a separate kubeconfig for this
  cluster and leaves your global current context unchanged. Its **Delete cluster** action
  removes the cluster and its workloads after confirmation. Clusters remain running when
  Marika closes; an interrupted creation remains listed if kind began creating it.
- **Manifests:** choose **New → Apply manifest** and select a YAML/JSON file in this project.
  Review the `kubectl diff` against the displayed context and namespace, then apply those
  exact reviewed file contents. Cluster-scoped resources affect the selected cluster.

Operations display their target and run with explicit context/namespace arguments.
Changing the target invalidates a pending operation; workload actions also check that the
selected resource has not been replaced. Failed commands report their output in the hub.
The hub supports existing Kubernetes clusters; `kind` is only needed to create a local one.

### Health, jobs and recovery

Choose **Health** in the Kubernetes view to check every configured context across all
namespaces. The overview separates unhealthy workloads, failed Jobs, container restarts
and warning events. Each context shows its own timestamp and connection errors; unreachable
contexts are not counted as healthy. Health refreshes every 30 seconds while visible, or
with **Refresh health**. Select an issue to open its resource and namespace.

Jobs show active attempts, completed work, terminal failure reasons, start/finish times and
CronJob ownership. A successful Job stays completed when earlier attempts failed; running
retries and suspended Jobs have their own states. CronJobs show their schedule, time zone,
last scheduled/successful runs and retained child Jobs. Counts describe retained Kubernetes
resources, so old failed Jobs remain visible until your cluster's retention policy removes them.

**Logs and diagnostics** lets you choose a retained pod and container, including init
containers. **Previous instance** reads the prior terminated instance's logs. Exit codes,
restart counts and related events help explain failures. Logs are read-only and limited to
the latest 300 lines; cleaned-up pods cannot provide logs.

**Retry as new job** and a CronJob's **Run now** prepare an independent Job using the selected
resource's template. The review shows the exact cluster, namespace, new name, images and
configuration summary. Confirming starts the work again, so its writes or notifications can
repeat. The original Job, CronJob and schedule are kept. Custom-controller Jobs and Jobs with
manual selectors must be managed through their owning controller.

For a Deployment, **History / rollback** lists retained revisions and their images. Select a
revision, review it, then **Confirm rollback** to restore that entire pod template. Rollback
keeps the replica count; it can also restore older configuration, not just images. Environment
values are omitted from the review summary. **Rollout status** and the live resource state
show the rollout's progress. Opening or cancelling a review runs no recovery action. Before
confirmation is executed, Marika checks the source UID and configuration again and verifies
that the chosen rollback revision still exists.

### Log explorer and Grafana / Loki

Choose **Logs** in Containers for a dedicated log explorer. Select a Docker container,
Kubernetes pod or workload, choose a time range, then **Run query**. Workloads merge their
retained pods; **All current pods / containers** is available for a broader view. Up to eight
sources are read at once. **Live → Start live** tails new container output; **Stop**, leaving
Logs, switching contexts/namespaces or closing Marika stops those streams. **Follow** keeps
the newest rows in view. Runtime logs only cover what the container engine retains.

Filter returned rows by text and severity, click a row to inspect structured JSON fields,
and copy or save the visible results. The chart counts loaded, filtered lines, including error
lines; it is not a measurement of all cluster traffic. The in-memory buffer keeps 2,000 rows
and reports dropped older rows. Long lines are truncated to bound memory use.

For retained log history, open **Connections**, enter a **Loki base URL**, optional username
and tenant, and its read-only access token. Tokens stay in macOS Keychain; workspace settings
contain the endpoint and username, not the token. Use HTTPS for authenticated remote
connections. **Test Loki** checks access and lists available labels. The **Loki history**
source accepts LogQL stream queries such as `{namespace="app"} |= "error"`; it requests the
latest 1,000 entries in the chosen time range. Live history refreshes every five seconds and
deduplicates returned entries. Narrow queries when the result limit is reached.

A **Grafana URL** enables **Open Grafana** in the project browser, where you sign in normally.
**Find Grafana link in cluster** checks the selected context's `monitoring/grafana` ConfigMap
for an existing Grafana Cloud URL. This only reads configuration. It does not install Grafana
or Loki, start scaled-down deployments, read their secrets or copy browser credentials.

Runtime live sessions follow the pods selected when the query starts; rerun after a rollout
to include replacement pods. Loki queries use the configured endpoint and the labels in
LogQL, so include cluster and namespace selectors when querying a shared multi-cluster store.
