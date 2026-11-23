#!/bin/sh
# Make this machine your Cookie team's always-on home: an old Mac, a mini PC,
# or a small server. Builds `cookie-team`, installs it for this user, and
# starts it at login (launchd on macOS, systemd --user on Linux).
#
#   ./install-runner.sh [--bind 0.0.0.0] [--port 4519] [--public-url https://cookie.example.com]
#
# Model keys: export ANTHROPIC_API_KEY (etc.) before running, or paste them in
# the app's Settings → Models once it's open; they're kept in the Keychain on a
# Mac and in a file only you can read elsewhere.
set -eu
BIND=127.0.0.1 PORT=4519 PUBLIC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bind) BIND="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --public-url) PUBLIC="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
command -v cargo >/dev/null || { echo "Needs Rust: https://rustup.rs" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
cargo install --locked --path "$HERE/team" --root "$HOME/.local"
BIN="$HOME/.local/bin/cookie-team"
DIR="$HOME/.cookie-team"
mkdir -p "$DIR"
ARGS="serve --dir $DIR --bind $BIND --port $PORT"
[ -n "$PUBLIC" ] && ARGS="$ARGS --public-url $PUBLIC"

case "$(uname -s)" in
  Darwin)
    PLIST="$HOME/Library/LaunchAgents/com.enkeon.cookie-team.plist"
    mkdir -p "$(dirname "$PLIST")"
    {
      echo '<?xml version="1.0" encoding="UTF-8"?>'
      echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
      echo '<plist version="1.0"><dict>'
      echo '<key>Label</key><string>com.enkeon.cookie-team</string>'
      echo '<key>ProgramArguments</key><array>'
      echo "<string>$BIN</string>"
      for a in $ARGS; do echo "<string>$a</string>"; done
      echo '</array>'
      echo '<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>'
      echo "<key>StandardOutPath</key><string>$DIR/runner.log</string>"
      echo "<key>StandardErrorPath</key><string>$DIR/runner.log</string>"
      echo '</dict></plist>'
    } > "$PLIST"
    launchctl bootout "gui/$(id -u)/com.enkeon.cookie-team" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    ;;
  Linux)
    UNIT="$HOME/.config/systemd/user/cookie-team.service"
    mkdir -p "$(dirname "$UNIT")"
    cat > "$UNIT" <<UNIT
[Unit]
Description=Cookie team runner
After=network-online.target

[Service]
ExecStart=$BIN $ARGS
Restart=on-failure

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now cookie-team.service
    command -v loginctl >/dev/null && loginctl enable-linger "$USER" 2>/dev/null || true
    ;;
  *) echo "On this system, run: $BIN $ARGS" ;;
esac

sleep 2
echo
echo "Cookie team is running. Open it from any device:"
echo "  ${PUBLIC:-http://$BIND:$PORT}/#token=$("$BIN" token --dir "$DIR")"
[ "$BIND" != "127.0.0.1" ] && [ -z "$PUBLIC" ] && echo "Put HTTPS in front (Caddy, a tunnel) before using it over the internet."
