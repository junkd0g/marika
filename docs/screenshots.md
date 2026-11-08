# Feature tour in screenshots

[Documentation](README.md) · [Install Marika](../README.md#get-started)

These are screenshots of the real macOS app. Projects, conversations, task outcomes and the
code-health report are sample data. They illustrate the interface; they are not live model
results or verification of the sample project's code.

| Explore | What is shown |
| --- | --- |
| [Spaces and view tabs](#spaces-and-view-tabs) | Project navigation, spaces and the labeled Views row. |
| [Project Chat](#project-chat) | A project channel alongside agent conversations and their latest results. |
| [Agent outcomes](#agent-outcomes) | Task names, completed results, failures and stopped work. |
| [Needs attention](#needs-attention) | A focused list of tasks that need intervention. |
| [Code editor](#code-editor) | File navigation, editor tabs and syntax highlighting in light appearance. |
| [Browser preview](#browser-preview) | A local project preview inside the workspace. |
| [Code-health reviews](#code-health-reviews) | A published sample review with source links and next steps. |
| [Side-by-side workspace](#side-by-side-workspace) | Chat and Code visible together. |
| [Stacked workspace](#stacked-workspace) | Chat above Code, with a horizontal divider. |

## Spaces and view tabs

Group projects into spaces in the sidebar. Open tools from **Views**, keep Chat pinned, and
close or reorder tool tabs without discarding saved drafts. Middle-click a named view to open
it directly; an existing tab is reused.

![Dark workspace with Work and Personal spaces, a Copper conversation, and labeled view shortcuts](images/workspace.png)

[Guide: spaces and project tabs](workspace.md#project-tabs)

## Project Chat

The **#project** channel sits beside the project's agent conversations. Agent rows show the
latest result and use the same status labels as Agents. Search for an agent or type **@** in
the composer to address one; each conversation retains its own draft.

![Project Chat with a sample conversation and Completed, Failed and Stopped agent rows](images/chat-agents.jpg)

[Guide: project channels and agent conversations](workspace.md#project-channels-and-agent-conversations)

## Agent outcomes

Agents shows the latest task result, a visible rename control and an **Open Chat** action.
Completed tasks show what the agent produced. Failed tasks show their error, and stopped tasks
remain distinct from completed work. Set an optional name when launching a task, or use the pencil
to rename it later; its @mention remains stable.

![Agents with three named sample tasks, their result previews, rename buttons and outcome labels](images/agents.jpg)

[Guide: launch and review task agents](workspace.md#launch-and-review-task-agents)

## Needs attention

Choose **Needs attention** to see failures and pending approvals. **Active** includes working
agents and agents waiting for approval. **Finished** includes completed, stopped and archived
tasks. In this example, the unavailable demo runner leaves one failed task needing attention.

![Needs attention filter showing only the failed sample verification task](images/agents-attention.jpg)

[Guide: task status and filters](workspace.md#task-status-and-filters)

## Code editor

Browse project files, keep multiple documents open, and use language-aware syntax highlighting.
The editor also supports Markdown Preview, Edit and Split modes, language tools, Git review,
tests and debugging. Unsaved drafts survive switching project views.

![Light Code view with the Copper file navigator and a Swift file open in the editor](images/code-editor.png)

[Guide: editing, reviewing and debugging](editor.md)

## Browser preview

Open a local server or a project HTML file without leaving Marika. Switch between desktop,
tablet and mobile widths, inspect the page, and attach visual feedback to a chat draft.
The example below previews the local Copper task board.

![Built-in Browser displaying the Copper sample task board](images/browser-preview.png)

[Guide: browser and local previews](tools.md#browser-and-local-previews)

## Code-health reviews

Stats presents published findings with priorities, source locations, impact and a next action.
Open **Evidence and next step** to inspect the exact excerpt. Source, tests and generated code
are counted separately; those counts are inventory, not a coverage or quality score.
The report below is a preloaded sample about the demo view's missing error state.

![Published sample code-health review with one finding, a source link and separate inventory counts](images/code-health.jpg)

[Guide: code-health reviews](tools.md#code-health-reviews)

## Side-by-side workspace

Drag a tab or a button from **Views** toward the left or right workspace edge to arrange a split.
A placement preview indicates the destination. The tab's context menu provides equivalent
directional actions. Resize the result by dragging the divider.

![Chat and a Swift file displayed side by side in the Copper demo workspace](images/split-workspace.jpg)

## Stacked workspace

Use the top or bottom edge to stack the views vertically. This example keeps the conversation
above the editor. Layout and open files are retained for the project when you reopen the app.

![Chat stacked above the Code editor, with project files and the horizontal split divider visible](images/stacked-workspace.jpg)

The split screenshots were arranged with the directional context-menu actions. They show the
resulting layouts; they do not verify physical mouse drag-and-drop or the wheel-button event.

[Guide: split workspace](workspace.md#split-workspace)

## More tools

| Feature | Documentation |
| --- | --- |
| Git diffs, staging, commits and pushes | [Changes](editor.md#review-stage-commit-and-push) |
| Project and agent-worktree shells | [Terminal](editor.md#terminal) |
| HTTP, GraphQL, gRPC and Compose environments | [API](tools.md#api-collections-and-project-environments) |
| Local GitHub Actions and native Swift checks | [Pipelines](tools.md#pipelines) |
| Recurring tasks and project setup | [Scheduled jobs](workspace.md#scheduled-jobs-and-project-setup) |
| Plans, reports and saved browser evidence | [Artifacts](recovery-and-updates.md#checkpoints-runtime-debugging-and-artifacts) |

For screenshot sources and refresh instructions, see [the image inventory](images/README.md).
