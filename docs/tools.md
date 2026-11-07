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

## Code-health reviews

Open **Stats** (⌘5) for code-health reviews. **Run review** starts the selected agent to inspect
source and tests, then publish prioritized findings with exact code excerpts, impact and next steps.
Click a source location to open the editor or ask an agent to work on a finding. The inventory
separates maintained source, tests, generated files and dependencies. Compact language and file-size
summaries support the review. Earlier scans remain available from the date menu, and the model can
be changed from the review settings button.

## API collections and project environments

Open **API** (⌘7) and choose **Generate collection** to have the current project agent read the
routes, handlers, tests and startup files. Open **Source** on a request to inspect its implementation.
The agent can publish HTTP requests, GraphQL queries and mutations, and gRPC methods in the same collection.
For GraphQL, edit the operation and its JSON variables. For gRPC, edit the protobuf JSON message and
metadata. The client uses `grpcurl` with project proto files or server reflection. Use `grpc://`
for plaintext and `grpcs://` for TLS. For HTTP, edit the path, query, headers or body, then **Send**. Use **Compare** to send the request to two
base URLs and see which JSON fields differ. **Save request** stores edits, including entered
headers, in the project's local workspace. **Project environment** shows the agent's Compose
files, profiles, command and prerequisites. **Start project** builds and starts the stack;
**Status**, **Logs**, and **Stop** operate on the same project-specific Compose stack.

## Pipelines

Open **Pipelines** (⌘6) to select a job and event from the project’s GitHub Actions YAML.
Linux jobs run through `act` and the active Docker engine. Choose an image with the tools the job
needs. Jobs with recognized GitHub-only requirements are labeled in the picker’s detail area.
Swift packages also offer a native Mac test and release build. Marika’s own pipeline finishes by
verifying the app signature. Each project keeps its latest 12 finished runs and the last 64 KB of
output per run. Use **Run again** to repeat a job or **Ask agent about failure** to analyze its log.
