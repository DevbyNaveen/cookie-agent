#!/bin/sh
# Builds enkeon-complete: llama.cpp's server (MIT), self-contained, for sentence completion.
# Static (no Homebrew libraries), Metal kernels embedded and compiled at runtime, so it needs no Xcode.
#   scripts/llama.sh          →   .build/llama/bin/llama-server            (this Mac's arch)
#   scripts/llama.sh arm64    →   .build/llama-arm64/bin/llama-server      (for a universal build)
#   scripts/llama.sh x86_64   →   .build/llama-x86_64/bin/llama-server     (for a universal build)
set -e
cd "$(dirname "$0")/.."
TAG=b11669   # the version the completion benchmark passed on; bump it with a new benchmark
SRC=.build/llama-src
if [ ! -d "$SRC/.git" ] || [ "$(git -C "$SRC" describe --tags 2>/dev/null)" != "$TAG" ]; then
  rm -rf "$SRC"
  git clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$SRC"
fi
COMMON="-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=ON"
case "${1:-}" in
  "")
    cmake -S "$SRC" -B .build/llama $COMMON -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON >/dev/null
    cmake --build .build/llama --target llama-server llama-quantize -j "$(sysctl -n hw.ncpu)" >/dev/null
    echo "built .build/llama/bin/llama-server ($TAG)" ;;
  arm64)
    cmake -S "$SRC" -B .build/llama-arm64 $COMMON -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON >/dev/null
    cmake --build .build/llama-arm64 --target llama-server -j "$(sysctl -n hw.ncpu)" >/dev/null
    echo "built .build/llama-arm64/bin/llama-server ($TAG)" ;;
  x86_64)
    # Intel Macs: CPU only. Metal on Intel GPUs lacks the simdgroup features llama.cpp's kernels
    # assume, so the slice is CPU (Accelerate + AVX2). CMAKE_APPLE_SILICON_PROCESSOR makes CMake
    # treat this as an x86_64 host, so ggml picks its x86 sources, not its ARM ones. Every Intel
    # Mac that runs macOS 15 (2017 iMac Pro and 2018 on) has AVX2, FMA, F16C and BMI2.
    cmake -S "$SRC" -B .build/llama-x86_64 $COMMON -DCMAKE_OSX_ARCHITECTURES=x86_64 \
      -DCMAKE_APPLE_SILICON_PROCESSOR=x86_64 -DGGML_METAL=OFF \
      -DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON \
      -DGGML_AVX512=OFF >/dev/null
    cmake --build .build/llama-x86_64 --target llama-server -j "$(sysctl -n hw.ncpu)" >/dev/null
    echo "built .build/llama-x86_64/bin/llama-server ($TAG)" ;;
  *) echo "usage: $0 [arm64|x86_64]" >&2; exit 64 ;;
esac
