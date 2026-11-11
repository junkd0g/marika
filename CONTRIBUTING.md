# Contributing to Marika

Marika is a native macOS app written in Swift. Small, focused pull requests are welcome.
For a larger change, open an issue describing the problem and proposed behavior first.

## Development

Install macOS 15 or later and full Xcode 26.3 or newer, then run:

```sh
git clone https://github.com/junkd0g/marika.git
cd marika
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --no-parallel
scripts/build-app.sh debug
open build/Marika.app
```

The normal test suite uses local fixtures and temporary projects. It does not send prompts
to an AI provider. `scripts/smoke.sh` is separate: it uses an installed, signed-in agent and
can consume your plan usage. Run it only when you intend to test the live integration.

Install Go 1.24 or newer for the Go test-runner fixtures. CI selects Go explicitly and runs
test cases serially because many cases launch child processes. Concurrency-focused cases
still exercise their own concurrent operations.

The app also runs with `swift run Marika`. A bundled build is preferable for checking icons,
signing, Keychain access and the browser helper. The build script uses a local Apple Development
identity when available and otherwise signs ad hoc. No signing identity is needed to contribute.

## Structure

- `Sources/MarikaCore`: agent protocols, storage, filesystem operations and testable services.
- `Sources/Marika`: SwiftUI screens, AppKit controls and application state.
- `Sources/MarikaBrowserMCP`: the local browser and agent-tool bridge.
- `Tests/MarikaCoreTests`: unit and protocol integration tests, including synthetic servers.

`AppModel` owns application state and lifecycle; keep feature actions in focused extensions
under `App/`. Capture workspace state synchronously in `WorkspaceSnapshot` before awaiting
storage, so restored layouts and unsaved buffers belong to the same snapshot. In Design,
keep pointer interactions in the canvas model and editing/export actions in their extensions.

Keep command values and validation in `MarikaCore`, separate from process execution and
SwiftUI presentation. Container views delegate connection changes to their model; credential
validation and process launch construction have injectable dependencies for fixture tests.
Use typed presentation state and preserve persisted raw values when reorganizing code.
Keep routing and interaction entry points focused on sequencing. Extract validation,
conversion and feature-specific actions into named helpers when they obscure that flow;
preserve the order of validation, side effects and asynchronous operations when splitting them.

Use the existing Swift style. Keep blocking work out of the main actor, preserve unsaved editor
content, and make agent mutations explicit and reviewable. Add tests for protocol handling,
storage, concurrency and destructive operations. Check visual changes in both light and dark
appearance at compact and wide window sizes.

Before submitting, run `swift test --no-parallel` and `scripts/build-app.sh release`. Describe the user-visible
change and the checks you ran. Never include credentials, private source code, saved chats,
personal configuration or raw recordings in a pull request. Make protocol fixtures synthetic
or remove identifying content first.

Contributions are provided under the repository's [MIT license](LICENSE). Third-party components
retain their own licenses in [Resources/ThirdPartyNotices.txt](Resources/ThirdPartyNotices.txt)
and [Resources/EditorToolNotices.txt](Resources/EditorToolNotices.txt).
