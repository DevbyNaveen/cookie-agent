#!/bin/sh
# Install Cookie from the latest GitHub release of DevbyNaveen/cookie-agent:
#
#   curl -fsSL https://raw.githubusercontent.com/DevbyNaveen/cookie-agent/main/install.sh | sh
#
# It picks the archive for this computer (macOS or Linux, Apple silicon,
# Intel or ARM), checks it against the SHA-256 the release publishes beside
# it, and refuses to install anything that does not match. The binary and
# the page go in one folder; `cookie` on your PATH runs that binary, so
# `cookie page` finds the page beside it.
#
#   COOKIE_VERSION=v0.2.0     install that release instead of the latest
#   COOKIE_INSTALL_DIR=DIR    put the `cookie` command in DIR
#   COOKIE_DOWNLOAD_URL=URL   download from a mirror of the releases
#                             (URL/<version>/<archive>) instead of GitHub

set -eu

REPO="DevbyNaveen/cookie-agent"

say() { printf '%s\n' "$*"; }
fail() { printf 'cookie install: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl is needed to download Cookie"
command -v tar >/dev/null 2>&1 || fail "tar is needed to unpack Cookie"

case "$(uname -s)" in
  Darwin) os=apple-darwin ;;
  Linux) os=unknown-linux-gnu ;;
  *) fail "there is no Cookie build for $(uname -s) yet (macOS and Linux only)" ;;
esac
case "$(uname -m)" in
  arm64 | aarch64) arch=aarch64 ;;
  x86_64 | amd64) arch=x86_64 ;;
  *) fail "there is no Cookie build for $(uname -m) yet" ;;
esac
target="$arch-$os"

version="${COOKIE_VERSION:-}"
if [ -z "$version" ]; then
  # The answer and its HTTP status, so a failed lookup is never taken for
  # a project with no release (GitHub answers 404 only for that).
  latest=$(curl -sSL -w '\n%{http_code}' "https://api.github.com/repos/$REPO/releases/latest") ||
    fail "could not look up the latest release of $REPO (no answer from GitHub); try again, or set COOKIE_VERSION"
  status=$(printf '%s\n' "$latest" | tail -n 1)
  case "$status" in
    200) ;;
    404) fail "$REPO has no release yet" ;;
    *) fail "could not look up the latest release of $REPO (GitHub answered HTTP $status, often its rate limit); try again later, or set COOKIE_VERSION" ;;
  esac
  version=$(printf '%s\n' "$latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$version" ] || fail "could not read the latest release of $REPO from GitHub's answer; set COOKIE_VERSION"
fi

name="cookie-$version-$target"
url="${COOKIE_DOWNLOAD_URL:-https://github.com/$REPO/releases/download}/$version/$name.tar.gz"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

say "Downloading Cookie $version for $target"
curl -fsSL "$url" -o "$work/$name.tar.gz" || fail "could not download $url"
curl -fsSL "$url.sha256" -o "$work/$name.tar.gz.sha256" || fail "could not download the checksum for $name.tar.gz"

want=$(cut -d ' ' -f 1 <"$work/$name.tar.gz.sha256")
if command -v sha256sum >/dev/null 2>&1; then
  got=$(sha256sum "$work/$name.tar.gz" | cut -d ' ' -f 1)
elif command -v shasum >/dev/null 2>&1; then
  got=$(shasum -a 256 "$work/$name.tar.gz" | cut -d ' ' -f 1)
else
  fail "neither sha256sum nor shasum is here, so the download cannot be checked"
fi
if [ -z "$want" ] || [ "$want" != "$got" ]; then
  fail "the download does not match its published SHA-256; nothing was installed"
fi

tar -xzf "$work/$name.tar.gz" -C "$work"
[ -x "$work/$name/cookie" ] || fail "the archive has no cookie binary"

# Where the command goes: /usr/local/bin when it can be written, else
# ~/.local/bin. The binary and its page live in the share folder beside it.
if [ -n "${COOKIE_INSTALL_DIR:-}" ]; then
  bin="$COOKIE_INSTALL_DIR"
elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
  bin=/usr/local/bin
else
  bin="$HOME/.local/bin"
fi
case "$bin" in
  /usr/local/bin) home=/usr/local/share/cookie ;;
  *) home="${XDG_DATA_HOME:-$HOME/.local/share}/cookie" ;;
esac
mkdir -p "$bin" "$home"

# Replaced whole, so an older page never mixes with a newer binary.
rm -rf "$home/page.new"
if [ -d "$work/$name/page" ]; then
  cp -R "$work/$name/page" "$home/page.new"
fi
cp "$work/$name/cookie" "$home/cookie.new"
chmod 755 "$home/cookie.new"
mv -f "$home/cookie.new" "$home/cookie"
rm -rf "$home/page"
if [ -d "$home/page.new" ]; then
  mv "$home/page.new" "$home/page"
fi

# shellcheck disable=SC2016 # "$@" is for the wrapper to expand, not this script
printf '#!/bin/sh\nexec "%s/cookie" "$@"\n' "$home" >"$bin/cookie.new"
chmod 755 "$bin/cookie.new"
mv -f "$bin/cookie.new" "$bin/cookie"

say "Installed: $bin/cookie ($("$home/cookie" --version))"
case ":$PATH:" in
  *":$bin:"*) ;;
  *) say "" && say "$bin is not on your PATH. Add this line to your shell's profile:" && say "  export PATH=\"$bin:\$PATH\"" ;;
esac
say ""
say "Next:"
say "  export ANTHROPIC_API_KEY=sk-ant-...   # or name another model with --model"
say "  cd ~/your-project && cookie local     # ask about the folder and the web, in the terminal"
say "  cookie page ~/your-project            # the same Cookie on its page: http://localhost:4747/me/local/cookie"
