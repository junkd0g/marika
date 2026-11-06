#!/bin/zsh
# Builds Marika.app. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "${0:a:h}/.."

CONFIG=${1:-release}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

BUILD_LOG=$(mktemp -t marika-build)
trap 'rm -f "$BUILD_LOG"' EXIT
if ! swift build -c "$CONFIG" >"$BUILD_LOG" 2>&1; then
  cat "$BUILD_LOG" >&2
  exit 1
fi
grep -E 'error:|Compiling Marika|Build complete' "$BUILD_LOG" | tail -5 || true
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/Marika"

APP=build/Marika.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Marika"
cp "${BINARY:h}/MarikaBrowserMCP" "$APP/Contents/MacOS/MarikaBrowserMCP"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/ThirdPartyNotices.txt "$APP/Contents/Resources/ThirdPartyNotices.txt"
if [[ -f Resources/EditorToolNotices.txt ]]; then cp Resources/EditorToolNotices.txt "$APP/Contents/Resources/EditorToolNotices.txt"; fi
if [[ -d .tools/bin ]]; then
  mkdir -p "$APP/Contents/Resources/Tools"
  cp .tools/bin/* "$APP/Contents/Resources/Tools/"
  for TOOL in "$APP/Contents/Resources/Tools/"*; do codesign --force --sign - "$TOOL"; done
fi

# A stable signature keeps the Keychain from asking again after every rebuild.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/MacOS/MarikaBrowserMCP"
codesign --force --sign "${IDENTITY:--}" "$APP"
codesign --verify "$APP" && echo "Built $APP (${IDENTITY:-ad-hoc signature})"
