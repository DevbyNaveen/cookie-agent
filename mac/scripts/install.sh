#!/bin/sh
# Install Cookie for Mac from the cookie-mac channel release of DevbyNaveen/cookie-agent:
#
#   curl -fsSL https://github.com/DevbyNaveen/cookie-agent/releases/download/cookie-mac/install.sh | sh
#
# It reads the release's latest.json, downloads Cookie.zip over HTTPS, checks it against the
# release's SHA-256, checks the app's code signature and signing team, quits a running Cookie,
# puts the new one in /Applications (or ~/Applications when /Applications isn't writable, no sudo)
# and opens it. Safe to run again: it replaces Cookie in place and keeps your settings.
# Cookie then keeps itself up to date (Settings → About).
#
#   COOKIE_INSTALL_FROM=DIR   install DIR/latest.json + DIR/Cookie.zip instead of GitHub's (testing a release)
#   COOKIE_INSTALL_DIR=DIR    install into DIR instead of /Applications or ~/Applications
#   COOKIE_NO_LAUNCH=1        don't open Cookie afterwards
#
# scripts/release.sh stamps the signing team into the copy it publishes.

set -eu

REPO="DevbyNaveen/cookie-agent"
LATEST="https://github.com/$REPO/releases/download/cookie-mac/latest.json"
DOWNLOADS="https://github.com/$REPO/releases/download/"
TEAM_ID="${COOKIE_TEAM_ID:-@COOKIE_TEAM_ID@}"
MINIMUM_MACOS="15.0"
BUNDLE_ID="com.enkeon.cookie"

say() { printf '%s\n' "$*"; }
fail() { printf 'Cookie: %s\n' "$*" >&2; exit 1; }

# version_at_least A B: true when dotted version A >= B, number by number.
version_at_least() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, "."); k = n > m ? n : m
    for (i = 1; i <= k; i++) { p = (i <= n) ? x[i] + 0 : 0; q = (i <= m) ? y[i] + 0 : 0
      if (p > q) exit 0; if (p < q) exit 1 }
    exit 0 }'
}

[ "$(uname -s)" = "Darwin" ] || fail "Cookie is a Mac app; this computer runs $(uname -s)."
case "$TEAM_ID" in @*) fail "this install.sh wasn't stamped by scripts/release.sh (set COOKIE_TEAM_ID to test it)." ;; esac
MACOS="$(sw_vers -productVersion)"
version_at_least "$MACOS" "$MINIMUM_MACOS" ||
  fail "Cookie needs macOS $MINIMUM_MACOS (Sequoia) or later; this Mac has $MACOS. Update in System Settings → General → Software Update."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

# fetch <url> <file> [progress]: HTTPS only, retried, failing on any HTTP error.
fetch() {
  if [ -n "${3:-}" ]; then
    curl -fL --proto '=https' --tlsv1.2 --retry 3 --progress-bar -o "$2" "$1" || fail "couldn't download $1"
  else
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$2" "$1" || fail "couldn't download $1"
  fi
}

if [ -n "${COOKIE_INSTALL_FROM:-}" ]; then
  cp "$COOKIE_INSTALL_FROM/latest.json" "$WORK/latest.json" || fail "no latest.json in $COOKIE_INSTALL_FROM"
else
  fetch "$LATEST" "$WORK/latest.json"
fi
field() { plutil -extract "$1" raw -o - "$WORK/latest.json" 2>/dev/null || fail "latest.json has no $1"; }
VERSION="$(field version)"
SHA256="$(field sha256)"
URL="$(field url)"
NEEDS="$(field minimumSystemVersion)"
case "$URL" in "$DOWNLOADS"*/Cookie.zip) ;; *) fail "latest.json points somewhere unexpected: $URL" ;; esac
version_at_least "$MACOS" "$NEEDS" ||
  fail "Cookie $VERSION needs macOS $NEEDS or later; this Mac has $MACOS. Update in System Settings → General → Software Update."

say "Installing Cookie ${VERSION}…"
if [ -n "${COOKIE_INSTALL_FROM:-}" ]; then
  cp "$COOKIE_INSTALL_FROM/Cookie.zip" "$WORK/Cookie.zip" || fail "no Cookie.zip in $COOKIE_INSTALL_FROM"
else
  fetch "$URL" "$WORK/Cookie.zip" progress
fi
ACTUAL="$(shasum -a 256 "$WORK/Cookie.zip" | awk '{ print $1 }')"
[ "$ACTUAL" = "$SHA256" ] || fail "the download doesn't match the release's SHA-256 ($ACTUAL, expected $SHA256); nothing was installed."

