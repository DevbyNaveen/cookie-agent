#!/bin/bash
# Build Cookie's private Python runtime into vendor/python:
# a pinned, hash-checked python-build-standalone CPython plus the
# hash-pinned wheels in cookie-py/requirements.txt. Re-runnable: it starts
# from an empty vendor/python each time.
set -euo pipefail

PBS_TAG="20261009"
PBS_FILE="cpython-3.12.15+${PBS_TAG}-aarch64-apple-darwin-install_only.tar.gz"
# From the release's SHA256SUMS (and GitHub's asset digest), checked 2026-10-13.
PBS_SHA256="83dcb04777c798bd95f3687acf9ae84b09860272ee6bdfb05be8bcf9447f75b8"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PBS_FILE//+/%2B}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
PY="$VENDOR/python/bin/python3"
REQS="$ROOT/cookie-py/requirements.txt"

[ "$(uname -m)" = "arm64" ] || { echo "this build is aarch64-apple-darwin; run it on Apple silicon" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> downloading $PBS_FILE"
curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 -o "$WORK/$PBS_FILE" "$PBS_URL"
echo "$PBS_SHA256  $WORK/$PBS_FILE" | shasum -a 256 --check --status \
  || { echo "SHA-256 mismatch for $PBS_FILE — refusing to unpack" >&2; exit 1; }
echo "    sha256 ok"

rm -rf "$VENDOR/python"
mkdir -p "$VENDOR"
tar -xzf "$WORK/$PBS_FILE" -C "$VENDOR"   # unpacks to vendor/python

echo "==> installing hash-pinned wheels"
PIP_DISABLE_PIP_VERSION_CHECK=1 "$PY" -I -B -m pip install \
  --no-cache-dir --no-deps --require-hashes --only-binary=:all: \
  --no-compile -r "$REQS"
"$PY" -I -B -m pip check

echo "==> trimming"
STD="$VENDOR/python/lib/python3.12"
# The stdlib's own test suite, Tk/IDLE (Cookie has no Tk UI), and their Tcl/Tk libraries.
rm -rf "$STD/test" "$STD/idlelib" "$STD/tkinter" "$STD/turtledemo" "$STD/turtle.py" \
       "$STD/lib-dynload/_tkinter"*.so
rm -rf "$VENDOR/python/lib/"tcl* "$VENDOR/python/lib/"tk* "$VENDOR/python/lib/"itcl* \
       "$VENDOR/python/lib/"thread* "$VENDOR/python/lib/libtcl"* "$VENDOR/python/lib/libtk"*
find "$VENDOR/python" -type d \( -name tests -o -name test -o -name __pycache__ \) -prune -exec rm -rf {} +
# pip is only needed at build time; the shipped runtime installs nothing.
"$PY" -I -B -c "import scrapling.parser, pptx, lxml, PIL, xlsxwriter; print('    imports ok')"
rm -rf "$STD/site-packages/pip" "$STD/site-packages/pip-"*.dist-info "$STD/ensurepip"
rm -f "$VENDOR/python/bin/pip"* "$VENDOR/python/bin/idle"* "$VENDOR/python/bin/2to3"*
# Headers, man pages and pkg-config files are for building against Python, not running it.
rm -rf "$VENDOR/python/include" "$VENDOR/python/share" "$VENDOR/python/lib/pkgconfig"

echo "==> done: $(du -sh "$VENDOR/python" | cut -f1) in $VENDOR/python"
