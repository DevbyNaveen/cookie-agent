#!/bin/sh
# Starts Cookie for the desktop with the Anthropic key from Kaivon's .env
# (Naveen's choice, 2026-11-23). Only that one line is read; nothing is copied.
# Point COOKIE_KEY_FILE at another .env to use a different key.
#
#   ./run.sh        dev mode: changes in ui/ show up live, Rust changes rebuild
#   ./run.sh app    the last built app, as it is
KEY_FILE="${COOKIE_KEY_FILE:-$HOME/Desktop/kaivon/.env}"
ANTHROPIC_API_KEY=$(grep '^ANTHROPIC_API_KEY=' "$KEY_FILE" | head -1 | cut -d= -f2- | tr -d "\"' ")
export ANTHROPIC_API_KEY
cd "$(dirname "$0")/src-tauri" || exit 1
if [ "$1" = "app" ]; then exec ../target/debug/cookie-desktop; fi
exec cargo tauri dev
