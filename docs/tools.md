# Browser, reviews, APIs and pipelines

[← Back to Marika](../README.md)

The Views row opens each tool as a tab. Tools that do not fit in a narrow window are listed under **More views** or **More**.

## Browser and local previews

Open **Browser** (⇧⌘B) to preview a running local server or a project HTML file. It has page tabs,
back/forward navigation, desktop/tablet/mobile widths, and WebKit's Inspect Element menu. Start
a detected development server with **⇧⌘R**, or enter a custom command and address in preview settings. The browser opens when the server responds. Select an element or
capture a screenshot to add feedback to the current message draft for review before sending.

Marika provides eight browser tools to newly started Claude and Codex agent processes through
the bundled `MarikaBrowserMCP` helper. Agents can inspect, screenshot, navigate, click, fill, scroll,
and switch tabs in the same browser you see. Local previews are enabled by default; other sites
need access enabled from **Agent access** in the browser toolbar. Each project has a separate,
temporary browsing profile. The preview uses native WebKit.

## Research

Open **Research** (⌘0) to investigate **Documentation**, **Libraries**, or **Competitors** for the
current project. Write a question, choose Claude or Codex, and select **Start research**. Research
uses the selected CLI agent's available web search and connected documentation tools. Connect
additional sources with **Connections**. Retrieval and account access depend on those tools;
if sources cannot be retrieved, the agent should report the blocker in chat.

The agent works in a separate chat in plan mode and is instructed to leave project files unchanged.
Progress, stop and approval actions remain available while it works. A run without a published
report is labeled explicitly; a completed agent turn alone does not mean a report exists.

Published reports show an answer and supporting sources side by side, with source excerpts and
links to the originals. Compact splits place sources below the answer. Select a finding's source
reference to highlight its evidence. Reports are supplied by the agent; open sources to check
the claims. **Research history** keeps recent runs with the project across restarts.

Select **Create task** on a finding to review its proposed instructions, evidence, provider and
permissions in the agent launch form. Launching creates a separate implementation task; Git
projects default to an isolated worktree. The finding then offers **Open task**, which opens the
task detail page. Research never starts implementation automatically.

## Code-health reviews

Open **Stats** (⌘5) for code-health reviews. **Run review** starts the selected agent to inspect
source and tests, then publish prioritized findings with exact code excerpts, impact and next steps.
Click a source location to open the editor or ask an agent to work on a finding. The inventory
separates maintained source, tests, generated files and dependencies. Compact language and file-size
summaries support the review. Earlier scans remain available from the date menu, and the model can
be changed from the review settings button.

**Review published** means the report is available even if its conversation continues with a
follow-up. A new review or failed rerun is reported separately, while the earlier report stays
readable. A worker that stops after saving inventory without publishing a review is shown as
incomplete. Inventory line counts do not measure test coverage or code quality. See the
[sample report screenshot](screenshots.md#code-health-reviews).

## API collections and project environments

Open **API** (⌘7) and choose **Generate collection** to have the current project agent read the
routes, handlers, tests and startup files. Open **Source** on a request to inspect its implementation.
The agent can publish HTTP requests, GraphQL queries and mutations, and gRPC methods in the same collection.
Find requests by method, name or path in the sidebar; compact panes use a request picker.
For HTTP, edit the base URL, method, path and query, headers or body, then **Send** (**⌘Return**).
**Parameters** provides named inputs for path placeholders and editable query rows. Values are
URL-encoded, and unresolved fields or an invalid destination are identified before Send becomes
available. Saving keeps the path template and its entered values; navigation and search show
the edited route, including saved changes after reopening.
For GraphQL, edit the operation and its JSON variables. For gRPC, edit the protobuf JSON message and
metadata. The client uses `grpcurl` with project proto files or server reflection. Use `grpc://`
for plaintext and `grpcs://` for TLS.
Request code editors preserve literal quotes and dashes, with automatic text substitutions
disabled. JSON bodies are checked before sending when the HTTP Content-Type is `application/json`
or ends in `+json`, and for gRPC messages. Other HTTP payload formats remain available.

The resizable response pane separates **Body**, **Headers** and **Raw** output, with status,
timing and a Copy button for the selected section. Text can also be selected and copied with **⌘C**.
Tall windows keep the request form compact and give the extra height to the response. Drag the
grip between them to resize, or use its accessibility increment/decrement actions.
**History** lets you reopen recent responses with their timestamp, status and request URL.
**View request** shows the exact saved destination, headers, body and GraphQL variables used
for that run. **Restore to editor** replaces the draft with that snapshot; **Undo restore** brings
back the previous draft until you edit it again. Restoring does not save the request automatically.
**Rerun** sends the selected run's request snapshot without replacing your current draft.
History keeps up to 20 runs across the project, with an 8 MB response-preview budget, during the
app session. Older entries are removed as the limits are reached. **Cancel** stops an in-flight request.
Each request retains its unsaved draft and recent responses
while switching requests or views during the app session. **Save changes** stores the request,
including entered headers, in the project's local workspace for the next launch; responses are
not saved across restarts. Use **Compare** to send the request to two base URLs and see which
JSON fields differ. See the [API screenshot](screenshots.md#api-playground).

**Project environment** shows the agent's Compose
files, profiles, command and prerequisites. **Start project** builds and starts the stack;
**Status**, **Logs**, and **Stop** operate on the same project-specific Compose stack.
Connection failures offer **View logs** and **Project setup** when a Compose environment is
available, plus **Start project** for local destinations. These actions open the environment
panel so their output is visible. Projects with startup instructions can open setup from the
failure panel. Sending a request never starts a service automatically.

## Pipelines

Open **Pipelines** (⌘6) to select a job and event from the project’s GitHub Actions YAML.
Linux jobs run through `act` and the active Docker engine. Choose an image with the tools the job
needs. Jobs with recognized GitHub-only requirements are labeled in the picker’s detail area.
Swift packages also offer a native Mac test and release build. Marika’s own pipeline finishes by
verifying the app signature. Each project keeps its latest 12 finished runs and the last 64 KB of
output per run. Use **Run again** to repeat a job or **Ask agent about failure** to analyze its log.
