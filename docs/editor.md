# Editing, reviewing and debugging

[← Back to Marika](../README.md)

Open **Code** from the **+** menu in the tab row or press **⌘2**. Editor state and unsaved drafts stay with each project and attached repository.

## Files, drafts and editor preferences

In Code, browse folders and edit multiple
files with line numbers, language-aware syntax colours, undo, and Find (⌘F). Save with ⌘S. Unsaved
buffers stay open when switching conversations, and Marika asks before discarding edits. Files
changed on disk reload automatically when clean; conflicting edits are preserved for review.
Right-click a local file, folder, or open file tab and choose **Move to Trash…** to delete it.
With the Files list focused (⇧⌘E), Delete or ⌘Delete opens the same confirmation. Unsaved edits
stay open as recovered drafts, and saved files can be restored from the Mac's Trash.
The editor supports UTF-8 and UTF-16 text files up to 2 MB. Single-click a file to open it.
Light and dark palettes distinguish keywords, types, functions, strings, and comments, including
Go, Swift, TypeScript, Python, GraphQL, and Protocol Buffers. The editor uses a monospaced font,
configurable tab stops, indentation guides, and matching-bracket highlights. Use the sliders button
in the editor toolbar (or **Settings → Editor**) to set the font size, light/dark theme, tabs or
spaces, tab width, guides, and line wrapping. These preferences update open editors immediately.
The slim file tabs sit above one toolbar; click a breadcrumb to browse and filter that folder.
Rename, refactoring, formatting, and snippets are in the **…** menu and the code context menu.

## Markdown and file previews

Markdown files open in **Preview**. Use **Edit** for the highlighted Markdown source or **Split**
to edit beside a live preview of your unsaved changes. The preview renders headings, tables,
checklists, code blocks and images. Relative images and document links resolve from the Markdown
file's folder within the project; heading links jump within the preview. Your chosen view and
unsaved source are restored with the file. Switching views preserves the editor's undo history.
Narrow split panes stack vertically, and ⌘F opens the source editor's search bar.
Images, PDFs, audio, video, and other files open in an embedded Quick Look preview, using the
preview formats installed on your Mac. Large text files use a preview instead of the editor.

## Search and navigation

Press **⌘P** from any project tab to search files by name, path, or abbreviation. Results
prefer exact filenames and names without extensions, with equally relevant source files above build output.
Recent files lead an empty Quick Open search. Generated and build files remain searchable;
type an explicit path when you want one of them. The file list also has a project-wide filter.
Use **⇧⌘E** to focus it, arrow keys to browse and expand folders,
and Return to start editing. **⇧⌘[ / ⇧⌘]** switch open files. Tabs scroll to the selected file,
the open-files menu shows full paths, and breadcrumb menus let you jump to nearby files.

Use **⌘K** to find workspace commands and **⇧⌘F** to search file contents across the project.
Select a match to jump to its line in Code. Use the split menu to pair two project panels side by
side or stack them vertically, or [drag a view tab to a workspace edge](workspace.md#split-workspace).
Drag the divider to resize them, or press `⌥⌘\` to toggle the
split. Marika restores the layout, browser addresses, open files, and unsaved edits on restart.

## Language servers and code assistance

The Code toolbar now connects to language servers for diagnostics, completions, definitions,
references, hover help, signatures, symbols, formatting, and refactoring previews. Go support
uses bundled `gopls`; Swift and C/C++ use installed Apple tools. GraphQL and Protobuf
presets connect to installed `graphql-lsp` and `buf lsp serve` tools. Configure other servers or import
Marika language-extension JSON in **Project Settings → Editor**. These are declarative Marika
integrations, not VS Code VSIX extensions. Format-on-save is opt-in.

With a language server configured, completion suggestions appear beside the cursor as you type.
Control-Space opens them manually; use the arrow keys to choose, Tab or Return to insert, and
Escape to dismiss. Hover a symbol for documentation, or use Control-Shift-Space for the current
function signature. Diagnostics show a lightbulb in the gutter: click it, hover the underlined
code, or press Option-Return to see quick fixes. Single-file fixes and completion edits (including
imports) are undoable; fixes spanning multiple files open a review before applying.

⌘-click a symbol or press F12 to go to its definition. ⌥⌘-click, Option-F12, or **Peek Definition**
opens a source preview without switching files. Shift-F12 shows references. Use the arrow keys
and Return in the preview, or choose **Open file**. Back and Forward retain cursor locations,
including jumps within one file. Only files inside the current project are opened by language
navigation. Unsaved content is used in previews.

## Tests and debugging

The editor drawer contains **Problems**, **Code**, **Tests**, and **Debug**. Test discovery supports
Go, Swift, and pytest; Go results include per-test status and line coverage. Go debugging uses
bundled Delve: click the line-number gutter to add breakpoints, start Debug, and inspect stack
frames, variables, and watches. Other runtimes use the configured DAP adapter and launch JSON.
Go starts at a breakpoint rather than at runtime initialization. macOS may request debugger access.

## Multiple cursors, refactoring and Git history

Option-click adds a cursor, ⌘D selects the next matching occurrence, and the editor's Fold/Unfold actions
collapse a language-server block without changing saved text. The Snippets menu inserts common
language templates. Search supports regex and replacement previews; replacements become unsaved
drafts, so normal save conflict checks still apply. Changes → History & branches provides commit
history, graphs, blame, branch switching, stash operations, and three-way merge resolution.

## Review, stage, commit and push

Open **Changes** from the **+** menu in the tab row or press **⌘8** to review staged and working-tree changes. Stage or
unstage a file or individual hunk, revert working changes after confirmation, and click a line
number to add feedback to the current chat draft. Commit the staged changes, push the branch,
and create a pull request with GitHub CLI. Push and PR creation run only when you choose them.

## Terminal

Open **Terminal** (⌘9, or Control + backtick) for interactive shells in the project and its agent worktrees. The + menu
opens another shell; closing a shell stops its processes. **Send output to chat** adds the current
terminal output to your draft. Project actions run in the selected shell.

The **▶ Run** button on a shell block in Chat opens a separate command tab, preserving the
selected shell. It uses that chat's project or agent-worktree folder and retains the output and
exit status when the command finishes. See [running a proposed command](workspace.md#run-a-proposed-terminal-command).

Compiler locations and stack frames in Terminal are clickable. Go, Swift, TypeScript and Python
locations open the matching project file and line. Dragging still selects terminal text. Relative
paths use the shell's initial folder or its reported current folder through OSC 7.
