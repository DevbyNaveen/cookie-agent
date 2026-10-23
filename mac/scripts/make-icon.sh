#!/bin/sh
# Renders scripts/make-icon.swift into Cookie/AppIcon.icns.
set -e
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
swift scripts/make-icon.swift "$TMP/icon-1024.png"
mkdir "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon-1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon-1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o Cookie/AppIcon.icns
cp "$TMP/icon-1024.png" Cookie/AppIcon-1024.png
rm -rf "$TMP"
echo "wrote Cookie/AppIcon.icns"
