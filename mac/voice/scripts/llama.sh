#!/bin/sh
# Builds enkeon-complete: llama.cpp's server (MIT), self-contained, for sentence completion.
# Static (no Homebrew libraries), Metal kernels embedded and compiled at runtime, so it needs no Xcode.
#   scripts/llama.sh   →   .build/llama/bin/llama-server
set -e
cd "$(dirname "$0")/.."
TAG=b11669   # the version the completion benchmark passed on; bump it with a new benchmark
SRC=.build/llama-src
if [ ! -d "$SRC/.git" ] || [ "$(git -C "$SRC" describe --tags 2>/dev/null)" != "$TAG" ]; then
  rm -rf "$SRC"
  git clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$SRC"
fi
cmake -S "$SRC" -B .build/llama -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=ON >/dev/null
cmake --build .build/llama --target llama-server llama-quantize -j "$(sysctl -n hw.ncpu)" >/dev/null
echo "built .build/llama/bin/llama-server ($TAG)"
