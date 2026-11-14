#!/bin/sh
# Renders Brand/enkeon-voice-icon.svg into App/AppIcon.icns (every size macOS asks for).
set -e
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
swiftc -O scripts/svg2png.swift -o "$WORK/svg2png"
SET="$WORK/AppIcon.iconset" && mkdir "$SET"
for size in 16 32 128 256 512; do
  "$WORK/svg2png" Brand/enkeon-voice-icon.svg "$SET/icon_${size}x${size}.png" $size
  "$WORK/svg2png" Brand/enkeon-voice-icon.svg "$SET/icon_${size}x${size}@2x.png" $((size * 2))
done
iconutil -c icns "$SET" -o App/AppIcon.icns
rm -rf "$WORK"
echo "wrote App/AppIcon.icns"
