#!/bin/zsh
# Drives the real debug app through one approved edit, using a throwaway project and data folder.
# Uses a small amount of your plan (Haiku, low effort). Prints PASS or FAIL.
set -euo pipefail
cd "${0:a:h}/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/project" "$WORK/data"
git -C "$WORK/project" init -q
printf 'hello\n' > "$WORK/project/notes.txt"
git -C "$WORK/project" add -A
git -C "$WORK/project" -c user.email=smoke@example.com -c user.name=Smoke commit -qm "Initial commit"

cat > "$WORK/steps.json" <<JSON
[
  {"op": "open", "path": "$WORK/project"},
  {"op": "wait", "seconds": 1},
  {"op": "waitFor", "what": "agents"},
  {"op": "settings", "model": "haiku", "effort": "low"},
  {"op": "send", "text": "Use the Edit tool to change hello to goodbye in notes.txt. Then say done."},
  {"op": "waitFor", "what": "idle", "approve": true},
  {"op": "wait", "seconds": 1},
  {"op": "shot", "path": "$WORK/result.png"},
  {"op": "quit"}
]
JSON

scripts/build-app.sh debug >/dev/null
MARIKA_DRIVER="$WORK/steps.json" MARIKA_DATA="$WORK/data" build/Marika.app/Contents/MacOS/Marika 2>&1 \
  | grep -E 'FAILED' || true

if grep -q goodbye "$WORK/project/notes.txt" && [[ -s "$WORK/result.png" ]]; then
  echo PASS
else
  echo FAIL
  exit 1
fi
