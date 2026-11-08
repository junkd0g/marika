# Spaces, conversations and agents

[← Back to Marika](../README.md)

Use spaces to group projects, keep conversations with their work, and launch Claude or Codex tasks from the same workspace.

## Spaces and project navigation

Organize projects into **spaces** in the left sidebar. The colored icons at the bottom switch
spaces; **+** creates one. Each space remembers its last project, chat, and editor state. New
projects belong to the current space. Right-click a project and choose **Move to Space**.
Use a space's menu to edit its name, icon and color, change its position,
or delete it. Deleting a space moves its projects to the space named in the confirmation;
files and conversations are kept. Existing projects start in **Personal**. **⌃⌥← / ⌃⌥→** switch
spaces, and **Navigate → Switch Space** and the command palette list them by name. Running
agents keep working when you switch, with activity dots on their space icons.

## Project tabs

Use the named buttons in the **Views** row to open **Code**, **Stats**, **Browser**, **Agents**,
**Changes**, **Terminal**, **Pipelines**, or **API** as a tab. Narrow windows keep **Code** and
**Stats** visible and put additional tools in **More views** (**More** in compact layouts).
**Chat** stays pinned at the beginning. Opening a view again selects its existing tab.
Middle-click a named view shortcut or tab to open that view directly, without a chooser.
Each tool tab has an **×** to close it; its context menu can
close other tabs or move it left or right. Each project remembers its open tabs, order and selected
view across restarts. Closing a tool tab keeps unsaved editor files and running tasks available
when you reopen it. **⌃Tab / ⌃⇧Tab** cycle through open tabs; **⌘1–9** open or select a view directly.

## Split workspace

Drag a view tab, or a button from **Views**, toward an edge of the workspace content. The outer
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
