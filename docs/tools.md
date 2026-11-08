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

## Compare models

In **Research → Compare models**, ask one question and choose the provider that will combine
the results. **Compare Claude + Codex** starts separate plan-mode chats using your installed
accounts. Each analysis gets the same question and is instructed to inspect evidence without
reading the other response or changing project files. Two free agent slots are required.

After both agents publish their structured answers, a third run automatically synthesizes
agreements, disagreements, a recommendation and checks still needed. Synthesis uses bounded
snapshots of the independent answers; it does not establish that either answer is correct.
Open each chat for approvals, full reasoning, failures or follow-up. Stop either active analysis
from its card. A completed turn without a published answer remains explicitly incomplete.
Retry an incomplete analysis or choose **Combine conclusions** if synthesis stopped.

Questions, assigned chats, answers and synthesis are saved with the project. A restart does
not silently repeat interrupted work; use the visible retry controls. Keep up to 40 comparisons
and remove finished ones when no longer needed. Switching the provider of an assigned analysis
chat prevents it from publishing under the original provider's label until you switch back.
All three runs use the accounts' normal approvals and usage limits.

## Project knowledge and reviewed memory

Open **Research → Knowledge**, or **Project Knowledge** in the command palette. Import UTF-8
text, Markdown, CSV, PDF, DOCX or RTF, or add a document, link or decision manually. Imports store
extracted text, with a 10 MB input limit and a 100 KB text limit per item. PDFs must be unlocked
and have at most 200 pages; text extraction does not include OCR. No original file is modified.

Search approved snapshots locally, inspect matching passages and copy their stable citations:
`[K:entryID:revision:passage]`. Link entries store your supplied text and source URL; adding a
link does not fetch it. To capture a URL, ask a research agent to retrieve it and propose a
knowledge item with its evidence. Stored content is a dated snapshot, so verify facts that may
have changed. The library supports up to 200 approved items.

Agents can search and read the project's approved library through `project_search_knowledge`
and `project_read_knowledge`. Relevant context carries into new tasks through those tools and
project instructions. Agents are instructed to treat stored documents as reference data and
can propose durable additions or corrections with `project_propose_knowledge`.

Expand **Review memory updates** to compare current and proposed content, inspect its source
chat, and approve or reject it. Pending proposals never enter approved search results. Updates
must match the revision reviewed; a newer edit blocks a stale replacement. The library keeps
up to 200 prior snapshots and 40 pending proposals. Removing an item excludes it from current
search, while retained revisions remain readable by citation. Existing manually maintained
Project Settings memory remains available alongside the library.

## Rich deliverables and exports

Choose **Deliverables** in Research, **Deliverables and Exports** in the command palette, or
**Deliverables, Plans and Artifacts** in the workspace menu. Select Report, Spreadsheet or
Presentation, describe the result, and choose **Create deliverable**. The selected project
provider gathers context and publishes a structured deliverable in a separate plan-mode chat.
Open that chat for approvals or revisions. Plans, walkthroughs and browser evidence remain in
the same artifact library.

| Deliverable | Preview | Export formats |
| --- | --- | --- |
| Report | Formatted Markdown with sources | PDF, Markdown, self-contained HTML, JSON |
| Spreadsheet | Selectable sheets and a scrollable text grid | XLSX, selected-sheet CSV, HTML, JSON |
| Presentation | Navigable slides and expandable speaker notes | PPTX, PDF, HTML, Markdown, JSON |

**Export** opens a save dialog and preserves the published snapshot. Existing Markdown plans
and walkthroughs can also be exported. XLSX includes every sheet and a source sheet when
sources are supplied; PPTX preserves speaker notes and adds source slides. PDF output paginates
long content. Exported HTML is self-contained and blocks scripts and external resources.

Spreadsheet cells are literal text, including formula-like values. Marika does not calculate
formulas or infer numeric cell types. CSV protects formula-like text when opened in a spreadsheet
application. Presentations support up to 60 authored slides; spreadsheets support up to 12 sheets
with 1,000 rows and 50 columns each. Published payloads are limited to 1 MB. Agents must supply
their sources; a preview or export does not verify the content's accuracy.

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
