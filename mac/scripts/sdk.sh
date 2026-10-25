#!/bin/sh
# Which macOS SDK to build with, from whatever this Mac has installed.
#   scripts/sdk.sh app     Cookie itself: prints the SDK path, or nothing for Xcode's default.
#   scripts/sdk.sh sense   cookie-sense: prints an SDK path, or exits 2 when none can build it.
#
# Cookie's SwiftUI needs either full Xcode, or a macOS 15 SDK: from SDK 26 on, SwiftUI's
# @State is a macro whose compiler plugin ships only with Xcode, not the Command Line Tools.
# cookie-sense needs SDK 26 or later (SpeechAnalyzer) and no SwiftUI, so the tools are enough.
what="${1:-app}"
developer=$(xcode-select -p 2>/dev/null)
case "$developer" in *.app/Contents/Developer) xcode=1 ;; *) xcode= ;; esac

# Every SDK this Mac has, as "<major> <path>", newest last.
sdks() {
  for dir in "$developer/SDKs" "$developer/Platforms/MacOSX.platform/Developer/SDKs" /Library/Developer/CommandLineTools/SDKs; do
    ls -d "$dir"/MacOSX[0-9]*.sdk 2>/dev/null
  done | sort -V | while read -r sdk; do
    version=${sdk##*/MacOSX}; echo "${version%%.*} $sdk"
  done
}

case "$what" in
  app)
    [ -n "$xcode" ] && exit 0
    sdk=$(sdks | awk '$1 == 15 { path = $2 } END { print path }')
    if [ -z "$sdk" ]; then
      echo "error: no macOS 15 SDK found. Building Cookie with the Command Line Tools alone needs the macOS 15 SDK" >&2
      echo "       (SDK 26 and later need Xcode's SwiftUI plugin). Install Xcode, or the Command Line Tools for Xcode 16" >&2
      echo "       from https://developer.apple.com/download/all/ ; or set SDKROOT yourself." >&2
      exit 1
    fi
    echo "$sdk" ;;
  sense)
    sdk=$(sdks | awk '$1 >= 26 { path = $2 } END { print path }')
    [ -n "$sdk" ] || exit 2
    echo "$sdk" ;;
  *) echo "usage: $0 app|sense" >&2; exit 64 ;;
esac
