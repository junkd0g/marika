#!/bin/zsh
# Native UI integration test. Uses mock agents, temporary projects and separate saved data.
set -euo pipefail
cd "${0:a:h}/.."
CHAT_FIXTURE=$(mktemp -d)
trap 'rm -rf "$CHAT_FIXTURE"' EXIT
CHAT_ARTIFACTS="${MARIKA_CHAT_ARTIFACTS:-$PWD/build/chat-review}"
mkdir -p "$CHAT_FIXTURE/Studio" "$CHAT_FIXTURE/data" "$CHAT_ARTIFACTS"
printf 'func health() -> Bool { true }\n' > "$CHAT_FIXTURE/Studio/Health.swift"
python3 - "$CHAT_FIXTURE" "$CHAT_ARTIFACTS" <<'PY'
import json, pathlib, sys
root, artifacts = sys.argv[1:]
steps = [
    {"op": "open", "path": root + "/Studio"},
    {"op": "size", "width": 1440, "height": 900},
    {"op": "appearance", "dark": True},
    {"op": "wait", "seconds": 0.6},
    {"op": "projectChatTest", "directory": artifacts},
    {"op": "quit"},
]
pathlib.Path(root, "steps.json").write_text(json.dumps(steps))
PY
MARIKA_DRIVER="$CHAT_FIXTURE/steps.json" MARIKA_DATA="$CHAT_FIXTURE/data" \
    MARIKA_EDITOR_DEFAULTS_SUITE="marika.chat-test.$RANDOM" \
    .build/debug/Marika > "$CHAT_ARTIFACTS/native-test.log" 2>&1
rg 'Project chat passed' "$CHAT_ARTIFACTS/native-test.log"
