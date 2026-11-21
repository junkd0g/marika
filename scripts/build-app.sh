#!/bin/zsh
# Builds Marika.app. Usage: scripts/build-app.sh [debug|release]
# Set MARIKA_APP_OUTPUT to package into a separate .app without replacing the installed build.
set -euo pipefail
cd "${0:a:h}/.."

CONFIG=${1:-release}
CHANNEL=${MARIKA_CHANNEL:-development}
STORE=0
SWIFT_ARGS=(--manifest-cache none)
case "$CHANNEL" in
  development) ;;
  website)
    [[ "${MARIKA_SIGNING_IDENTITY:-}" == "Developer ID Application:"* ]] || { echo "Set MARIKA_SIGNING_IDENTITY to a Developer ID Application identity." >&2; exit 1; }
    [[ -n "${MARIKA_NOTARY_PROFILE:-}" ]] || { echo "Set MARIKA_NOTARY_PROFILE to a notarytool keychain profile." >&2; exit 1; };;
  app-store|store-prototype)
    STORE=1
    SWIFT_ARGS+=(--scratch-path .build/store)
    if [[ "$CHANNEL" == app-store ]]; then
      [[ "${MARIKA_SIGNING_IDENTITY:-}" == "Apple Distribution:"* || "${MARIKA_SIGNING_IDENTITY:-}" == "3rd Party Mac Developer Application:"* ]] || { echo "Set a Mac App Store distribution signing identity." >&2; exit 1; }
      [[ -n "${MARIKA_INSTALLER_IDENTITY:-}" ]] || { echo "Set MARIKA_INSTALLER_IDENTITY to a Mac Installer Distribution identity." >&2; exit 1; }
    fi;;
  *) echo "Unknown MARIKA_CHANNEL: $CHANNEL" >&2; exit 1;;
esac
export MARIKA_STORE_BUILD="$STORE"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

BUILD_LOG=$(mktemp -t marika-build)
trap 'rm -f "$BUILD_LOG"' EXIT
if ! swift build "${SWIFT_ARGS[@]}" -c "$CONFIG" >"$BUILD_LOG" 2>&1; then
  cat "$BUILD_LOG" >&2
  exit 1
fi
grep -E 'error:|Compiling Marika|Build complete' "$BUILD_LOG" | tail -5 || true
BINARY="$(swift build "${SWIFT_ARGS[@]}" -c "$CONFIG" --show-bin-path)/Marika"

DEFAULT_APP=build/Marika.app
if [[ "$CHANNEL" != development ]]; then DEFAULT_APP="build/$CHANNEL/Marika.app"; fi
APP=${MARIKA_APP_OUTPUT:-$DEFAULT_APP}
if [[ "$APP" != *.app || "$APP" == .app || "$APP" == /.app ]]; then
  echo 'MARIKA_APP_OUTPUT must name an .app bundle.' >&2
  exit 1
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Marika"
cp "${BINARY:h}/MarikaBrowserMCP" "$APP/Contents/MacOS/MarikaBrowserMCP"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/ThirdPartyNotices.txt "$APP/Contents/Resources/ThirdPartyNotices.txt"
cp Resources/Privacy.html "$APP/Contents/Resources/Privacy.html"
if [[ -f Resources/EditorToolNotices.txt ]]; then cp Resources/EditorToolNotices.txt "$APP/Contents/Resources/EditorToolNotices.txt"; fi
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if (( ! STORE )); then
cp Resources/SparkleNotices.txt "$APP/Contents/Resources/SparkleNotices.txt"
mkdir -p "$APP/Contents/Frameworks"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$FRAMEWORK"
else
  python3 scripts/bundle-codex.py "$APP"
fi

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
if os.environ.get('MARIKA_STORE_BUILD') == '1':
    for key in list(info):
        if key.startswith('SU'):
            del info[key]
    if os.environ.get('MARIKA_CHANNEL') == 'store-prototype':
        info['CFBundleIdentifier'] = 'app.marika.testing.store'
elif feed or public_key:
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
HELPER_SIGN=("${SIGN[@]}")
if (( STORE )); then
  HELPER_SIGN+=(--entitlements Resources/SandboxHelper.entitlements)
  if [[ -n "${MARIKA_PROVISIONING_PROFILE:-}" ]]; then cp "$MARIKA_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"; fi
fi
for TOOL in "$APP"/Contents/Resources/Tools/*(N) "$APP"/Contents/Helpers/Codex.app/Contents/MacOS/*(N); do codesign "${HELPER_SIGN[@]}" "$TOOL"; done
if (( STORE )); then
  codesign "${HELPER_SIGN[@]}" "$APP/Contents/Helpers/Codex.app"
else
for SERVICE in "$FRAMEWORK"/Versions/Current/XPCServices/*.xpc(N); do
  codesign "${SIGN[@]}" --preserve-metadata=entitlements "$SERVICE"
done
codesign "${SIGN[@]}" "$FRAMEWORK/Versions/Current/Autoupdate"
codesign "${SIGN[@]}" --preserve-metadata=entitlements "$FRAMEWORK/Versions/Current/Updater.app"
codesign "${SIGN[@]}" "$FRAMEWORK"
fi
codesign "${HELPER_SIGN[@]}" "$APP/Contents/MacOS/MarikaBrowserMCP"
if (( STORE )); then SIGN+=(--entitlements Resources/SandboxApp.entitlements); fi
codesign "${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
if [[ "$CHANNEL" == website ]]; then
  NOTARY_DIR=$(mktemp -d)
  trap 'rm -rf "$NOTARY_DIR"; rm -f "$BUILD_LOG"' EXIT
  ditto -c -k --keepParent "$APP" "$NOTARY_DIR/Marika.zip"
  xcrun notarytool submit "$NOTARY_DIR/Marika.zip" --keychain-profile "$MARIKA_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute "$APP"
elif [[ "$CHANNEL" == app-store ]]; then
  productbuild --component "$APP" /Applications --sign "$MARIKA_INSTALLER_IDENTITY" "${APP:r}.pkg"
fi
echo "Built $APP (${IDENTITY:-ad-hoc signature})"
