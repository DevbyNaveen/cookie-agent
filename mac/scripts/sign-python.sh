#!/bin/bash
# Codesign every Mach-O in a bundled Python tree, innermost first, then verify.
#
#   scripts/sign-python.sh <app-bundle-python-dir> <SIGN_ID> [codesign flags…]
#
# The flags default to `--options runtime --timestamp` (hardened runtime, as
# notarization requires). Pass your own to replace them, e.g.
# `--options runtime --timestamp --entitlements python.entitlements`.
# Measured 2026-10-13: the bundled CPython 3.12 + lxml + Pillow + orjson run
# under the hardened runtime with NO entitlements (see cookie-py/README.md).
set -euo pipefail

[ $# -ge 2 ] || { echo "usage: $0 <python-dir> <SIGN_ID> [codesign flags…]" >&2; exit 2; }
DIR="$(cd "$1" && pwd)"
ID="$2"
shift 2
FLAGS=("$@")
[ ${#FLAGS[@]} -gt 0 ] || FLAGS=(--options runtime --timestamp)

# Every regular file that is Mach-O (by its magic, not its name), deepest path first,
# so a library is signed before anything that sits above it.
MACHO=()
while IFS= read -r f; do MACHO+=("$f"); done < <(
  find "$DIR" -type f -print0 \
    | xargs -0 file --no-pad --separator '|' \
    | awk -F'|' '$2 ~ /Mach-O/ { print $1 }' \
    | awk -F/ '{ print NF "\t" $0 }' | sort -rn -k1,1 | cut -f2-
)
[ ${#MACHO[@]} -gt 0 ] || { echo "no Mach-O files under $DIR" >&2; exit 1; }

echo "==> signing ${#MACHO[@]} Mach-O files with ${FLAGS[*]}"
for f in "${MACHO[@]}"; do
  codesign --force --sign "$ID" "${FLAGS[@]}" "$f"
done

echo "==> verifying"
for f in "${MACHO[@]}"; do
  codesign --verify --strict "$f" || { echo "verification failed: $f" >&2; exit 1; }
done
echo "    all ${#MACHO[@]} verify (--strict)"
