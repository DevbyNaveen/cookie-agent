#!/bin/sh
# Every check for the Mac app, in order: Enkeon dictation's kit checks, then Cookie's native checks.
# Run in a logged-in macOS session. Refuses to start when the disk is too full to build.
set -e
cd "$(dirname "$0")/.."
FREE_GB=$(df -g / | awk 'NR==2 { print $4 }')
[ "$FREE_GB" -ge 6 ] || { echo "error: only ${FREE_GB} GB free; 6 GB are needed to build. Clean build folders first." >&2; exit 1; }
(cd voice && SDKROOT="$(scripts/sdk.sh app)" swift run --build-system native EnkeonVoiceKitChecks)
python3 scripts/check_cookie_interactions.py
