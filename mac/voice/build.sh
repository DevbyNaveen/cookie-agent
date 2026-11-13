#!/bin/sh
# Build Enkeon.app without Xcode: SwiftPM binary + hand-assembled bundle, signed with the hardened
# runtime. The same shape as Cookie's mac/build.sh (cookie-harness).
#   ./build.sh            → build/Enkeon.app
#   ENKEON_SIGN_ID="Apple Development: …" ./build.sh   (a real identity keeps permission grants across rebuilds)
set -e
cd "$(dirname "$0")"

APP_SDK=$(scripts/sdk.sh app)
# A real identity keeps the signature stable across rebuilds, so macOS keeps the permission grants
# (ad-hoc "-" pins grants to the cdhash, which changes every build).
# A real identity keeps macOS permission grants across rebuilds; ad-hoc ("-") makes every build a new
# app to macOS. ponytail: takes the first Apple Development identity; set ENKEON_SIGN_ID to pick another.
SIGN_ID="${ENKEON_SIGN_ID:-$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')}"
SIGN_ID="${SIGN_ID:--}"

# Only the app: EnkeonVoiceKitChecks imports the kit @testable, which a release build doesn't allow.
if [ -n "$APP_SDK" ]; then SDKROOT="$APP_SDK" swift build -c release --build-system native --product Enkeon
else swift build -c release --build-system native --product Enkeon; fi

APP=build/Enkeon.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp .build/release/Enkeon "$APP/Contents/MacOS/Enkeon"
# MIT: the copyright notice ships inside the app.
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp -R App/Licenses "$APP/Contents/Resources/Licenses"
cp App/Info.plist "$APP/Contents/Info.plist"
cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
P=/usr/libexec/PlistBuddy
$P -c "Add :CFBundleExecutable string Enkeon" -c "Add :CFBundleIdentifier string com.enkeon.app" \
   -c "Add :CFBundleName string Enkeon" -c "Add :CFBundleDisplayName string Enkeon" \
   -c "Add :CFBundlePackageType string APPL" -c "Add :CFBundleShortVersionString string 0.0.1" \
   -c "Add :CFBundleVersion string 1" -c "Add :LSMinimumSystemVersion string 15.0" \
   -c "Add :NSHighResolutionCapable bool true" "$APP/Contents/Info.plist"

# Ears: enkeon-sense (SpeechAnalyzer) in its own process, built against a macOS 26+ SDK. Without it
# the app transcribes with SFSpeechRecognizer.
if [ -z "$ENKEON_SENSE_BIN" ]; then
  if SENSE_SDK=$(scripts/sdk.sh sense); then
    (cd Helpers/enkeon-sense && SDKROOT="$SENSE_SDK" swift build -c release --build-system native)
  else
    echo "note: no macOS 26+ SDK here, so enkeon-sense is left out"
  fi
fi
SENSE="${ENKEON_SENSE_BIN:-Helpers/enkeon-sense/.build/release/enkeon-sense}"
if [ -x "$SENSE" ]; then
  cp "$SENSE" "$APP/Contents/Helpers/enkeon-sense"
  # Inside-out: the helper is signed (hardened runtime, no entitlements) before the app seals it.
  codesign --force --options runtime --identifier com.enkeon.app.sense --sign "$SIGN_ID" "$APP/Contents/Helpers/enkeon-sense"
else
  echo "note: $SENSE is missing; dictation uses SFSpeechRecognizer"
fi

# Pen: enkeon-complete (llama.cpp's server, MIT) runs the sentence-completion model; scripts/llama.sh builds it.
COMPLETE=.build/llama/bin/llama-server
[ -x "$COMPLETE" ] || scripts/llama.sh
if [ -x "$COMPLETE" ]; then
  cp "$COMPLETE" "$APP/Contents/Helpers/enkeon-complete"
  codesign --force --options runtime --identifier com.enkeon.app.complete --sign "$SIGN_ID" "$APP/Contents/Helpers/enkeon-complete"
else
  echo "note: enkeon-complete didn't build; sentence completion is off"
fi

codesign --force --options runtime --sign "$SIGN_ID" --entitlements App/Enkeon.entitlements "$APP"
codesign --verify --strict --deep "$APP"
for BIN in "$APP" "$APP/Contents/Helpers/enkeon-sense" "$APP/Contents/Helpers/enkeon-complete"; do
  [ -e "$BIN" ] || continue
  codesign -dv "$BIN" 2>&1 | grep -Eq "flags=0x[0-9a-f]+\([^)]*runtime" || { echo "hardened runtime missing: $BIN"; exit 1; }
done
echo "built $APP"
