#!/bin/sh
# Starts Cookie for the desktop from source.
#
#   ./run.sh        dev mode: changes in ui/ show up live, Rust changes rebuild
#   ./run.sh app    the last built app, as it is
#
# Model keys come from your environment, or from Settings → Models once it is
# open. To start with a key from a .env file, point COOKIE_KEY_FILE at it, or
# put one at desktop/.env.local (ignored by git). Only the ANTHROPIC_API_KEY
# line is read; nothing is copied.
KEY_FILE="${COOKIE_KEY_FILE:-$(dirname "$0")/.env.local}"
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -r "$KEY_FILE" ]; then
  ANTHROPIC_API_KEY=$(grep '^ANTHROPIC_API_KEY=' "$KEY_FILE" | head -1 | cut -d= -f2- | tr -d "\"' ")
  export ANTHROPIC_API_KEY
fi
cd "$(dirname "$0")/src-tauri" || exit 1
if [ "$1" = "app" ]; then exec ../target/debug/cookie-desktop; fi
exec cargo tauri dev