ditto -x -k "$WORK/Cookie.zip" "$WORK/unpacked" || fail "couldn't unzip Cookie.zip"
NEW="$WORK/unpacked/Cookie.app"
[ -d "$NEW" ] || fail "Cookie.zip holds no Cookie.app"
[ "$(plutil -extract CFBundleIdentifier raw -o - "$NEW/Contents/Info.plist")" = "$BUNDLE_ID" ] || fail "the app in Cookie.zip isn't Cookie"
[ "$(plutil -extract CFBundleShortVersionString raw -o - "$NEW/Contents/Info.plist")" = "$VERSION" ] ||
  fail "the app in Cookie.zip isn't version $VERSION"
codesign --verify --strict --deep \
  -R="identifier \"$BUNDLE_ID\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\"" "$NEW" 2>/dev/null ||
  fail "Cookie.app's code signature is invalid or isn't from team $TEAM_ID; nothing was installed."

# Where: an existing Cookie stays where it is; else /Applications, or ~/Applications without sudo.
if [ -n "${COOKIE_INSTALL_DIR:-}" ]; then
  DIR="$COOKIE_INSTALL_DIR"
elif [ -d /Applications/Cookie.app ] && [ -w /Applications ]; then
  DIR=/Applications
elif [ -d "$HOME/Applications/Cookie.app" ]; then
  DIR="$HOME/Applications"
elif [ -w /Applications ]; then
  DIR=/Applications
else
  DIR="$HOME/Applications"
fi
mkdir -p "$DIR" || fail "couldn't create $DIR"
[ -w "$DIR" ] || fail "$DIR isn't writable; set COOKIE_INSTALL_DIR to a folder you own."
FINAL="$DIR/Cookie.app"
if [ "$DIR" != /Applications ] && [ -d /Applications/Cookie.app ] && [ -z "${COOKIE_INSTALL_DIR:-}" ]; then
  say "Note: /Applications/Cookie.app is someone else's and stays; this one goes in $DIR."
fi

# Quit the Cookie being replaced: asked politely first (it saves what it's doing), then told.
running() { pgrep -f "$FINAL/Contents/MacOS/Cookie" >/dev/null 2>&1; }
if running; then
  say "Quitting Cookie…"
  osascript -e "tell application \"$FINAL\" to quit" >/dev/null 2>&1 &
  waited=0
  while running && [ "$waited" -lt 150 ]; do sleep 0.1; waited=$((waited + 1)); done
  if running; then pkill -TERM -f "$FINAL/Contents/MacOS/Cookie" 2>/dev/null || true; sleep 3; fi
  if running; then pkill -KILL -f "$FINAL/Contents/MacOS/Cookie" 2>/dev/null || true; sleep 1; fi
  running && fail "Cookie didn't quit; quit it from its menu and run this again."
fi

# Swap: the new app is copied in beside the old one, then they trade places; any failure keeps the old one.
STAGING="$DIR/.Cookie.app.installing"
PREVIOUS="$DIR/.Cookie.app.previous"
rm -rf "$STAGING" "$PREVIOUS"
ditto "$NEW" "$STAGING" || { rm -rf "$STAGING"; fail "couldn't copy Cookie into $DIR"; }
if [ -d "$FINAL" ]; then
  mv "$FINAL" "$PREVIOUS" || { rm -rf "$STAGING"; fail "couldn't move the old Cookie aside"; }
fi
if ! mv "$STAGING" "$FINAL"; then
  [ -d "$PREVIOUS" ] && mv "$PREVIOUS" "$FINAL"
  rm -rf "$STAGING"
  fail "couldn't put Cookie in $DIR; the old one is back."
fi
rm -rf "$PREVIOUS"
# Downloaded with curl, so no quarantine is set; cleared anyway in case a browser download left one.
xattr -dr com.apple.quarantine "$FINAL" 2>/dev/null || true

[ -n "${COOKIE_NO_LAUNCH:-}" ] || open "$FINAL"

say ""
say "Cookie $VERSION is installed in $FINAL."
say ""
say "Next:"
say "  1. Cookie lives in the menu bar and the notch. Its setup asks for what it needs as you go:"
say "     Microphone, Speech Recognition, Accessibility, Screen Recording and Input Monitoring."
say "     If macOS sends you to System Settings → Privacy & Security, switch Cookie on there;"
say "     Cookie's Settings → Permissions shows each one."
say "  2. Pick a model and add your key in Cookie's Settings → Voice (or sign in with Enkeon)."
say "  3. Hold fn and Option, speak, let go."
say ""
say "Cookie updates itself; Settings → About shows the version and checks now."
