# Development, testing and releases

[← Back to Marika](../README.md)

Start with [CONTRIBUTING.md](../CONTRIBUTING.md) for the development workflow and [SECURITY.md](../SECURITY.md) for vulnerability reports.

## Build and check

Use macOS 15 or later and full Xcode 26.3 or newer. Go 1.24 or newer is needed for Go test-runner fixtures.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --no-parallel
scripts/build-app.sh release
codesign --verify --deep --strict build/Marika.app
```

`swift run Marika` runs the app directly; a bundled build is preferable when checking signing,
Keychain access, icons and the browser helper.

## Architecture

```
Sources/
  MarikaCore/              Runtime protocols, storage and project services.
    Agents/
      AgentSession.swift   The protocol every agent implements
      Claude/              Claude Code CLI over stream-json
      Codex/               codex app-server over JSON-RPC
    Model/                 Transcript, diffs, approvals, events shared by all agents
    Services/              SessionController (events to transcript), git, Keychain, storage
    Support/               Subprocess handling, login-shell environment, JSON
  Marika/                  The SwiftUI app
  MarikaBrowserMCP/        Local MCP bridge to the browser and agent tasks
Tests/MarikaCoreTests/     Replays recordings of the real tools, plus stand-in Codex servers
```

To add an agent, implement `AgentSession` and translate its protocol into `AgentEvent`s. The UI
only ever sees those events.

## Test suites and native UI checks

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel
```

The live suites drive your real, signed-in tools, using small models at low effort. The Codex suite
archives the threads it creates:

```bash
MARIKA_LIVE=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LiveClaudeTests
```

```bash
MARIKA_LIVE=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LiveCodexTests
```

`scripts/smoke.sh` runs the real app through one approved edit. Debug builds can follow a script of
UI steps, which is how the app was checked end to end. See `DebugDriver.swift`.

After a debug build, `python3 scripts/ui-smoke.py` checks the native tab controls, narrow-window
layout, multiline drafts, and hidden-composer safety without sending model requests. It saves
screenshots and a driver log in the temporary directory printed at the end.

`python3 scripts/ui-codex-style.py` checks the light and dark chat layouts, speed-control
visibility in narrow windows, and speed/effort persistence across restarts using mock agents.

`python3 scripts/ui-spaces.py` checks space creation, appearance editing, scoped project lists,
switching with active agents and unsaved drafts, space removal, and restoration after a restart.
It uses temporary data and mock agents, and captures light and dark layouts.

`python3 scripts/ui-project-tabs.py` checks the single-row header with a narrow inspector,
opening, reusing and closing project tool tabs, split cleanup, per-project tab restoration,
and preservation of active agents and unsaved files.

`python3 scripts/ui-browser.py` uses a local HTTP fixture and isolated project data to check browser
menu actions and shortcut bindings, navigation, popups, tab closing/reopening, reordering, find,
zoom, bookmarks, history, downloaded file contents, failed and cancelled download retries, favicons,
and project website-data isolation/removal. Download destinations are injected through a debug-only
hook. `python3 scripts/ui-browser.py --interactive` leaves an isolated test app and local server open
for native input checks. Pointer-based tab dragging and middle-click closing, split-pane Find shortcuts,
bookmark editing, native upload selection, JavaScript dialogs, and a real Save dialog were checked
through the running app. Trackpad back/forward gestures still require a physical hardware check.
It restarts the app to verify that cookies, local storage, tabs and bookmarks persist, and captures
the browser in dark and light appearances. It makes no AI requests.

`python3 scripts/ui-history-updates.py` checks cross-project message search, older-message jumps,
draft preservation, release notes and update states. It also makes one read-only request to the
public GitHub releases endpoint; it sends no AI prompts or conversation data.

`python3 scripts/ui-recovery.py` checks deleted-file drafts, backup recovery, corrupt-data
protection, retrying failed transcript saves, and restoration of partial streaming output
after an exit without a shutdown save. It uses synthetic events and a mock agent.

`python3 scripts/ui-welcome.py` checks first-run state, switching the selected provider,
resuming incomplete setup after restart, retaining drafts, and exploring a project before
an agent is connected. Statuses and agent responses are synthetic; the test doesn't install
software or sign in to a real account.

`python3 scripts/ui-followups.py` checks the ready-agent suggestion, recovery of a saved browser
route by starting its configured preview, failed/retried/confirmed sign-in, and removal of the
empty native toolbar in windowed and full-screen layouts. Sign-in uses a synthetic Terminal
handoff and account status; no real account or credential is accessed.

`python3 scripts/ui-workflow.py` exercises the completion card and review sheet, runs a real
Swift fixture test suite, verifies outdated results after external and unsaved edits, reruns failed
and repaired code, checks freshness after restart, and rejects results changed during a run. It also
checks an occupied preview port and opens the preview with adjacent logs.
It uses isolated data and synthetic agent output; no provider request is sent.

`python3 scripts/ui-space-content.py` exercises note blocks and ticket editing through native
controls, checks space isolation and archive/restore, and verifies autosave and section restoration
after restart. It uses local fixtures without a provider account.

