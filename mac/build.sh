#!/bin/sh
# Build Cookie.app without Xcode: SwiftPM binary + hand-assembled bundle, signed with the hardened runtime.
# One command builds everything: Cookie's core, its helpers and the app, with the SDKs this Mac has.
set -e
cd "$(dirname "$0")"
command -v cargo >/dev/null || { echo "error: Rust is needed (https://rustup.rs), 1.91 or later" >&2; exit 1; }
RUSTV=$(rustc --version | awk '{print $2}')
[ "$(printf '1.91.0\n%s\n' "$RUSTV" | sort -V | head -1)" = "1.91.0" ] || { echo "error: Rust $RUSTV is too old; 1.91 or later (rustup update)" >&2; exit 1; }
APP_SDK=$(scripts/sdk.sh app)
# Cookie thinks through `cookie serve`, this repo's core, bundled as a helper.
# Built here with Amazon Bedrock (the `bedrock` cargo feature, Rust 1.91+), so every
# provider Settings offers can answer. COOKIE_HARNESS_BIN uses a binary you built instead.
if [ -n "$COOKIE_HARNESS_BIN" ]; then
  HARNESS="$COOKIE_HARNESS_BIN"
else
  (cd .. && cargo build --release --bin cookie --features bedrock)
  HARNESS=../target/release/cookie
fi
[ -x "$HARNESS" ] || { echo "error: harness binary not found or not executable: $HARNESS" >&2
  echo "       build it (cargo build --release --bin cookie --features bedrock) or set COOKIE_HARNESS_BIN" >&2; exit 1; }
