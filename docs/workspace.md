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
Each tool tab has an **×** to close it; its context menu can
close other tabs or move it left or right. Each project remembers its open tabs, order and selected
view across restarts. Closing a tool tab keeps unsaved editor files and running tasks available
when you reopen it. **⌃Tab / ⌃⇧Tab** cycle through open tabs; **⌘1–9** open or select a view directly.

## Project channels and agent conversations

Chat includes a **#project** channel and direct conversations with the project's agents, with live status, unread replies and agent search. Type **@** to choose an agent, then send a message to its conversation. Drafts and attachments stay with each chat, and switching projects or tabs restores your last conversation. The outer sidebar remains project-only.

## Models, effort and speed

The chat composer has separate **model**, **reasoning effort**, and **speed** controls for Codex.
Speed offers Standard plus the faster tiers advertised by the selected model, including Fast
or Ultrafast when available. **Default speed** follows your Codex configuration. Each chat keeps
its own choice across restarts; changes apply to the next turn. Narrow windows wrap the controls
onto two rows so the speed selector remains accessible. Light and dark chat layouts use quiet
project navigation, neutral message bubbles, and a rounded composer.

## Search past conversations

Use **Search chat history** in the chat header, or **⇧⌘H**, to search messages across all projects
in a separate window overlay. Filter by project and open a result to jump to the original message,
highlighted in its conversation. **Latest** returns to the end of the chat. Search reads saved and
live conversations locally; it sends no messages to a provider and leaves your drafts intact.

## Launch and review task agents

Use **Agents → Launch Agent** (⇧⌘N) to give Claude or Codex a task in a separate chat. Choose its
model and permissions, optionally include the selected file, and monitor progress from Agents.
Open an agent's chat to answer approval requests or give further instructions. Each agent keeps
its own conversation. Git projects use isolated worktrees by default. Choose **Review Changes**
to open a before/after diff in the code editor. Accept or reject each hunk, or accept all remaining
changes. New, deleted and binary files are reviewed as whole files. Acceptance protects unsaved
editor drafts and refuses stale reviews; refresh if the project or agent's proposal changed.
**Run tests** runs the relevant Go packages or the project's Swift, Rust, JavaScript or Python
test command in the agent's worktree. Send review feedback and failed test output directly to
that agent. Agents in non-Git folders share the project files. Up to four agent tasks can run at once.

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
an existing SKILL.md or create instructions in the editor. Open **Project → MCP Servers** to add,
edit, enable or disable servers for this project. Connect local commands or HTTP endpoints;
**Test connection** initializes a temporary connection and lists tools, resources and prompts
without executing tools. Import existing `mcpServers` JSON or use Advanced JSON for extra options.
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
