#!/bin/zsh
# Builds with full Xcode (no need to change xcode-select) and prints only diagnostics.
set -uo pipefail
cd "${0:a:h}/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
BUILD_LOG=$(mktemp -t marika-check)
trap 'rm -f "$BUILD_LOG"' EXIT
BUILD_STATUS=0
swift build "$@" >"$BUILD_LOG" 2>&1 || BUILD_STATUS=$?
sed -E 's/\x1b\[[0-9;]*m//g; s/\x1b\]8;;[^\x1b]*\x1b\\//g' "$BUILD_LOG" \
  | grep -E '(error|warning):|Build complete|Compiling .*failed|Build failed' \
  | grep -v 'add .@preconcurrency' | sort -u | cut -c1-260 | head -40
if (( BUILD_STATUS != 0 )); then
  cat "$BUILD_LOG" >&2
fi
exit "$BUILD_STATUS"