# Your Developer ID (security find-identity -v -p codesigning) keeps the signature
# stable across rebuilds; without one the app is signed ad hoc (macOS then asks for
# its permissions again after each rebuild).
SIGN_ID="${COOKIE_SIGN_ID:--}"
TIMESTAMP=""; [ "$1" = "--release" ] && TIMESTAMP="--timestamp"
# scripts/sdk.sh says why the SDK matters (empty: Xcode's own default).
if [ -n "$APP_SDK" ]; then SDKROOT="$APP_SDK" swift build -c release --build-system native
else swift build -c release --build-system native; fi
APP=build/Cookie.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp .build/release/Cookie "$APP/Contents/MacOS/Cookie"
# MIT: the upstream copyright notice ships inside the app.
cp LICENSE "$APP/Contents/Resources/LICENSE"
# Skills the agent can load (skills/validate.py checks them).
python3 skills/validate.py >/dev/null
rm -rf "$APP/Contents/Resources/skills" && mkdir -p "$APP/Contents/Resources/skills"
for d in skills/*/; do [ -f "${d}SKILL.md" ] && cp -R "${d%/}" "$APP/Contents/Resources/skills/"; done
# The app icon (scripts/make-icon.sh draws it).
cp Cookie/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Cookie/Info.plist "$APP/Contents/Info.plist"
P=/usr/libexec/PlistBuddy
$P -c "Add :CFBundleExecutable string Cookie" -c "Add :CFBundleIdentifier string com.enkeon.cookie" \
   -c "Add :CFBundleName string Cookie" -c "Add :CFBundleDisplayName string Cookie" \
   -c "Add :CFBundlePackageType string APPL" -c "Add :CFBundleShortVersionString string 0.1.0" \
   -c "Add :CFBundleVersion string 1" -c "Add :CFBundleIconFile string AppIcon" \
   -c "Add :NSAppleEventsUsageDescription string 'Cookie edits documents in this app only for a task you approved.'" -c "Add :LSMinimumSystemVersion string 15.0" "$APP/Contents/Info.plist"
# A real identity keeps the signature stable across rebuilds, so macOS keeps the permission grants
# (ad-hoc "-" pins grants to the cdhash, which changes every build). Override with COOKIE_SIGN_ID.
# Hardened runtime with zero exception entitlements: code injected into Cookie
# would otherwise inherit its screen, keyboard and accessibility grants.
# Inside-out: the helper is signed (same identity, hardened runtime, no
# entitlements) before the app seals it. Contents/Helpers is Apple's place for
# helper executables that aren't the app's main one.
cp "$HARNESS" "$APP/Contents/Helpers/cookie"
codesign --force --options runtime $TIMESTAMP --identifier com.enkeon.cookie.harness --sign "$SIGN_ID" "$APP/Contents/Helpers/cookie"
# Files: cookie-tools (spreadsheets, documents, pages, CSV), a signed helper like the harness.
[ -n "$COOKIE_TOOLS_BIN" ] || (cd cookie-tools && cargo build --release)
TOOLS="${COOKIE_TOOLS_BIN:-cookie-tools/target/release/cookie-tools}"
if [ -x "$TOOLS" ]; then
  cp "$TOOLS" "$APP/Contents/Helpers/cookie-tools"
  codesign --force --options runtime $TIMESTAMP --identifier com.enkeon.cookie.tools --sign "$SIGN_ID" "$APP/Contents/Helpers/cookie-tools"
else
  echo "note: $TOOLS is missing; files are left out"
fi
# Meetings: cookie-recorder (microphone + the call's sound, sent to Enkeon a minute at a time).
[ -n "$COOKIE_RECORDER_BIN" ] || (cd cookie-recorder && cargo build --release)
RECORDER="${COOKIE_RECORDER_BIN:-cookie-recorder/target/release/cookie-recorder}"
if [ -x "$RECORDER" ]; then
  cp "$RECORDER" "$APP/Contents/Helpers/cookie-recorder"
  codesign --force --options runtime $TIMESTAMP --identifier com.enkeon.cookie.recorder --sign "$SIGN_ID" "$APP/Contents/Helpers/cookie-recorder"
else
  echo "note: $RECORDER is missing; meeting recording is left out"
fi
# Eyes and ears: cookie-sense (Vision text and faces, SpeechAnalyzer) in its own process, so a
# Vision model that fails to load can't take Cookie down. A Swift package built against a macOS 26+
# SDK (it needs no SwiftUI, so no Xcode). Without it Cookie reads screenshots in its own process and
# transcribes with SFSpeechRecognizer.
if [ -z "$COOKIE_SENSE_BIN" ]; then
  if SENSE_SDK=$(scripts/sdk.sh sense); then
    (cd cookie-sense && SDKROOT="$SENSE_SDK" swift build -c release --build-system native)
  else
    echo "note: no macOS 26+ SDK here, so cookie-sense is left out"
  fi
fi
SENSE="${COOKIE_SENSE_BIN:-cookie-sense/.build/release/cookie-sense}"
if [ -x "$SENSE" ]; then
  cp "$SENSE" "$APP/Contents/Helpers/cookie-sense"
  codesign --force --options runtime $TIMESTAMP --identifier com.enkeon.cookie.sense --sign "$SIGN_ID" "$APP/Contents/Helpers/cookie-sense"
else
  echo "note: $SENSE is missing; screen reading stays in-process"
fi
# Research and decks: the bundled Python (scripts/bundle-python.sh) running cookie-py,
# every Mach-O signed inside-out before the app seals it (no entitlements needed, measured).
if [ -d vendor/python ]; then
  # In Resources, not Frameworks: codesign reads every folder in Frameworks as a framework bundle.
  mkdir -p "$APP/Contents/Resources/cookie-py"
  cp -R vendor/python "$APP/Contents/Resources/python"
  cp cookie-py/server.py "$APP/Contents/Resources/cookie-py/server.py"
  scripts/sign-python.sh "$APP/Contents/Resources/python" "$SIGN_ID" --options runtime $TIMESTAMP >/dev/null
else
  echo "note: vendor/python is missing (run scripts/bundle-python.sh); research and decks are left out"
fi
codesign --force --options runtime $TIMESTAMP --sign "$SIGN_ID" --entitlements Cookie/Cookie.entitlements "$APP"
codesign --verify --strict --deep "$APP"
for BIN in "$APP" "$APP/Contents/Helpers/cookie"; do
  codesign -dv "$BIN" 2>&1 | grep -Eq "flags=0x[0-9a-f]+\([^)]*runtime" || { echo "hardened runtime missing: $BIN"; exit 1; }
done
echo "built $APP"

# ./build.sh --release → notarize and staple (needs a Developer ID Application
# certificate in COOKIE_SIGN_ID and `xcrun notarytool store-credentials cookie-notary`).
if [ "$1" = "--release" ]; then
  ZIP=build/Cookie.zip
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "${COOKIE_NOTARY_PROFILE:-cookie-notary}" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute -vv "$APP"
  rm -f "$ZIP"
fi
