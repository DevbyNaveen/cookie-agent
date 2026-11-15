#!/bin/bash
# Build Cookie's private Python runtime:
# a pinned, hash-checked python-build-standalone CPython plus the
# hash-pinned wheels in cookie-py/requirements.txt. Re-runnable: it starts
# from an empty output folder each time.
#
#   scripts/bundle-python.sh               → vendor/python            (Apple silicon)
#   scripts/bundle-python.sh --universal   → vendor/python-universal  (Apple silicon + Intel)
#
# --universal installs the same pins into an arm64 and an x86_64 CPython (the x86_64 one runs
# under Rosetta here, so its imports are really tried), trims both the same way, then lipos
# every Mach-O pair into one tree. A file that exists for one arch only fails the build.
set -euo pipefail

PBS_TAG="20261009"
PBS_VERSION="3.12.15"
# From the release's SHA256SUMS (and GitHub's asset digest), checked 2026-10-13 (arm64) and 2026-11-15 (x86_64).
PBS_SHA256_aarch64="83dcb04777c798bd95f3687acf9ae84b09860272ee6bdfb05be8bcf9447f75b8"
PBS_SHA256_x86_64="4c84ef5abe4bc145646175fce9b881936d60126b9a3f9a24c6308e2d035ca5c6"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
REQS="$ROOT/cookie-py/requirements.txt"
UNIVERSAL=0
case "${1:-}" in
  "") ;;
  --universal) UNIVERSAL=1 ;;
  *) echo "usage: $0 [--universal]" >&2; exit 64 ;;
esac

[ "$(uname -m)" = "arm64" ] || { echo "this build runs on Apple silicon" >&2; exit 1; }
if [ "$UNIVERSAL" = 1 ] && ! arch -x86_64 /usr/bin/true 2>/dev/null; then
  echo "--universal installs and tries the Intel half under Rosetta: softwareupdate --install-rosetta --agree-to-license" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# fetch_python <aarch64|x86_64> <dest>: the pinned CPython for that arch, unpacked into <dest>.
fetch_python() {
  local arch="$1" dest="$2" sha file url
  sha="PBS_SHA256_$arch"; sha="${!sha}"
  file="cpython-${PBS_VERSION}+${PBS_TAG}-${arch}-apple-darwin-install_only.tar.gz"
  url="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${file//+/%2B}"
  echo "==> downloading $file"
  curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 -o "$WORK/$file" "$url"
  echo "$sha  $WORK/$file" | shasum -a 256 --check --status \
    || { echo "SHA-256 mismatch for $file — refusing to unpack" >&2; exit 1; }
  echo "    sha256 ok"
  mkdir -p "$dest"
  tar -xzf "$WORK/$file" -C "$dest" --strip-components 1   # the archive's top folder is python/
  rm -f "$WORK/$file"
}

# install_and_trim <python-dir> [arch -x86_64]: the pinned wheels, checked, then everything Cookie never runs removed.
install_and_trim() {
  local dir="$1"; shift
  local run=("$@" "$dir/bin/python3")
  echo "==> installing hash-pinned wheels ($(basename "$dir"))"
  PIP_DISABLE_PIP_VERSION_CHECK=1 "${run[@]}" -I -B -m pip install \
    --no-cache-dir --no-deps --require-hashes --only-binary=:all: \
    --no-compile -r "$REQS"
  "${run[@]}" -I -B -m pip check

  echo "==> trimming"
  local std="$dir/lib/python3.12"
  # The stdlib's own test suite, Tk/IDLE (Cookie has no Tk UI), and their Tcl/Tk libraries.
  rm -rf "$std/test" "$std/idlelib" "$std/tkinter" "$std/turtledemo" "$std/turtle.py" \
         "$std/lib-dynload/_tkinter"*.so
  rm -rf "$dir/lib/"tcl* "$dir/lib/"tk* "$dir/lib/"itcl* \
         "$dir/lib/"thread* "$dir/lib/libtcl"* "$dir/lib/libtk"*
  find "$dir" -type d \( -name tests -o -name test -o -name __pycache__ \) -prune -exec rm -rf {} +
  # pip is only needed at build time; the shipped runtime installs nothing.
  "${run[@]}" -I -B -c "import scrapling.parser, pptx, lxml, PIL, xlsxwriter, orjson; print('    imports ok')"
  rm -rf "$std/site-packages/pip" "$std/site-packages/pip-"*.dist-info "$std/ensurepip"
  rm -f "$dir/bin/pip"* "$dir/bin/idle"* "$dir/bin/2to3"*
  # Headers, man pages and pkg-config files are for building against Python, not running it.
  rm -rf "$dir/include" "$dir/share" "$dir/lib/pkgconfig"
}