`python3 scripts/ui-checks.py` runs the welcome, followups, workflow, Codex-style, smoke, recovery, project-tab, space, space-content and browser suites
serially. It isolates editor preferences and saved data, disables CLI account probing, and
keeps fixture files, screenshots and logs in `build/ui-checks` (or `--artifacts PATH`).
The macOS GitHub Actions workflow runs these native UI checks after core tests and app-bundle
verification, and retains their diagnostics for seven days on failure. Live provider tests remain opt-in.

## Refresh the screenshots

Build the debug executable and capture a fresh demo workspace:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
python3 scripts/capture-readme.py
```

The script writes the three images used by the README into `docs/images/`. It launches the
real app with temporary projects, sample conversations, and a local browser preview. The
`MARIKA_DEMO=1` flag suppresses CLI account probing in debug builds. Demo data and editor
preferences are isolated, and no AI prompts are sent. Capture diagnostics stay in
`build/readme-capture.log`. Inspect all images before committing them.

### Feature-tour screenshots

The [screenshot tour](screenshots.md) also covers Chat/Agents status, the attention filter,
published reviews, and side-by-side and stacked workspaces. Prepare its sample data with:

```bash
python3 scripts/prepare-feature-tour.py
```

The command prints a launch command for the debug app with an isolated data directory, isolated
editor preferences, disabled CLI account probing and a local mock agent. It does not launch the
app or send prompts. An optional argument selects a new or empty destination directory; existing
files are never overwritten. Build the debug executable first, then run the printed command.

Navigate using the real app and capture its window with native screenshot controls. The
[image inventory](images/README.md) lists each view and destination filename. The review and task
results are preloaded examples, not model-generated evidence. Keep that distinction in captions.
Check each capture for readability and personal information before committing it.

For the split images, use the Code tab's directional context-menu actions with Chat selected.
These exercise the same layout action used by a drop, but a screenshot of the result does not
verify the mouse gesture. The current tab/split change passed 341 core tests and a release build;
physical drag-and-drop and the wheel-button event still require manual verification. Keep that
limitation in the change description until those checks have been completed.

## Signed app updates

Sparkle is pinned through SwiftPM and embedded, with its helper services, in the app bundle.
Normal development builds provide version information, release notes, and GitHub release checks.
To enable in-app installation, configure a real HTTPS appcast URL and Ed25519 public key when
building. Archives and the appcast must be signed with the matching private key.

After resolving the package, generate a release-signing key in your Keychain:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account marika-updates
```

Use the public key printed by that tool. Use a higher version and build number for each release:

```bash
MARIKA_VERSION=0.2.0 MARIKA_BUILD_NUMBER=2 \
MARIKA_UPDATE_FEED_URL=https://github.com/junkd0g/marika/releases/latest/download/appcast.xml \
MARIKA_UPDATE_PUBLIC_KEY='<your public key>' \
scripts/build-app.sh release
```

For distribution to other Macs, set `MARIKA_SIGNING_IDENTITY` to a Developer ID Application
identity and notarize the app before packaging it. The build script embeds and signs Sparkle's
framework and helper services, preserves their entitlements, and removes local SwiftPM search
paths from the packaged executable. Developer ID builds use hardened runtime and timestamping.

Prepare a signed archive and feed locally, supplying your Markdown release notes:

```bash
python3 scripts/package-update.py \
  --download-prefix https://github.com/junkd0g/marika/releases/download/v0.2.0/ \
  --notes /path/to/release-notes.md
```

The command verifies the archive against the public key embedded in the app and verifies the
signed appcast. It writes `build/update-release/Marika-0.2.0.zip` and `appcast.xml`; it does not
publish them. Attach those files to the corresponding GitHub release and use the same notes
as the release description. Keep the private key in Keychain; CI can instead provide its path
with `--private-key-file`. No private signing key is embedded in the app or committed to Git.

`python3 scripts/test-update-package.py` verifies the packaging flow with an inert fixture app
and temporary keys, including mismatched-key and tampered-file rejection. CI runs this check
after building the app.

## Distribution

The current app launches local CLI processes and is built for direct macOS distribution.
For distribution to other Macs, sign with a Developer ID Application identity and notarize
the bundle. Choose your bundle identifier in `Resources/Info.plist`.

Build optional bundled Go tools with `scripts/install-editor-tools.sh` before packaging.
The script pins the tested gopls and Delve versions and installs them in `.tools/bin`.
See [provider runtime notes](subscriptions.md) when planning distribution.

## Recorded validation status

Historical live checks recorded during early development. These CLI versions are not installation requirements.

| Area | State |
| --- | --- |
| Claude Agent on a Claude plan | Tested end to end against the real CLI (v2.1.308) |
| Codex CLI sign-in | Tested end to end against real Codex (0.166.0-alpha.6) |
| Claude with an API key | Environment handling is unit tested. **Not yet run with a real key** |
| Sign-in through Terminal | **Not yet exercised**, because the test Mac was already signed in |

The agents have different safety controls, so read [approval modes](approval-modes.md) for
what each mode really does.
