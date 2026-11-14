#!/bin/sh
# Dev mode: save a Swift file and Enkeon rebuilds (debug, incremental), swaps its binary inside
# build/Enkeon.app and reopens. The bundle, its speech helper and its signature identity stay put,
# so macOS keeps the microphone / Accessibility / Input Monitoring grants between reloads.
#   scripts/dev.sh                      (Ctrl-C to stop)
#   ENKEON_SIGN_ID="Apple Development: …" scripts/dev.sh
# No Xcode, so no SwiftUI previews: this is the Command Line Tools' live loop.
set -e
cd "$(dirname "$0")/.."

# A real identity keeps macOS permission grants across rebuilds; ad-hoc ("-") makes every build a new
# app to macOS. ponytail: takes the first Apple Development identity; set ENKEON_SIGN_ID to pick another.
SIGN_ID="${ENKEON_SIGN_ID:-$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')}"
SIGN_ID="${SIGN_ID:--}"
APP=build/Enkeon.app
SDK=$(scripts/sdk.sh app)
STAMP=.build/dev.stamp

# The bundle (Info.plist, helper, entitlements) comes from the full build, once.
[ -x "$APP/Contents/MacOS/Enkeon" ] || ENKEON_SIGN_ID="$SIGN_ID" ./build.sh

# The speech + clean-up helper is its own package (macOS 26+ SDK): rebuilt and re-signed when it changes.
reload_helper() {
  echo "⟳ building the speech helper…"
  if ! out=$(cd Helpers/enkeon-sense && SDKROOT="$(../../scripts/sdk.sh sense)" swift build -c release --build-system native 2>&1); then
    echo "$out" | grep -E "error:" | sort -u
    echo "✗ helper build failed; the running helper is unchanged"
    return 1
  fi
  cp Helpers/enkeon-sense/.build/release/enkeon-sense "$APP/Contents/Helpers/enkeon-sense"
  codesign --force --options runtime --identifier com.enkeon.app.sense --sign "$SIGN_ID" "$APP/Contents/Helpers/enkeon-sense" 2>/dev/null
}

reload() {
  echo "⟳ building…"
  start=$(date +%s)
  if ! out=$(SDKROOT="$SDK" swift build --build-system native --product Enkeon 2>&1); then
    echo "$out" | grep -E "error:" | sed -E 's#.*/Sources/#Sources/#' | sort -u
    echo "✗ build failed; the running app is unchanged"
    return
  fi
  echo "$out" | grep -E "warning:" | grep -v deprecated | sed -E 's#.*/Sources/#Sources/#' | sort -u
  pkill -f "$APP/Contents/MacOS/Enkeon" 2>/dev/null || true
  pkill -f "$APP/Contents/Helpers/enkeon-complete" 2>/dev/null || true
  cp .build/debug/Enkeon "$APP/Contents/MacOS/Enkeon"
  # Preserve generated bundle identity/version while refreshing source-controlled permissions
  # and URL handlers. Otherwise incremental builds silently keep obsolete Info.plist metadata.
  python3 - <<'PY'
import plistlib
from pathlib import Path
target = Path('build/Enkeon.app/Contents/Info.plist')
with target.open('rb') as handle:
    info = plistlib.load(handle)
with Path('App/Info.plist').open('rb') as handle:
    info.update(plistlib.load(handle))
with target.open('wb') as handle:
    plistlib.dump(info, handle)
PY
  codesign --force --options runtime --sign "$SIGN_ID" --entitlements App/Enkeon.entitlements "$APP" 2>/dev/null
  open --stdout build/app.log --stderr build/app.log "$APP"  # the app's own log: tail -f build/app.log
  echo "✓ reloaded in $(( $(date +%s) - start ))s  $(date +%H:%M:%S)"
}

mkdir -p .build && touch "$STAMP"
reload
echo "watching Sources/ and Helpers/ — save a file to reload, Ctrl-C to stop"
trap 'pkill -f "$APP/Contents/MacOS/Enkeon" 2>/dev/null; exit 0' INT TERM
while :; do
  sleep 0.5
  helper_changed=$(find Helpers/enkeon-sense/Sources -name '*.swift' -newer "$STAMP" -print -quit)
  app_changed=$(find Sources -name '*.swift' -newer "$STAMP" -print -quit)
  if [ -n "$helper_changed" ] || [ -n "$app_changed" ]; then
    touch "$STAMP"
    if [ -n "$helper_changed" ]; then reload_helper || true; fi
    reload
  fi
done