# True when lipo says the file holds both an x86_64 and an arm64 slice.
is_universal() {
  local archs=" $(lipo -archs "$1" 2>/dev/null) "
  [[ "$archs" == *" x86_64 "* && "$archs" == *" arm64 "* ]]
}

# Every regular Mach-O file under a tree, relative to it.
macho_files() {
  (cd "$1" && find . -type f -print0 | xargs -0 file --no-pad --separator '|' | awk -F'|' '$2 ~ /Mach-O/ { print $1 }' | sort)
}

if [ "$UNIVERSAL" = 0 ]; then
  rm -rf "$VENDOR/python"
  fetch_python aarch64 "$VENDOR/python"
  install_and_trim "$VENDOR/python"
  echo "==> done: $(du -sh "$VENDOR/python" | cut -f1) in $VENDOR/python"
  exit 0
fi

OUT="$VENDOR/python-universal"
ARM="$WORK/arm64" X86="$WORK/x86_64"
fetch_python aarch64 "$ARM"
install_and_trim "$ARM"
fetch_python x86_64 "$X86"
install_and_trim "$X86" arch -x86_64

echo "==> merging into one universal tree"
macho_files "$ARM" > "$WORK/arm.list"
macho_files "$X86" > "$WORK/x86.list"
if ! diff -u "$WORK/arm.list" "$WORK/x86.list" > "$WORK/macho.diff"; then
  echo "the two Pythons don't have the same native files; refusing a tree that would break on one Mac:" >&2
  cat "$WORK/macho.diff" >&2
  exit 1
fi
rm -rf "$OUT"
mkdir -p "$VENDOR"
cp -R "$ARM" "$OUT"
merged=0 already=0
while IFS= read -r file; do
  if is_universal "$OUT/$file"; then already=$((already + 1)); continue; fi
  # The Intel side may itself be fat; only its x86_64 slice joins.
  lipo "$X86/$file" -thin x86_64 -output "$WORK/slice" 2>/dev/null || cp "$X86/$file" "$WORK/slice"
  lipo -create "$OUT/$file" "$WORK/slice" -output "$WORK/fat"
  chmod u+w "$OUT/$file"
  cat "$WORK/fat" > "$OUT/$file"   # keeps the file's mode
  merged=$((merged + 1))
done < "$WORK/arm.list"
rm -f "$WORK/slice" "$WORK/fat"
bad=0
while IFS= read -r file; do
  is_universal "$OUT/$file" || { echo "not universal: $file ($(lipo -archs "$OUT/$file"))" >&2; bad=1; }
done < "$WORK/arm.list"
[ "$bad" = 0 ] || exit 1
"$OUT/bin/python3" -I -B -c "import scrapling.parser, pptx, lxml, PIL, xlsxwriter, orjson; print('    arm64 imports ok')"
arch -x86_64 "$OUT/bin/python3" -I -B -c "import scrapling.parser, pptx, lxml, PIL, xlsxwriter, orjson; print('    x86_64 imports ok')"
echo "==> done: $merged merged, $already already universal; $(du -sh "$OUT" | cut -f1) in $OUT"
