#!/bin/sh
# Installs the sentence-completion model: Google's Gemma 3 1B base (Gemma Terms of Use), as published
# by ggml-org, quantized here to 4-bit (Q4_K_M, ~800 MB) — the build the 2026-10-30 benchmark passed.
#   scripts/model.sh   →   ~/Library/Application Support/Enkeon/models/gemma-3-1b-pt-Q4_K_M.gguf
set -e
cd "$(dirname "$0")/.."
DIR="$HOME/Library/Application Support/Enkeon/models"
OUT="$DIR/gemma-3-1b-pt-Q4_K_M.gguf"
[ -f "$OUT" ] && { echo "already installed: $OUT"; exit 0; }
[ -x .build/llama/bin/llama-quantize ] || scripts/llama.sh
mkdir -p "$DIR"
TMP="$DIR/.gemma-3-1b-pt-bf16.gguf"
curl -fL --progress-bar -o "$TMP" "https://huggingface.co/ggml-org/gemma-3-1b-pt-GGUF/resolve/main/ggml-model-bf16.gguf"
.build/llama/bin/llama-quantize "$TMP" "$OUT.part" Q4_K_M >/dev/null 2>&1
mv "$OUT.part" "$OUT" && rm -f "$TMP"
echo "installed $OUT"
