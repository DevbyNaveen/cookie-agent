#!/bin/sh
# Start over: stop Enkeon and the dev watcher, delete every build cache (app, helper, bundle),
# rebuild the signed app, register it with macOS, then run dev mode.
#   scripts/fresh.sh                 keeps macOS permissions
#   scripts/fresh.sh --permissions   also forgets them (macOS asks again on first use)
set -e
cd "$(dirname "$0")/.."

pkill -f "scripts/dev.sh" 2>/dev/null || true
pkill -f "build/Enkeon.app/Contents/MacOS/Enkeon" 2>/dev/null || true

rm -rf .build build Helpers/enkeon-sense/.build
echo "✓ caches cleared"

if [ "$1" = "--permissions" ]; then
  tccutil reset All com.enkeon.app >/dev/null
  echo "✓ permissions forgotten: allow them again in Enkeon's setup"
fi

./build.sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f build/Enkeon.app
echo "✓ registered with macOS"

exec scripts/dev.sh
