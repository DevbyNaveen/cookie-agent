#!/bin/sh
# Builds every native piece of Cookie for Apple silicon AND Intel, and lipos each pair into one
# universal binary in build/universal/bin. `./build.sh --universal` runs it, then bundles those.
#
#   Cookie            SwiftPM, once per --triple (arm64, x86_64)
#   cookie            this repo's core (--features bedrock), cookie-tools, cookie-recorder:
#                     cargo --target aarch64/x86_64-apple-darwin, sharing one CARGO_TARGET_DIR
#   cookie-sense      SwiftPM against a macOS 26+ SDK, once per --triple (it only runs on macOS 26+)
#   enkeon-complete   llama.cpp: arm64 with Metal, x86_64 CPU-only (voice/scripts/llama.sh says why)
#   Python            scripts/bundle-python.sh --universal → vendor/python-universal
#
# The disk is the limit, so each arch's intermediates are deleted once its binaries are copied out,
# and the build stops before a step that might not fit (COOKIE_MIN_FREE_GB, default 3).
# build/universal/disk.log records free space at every step; the peak is printed at the end.
set -eu
cd "$(dirname "$0")/.."
MAC="$(pwd)"
U="$MAC/build/universal"
BIN="$U/bin"
CARGO_TARGET_DIR="$U/cargo"
export CARGO_TARGET_DIR
MIN_FREE_GB="${COOKIE_MIN_FREE_GB:-3}"
mkdir -p "$BIN" "$U/arm64" "$U/x86_64"
DISK_LOG="$U/disk.log"

free_kb() { df -k "$MAC" | awk 'NR == 2 { print $4 }'; }
START_FREE=$(free_kb)
echo "start $START_FREE" > "$DISK_LOG"
# disk <step>: logs free space, stops when it's under the floor before a heavy step.
disk() {
  now=$(free_kb)
  echo "$1 $now" >> "$DISK_LOG"
  if [ "$now" -lt $((MIN_FREE_GB * 1024 * 1024)) ]; then
    echo "error: only $((now / 1024)) MB free before '$1' (floor: ${MIN_FREE_GB} GB). Stopping before the disk fills." >&2
    echo "       Free some space (or set COOKIE_MIN_FREE_GB) and run again; finished arches are kept in $U." >&2
    exit 1
  fi
}

# lipo_pair <name>: build/universal/{arm64,x86_64}/<name> → build/universal/bin/<name>, both slices checked.
lipo_pair() {
  lipo -create "$U/arm64/$1" "$U/x86_64/$1" -output "$BIN/$1"
  archs=$(lipo -archs "$BIN/$1")
  [ "$archs" = "x86_64 arm64" ] || [ "$archs" = "arm64 x86_64" ] || { echo "error: $1 is '$archs'" >&2; exit 1; }
  rm -f "$U/arm64/$1" "$U/x86_64/$1"
  echo "    $1: $archs"
}

for triple in aarch64-apple-darwin x86_64-apple-darwin; do
  rustup target list --installed | grep -qx "$triple" || { echo "error: rustup target add $triple" >&2; exit 1; }
done
arch -x86_64 /usr/bin/true 2>/dev/null || echo "note: no Rosetta here, so the Intel halves are built but never run on this Mac"

# Rust: one arch at a time, so only one arch's target folder ever exists.
for triple in aarch64-apple-darwin x86_64-apple-darwin; do
  case "$triple" in aarch64*) arch=arm64 ;; *) arch=x86_64 ;; esac
  disk "rust-$arch"
  echo "==> Rust helpers for $triple"
  (cd .. && cargo build --release --bin cookie --features bedrock --target "$triple")
  (cd cookie-tools && cargo build --release --target "$triple")
  (cd cookie-recorder && cargo build --release --target "$triple")
  # The core goes in as cookie-core: macOS names ignore case, so a file "cookie" here is the same file
  # as the SwiftPM app "Cookie" below, and the app would overwrite the core (exit 11 on every message).
  cp "$CARGO_TARGET_DIR/$triple/release/cookie" "$U/$arch/cookie-core"
  for name in cookie-tools cookie-recorder; do cp "$CARGO_TARGET_DIR/$triple/release/$name" "$U/$arch/$name"; done
  disk "rust-$arch-built"
  # The arch's objects, and the host build scripts that made them, go before the next arch.
  rm -rf "${CARGO_TARGET_DIR:?}/$triple" "${CARGO_TARGET_DIR:?}/release"
done
for name in cookie-core cookie-tools cookie-recorder; do lipo_pair "$name"; done

# swift_pair <package-dir> <product> <sdk>: SwiftPM once per triple, then the per-arch build folders go.
swift_pair() {
  for arch in arm64 x86_64; do
    disk "swift-$2-$arch"
    echo "==> $2 for $arch"
    if [ -n "$3" ]; then
      (cd "$1" && SDKROOT="$3" swift build -c release --build-system native --triple "$arch-apple-macosx15.0")
      path=$(cd "$1" && SDKROOT="$3" swift build -c release --build-system native --triple "$arch-apple-macosx15.0" --show-bin-path)
    else
      (cd "$1" && swift build -c release --build-system native --triple "$arch-apple-macosx15.0")
      path=$(cd "$1" && swift build -c release --build-system native --triple "$arch-apple-macosx15.0" --show-bin-path)
    fi
    cp "$path/$2" "$U/$arch/$2"
    disk "swift-$2-$arch-built"
    rm -rf "$1/.build/$arch-apple-macosx"
  done
  lipo_pair "$2"
}

swift_pair . Cookie "$(scripts/sdk.sh app)"
if [ -z "${COOKIE_SENSE_BIN:-}" ]; then
  if SENSE_SDK=$(scripts/sdk.sh sense); then
    swift_pair cookie-sense cookie-sense "$SENSE_SDK"
  else
    echo "note: no macOS 26+ SDK here, so cookie-sense is left out"
  fi
fi

if [ -z "${ENKEON_COMPLETE_BIN:-}" ]; then
  for arch in arm64 x86_64; do
    disk "llama-$arch"
    voice/scripts/llama.sh "$arch"
    cp "voice/.build/llama-$arch/bin/llama-server" "$U/$arch/enkeon-complete"
    rm -rf "voice/.build/llama-$arch"
  done
  lipo_pair enkeon-complete
fi

disk python
scripts/bundle-python.sh --universal

END_FREE=$(free_kb)
LOW=$(awk '{ print $2 }' "$DISK_LOG" | sort -n | head -1)
echo "end $END_FREE" >> "$DISK_LOG"
echo "==> universal helpers in $BIN"
echo "    peak disk use: $(( (START_FREE - LOW) / 1024 )) MB above the start; $(( (START_FREE - END_FREE) / 1024 )) MB kept (log: $DISK_LOG)"
