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
cp Resources/SparkleNotices.txt "$APP/Contents/Resources/SparkleNotices.txt"
if [[ -f Resources/EditorToolNotices.txt ]]; then cp Resources/EditorToolNotices.txt "$APP/Contents/Resources/EditorToolNotices.txt"; fi
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$FRAMEWORK"

# Configure release metadata without putting signing secrets into the bundle.
python3 - "$APP" <<'PY'
import base64, os, pathlib, plistlib, re, subprocess, sys, urllib.parse
app = pathlib.Path(sys.argv[1])
info_path = app / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
for variable, key in [('MARIKA_VERSION', 'CFBundleShortVersionString'), ('MARIKA_BUILD_NUMBER', 'CFBundleVersion')]:
    value = os.environ.get(variable)
    if value:
        if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', value):
            raise SystemExit(f'{variable} must be a numeric version.')
        info[key] = value
feed, public_key = os.environ.get('MARIKA_UPDATE_FEED_URL'), os.environ.get('MARIKA_UPDATE_PUBLIC_KEY')
if feed or public_key:
    url = urllib.parse.urlsplit(feed or '')
    if url.scheme != 'https' or not url.hostname or url.username or url.password:
        raise SystemExit('MARIKA_UPDATE_FEED_URL must be an HTTPS URL without credentials.')
    try:
        valid_key = len(base64.b64decode(public_key or '', validate=True)) == 32
    except ValueError:
        valid_key = False
    if not valid_key:
        raise SystemExit('MARIKA_UPDATE_PUBLIC_KEY must be a base64 Ed25519 public key.')
    info['SUFeedURL'], info['SUPublicEDKey'] = feed, public_key
    info['SURequireSignedFeed'] = True
info_path.write_bytes(plistlib.dumps(info))
# The app must load its embedded framework, rather than a local SwiftPM build folder.
binary = str(app / 'Contents/MacOS/Marika')
commands = subprocess.check_output(['/usr/bin/otool', '-l', binary], text=True)
for match in re.finditer(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset', commands):
    path = match.group(1)
    if path.startswith('/') and '/.build/' in path:
        subprocess.run(['/usr/bin/install_name_tool', '-delete_rpath', path, binary], check=True)
PY
if [[ -d .tools/bin ]]; then
  mkdir -p "$APP/Contents/Resources/Tools"
  cp .tools/bin/* "$APP/Contents/Resources/Tools/"
fi

# A stable signature keeps the Keychain from asking again after every rebuild.
IDENTITY=${MARIKA_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}
SIGN=(--force --sign "${IDENTITY:--}")
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then SIGN+=(--options runtime --timestamp); fi
for TOOL in "$APP"/Contents/Resources/Tools/*(N); do codesign "${SIGN[@]}" "$TOOL"; done
for SERVICE in "$FRAMEWORK"/Versions/Current/XPCServices/*.xpc(N); do
  codesign "${SIGN[@]}" --preserve-metadata=entitlements "$SERVICE"
done
codesign "${SIGN[@]}" "$FRAMEWORK/Versions/Current/Autoupdate"
codesign "${SIGN[@]}" --preserve-metadata=entitlements "$FRAMEWORK/Versions/Current/Updater.app"
codesign "${SIGN[@]}" "$FRAMEWORK"
codesign "${SIGN[@]}" "$APP/Contents/MacOS/MarikaBrowserMCP"
codesign "${SIGN[@]}" "$APP"
codesign --verify "$APP" && echo "Built $APP (${IDENTITY:-ad-hoc signature})"
