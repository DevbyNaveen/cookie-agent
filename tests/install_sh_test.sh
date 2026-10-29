#!/bin/sh
# install.sh's latest-release lookup, with a stand-in curl (no network):
# a failed lookup is said as one, and only GitHub's 404 means no release.
#
#   sh tests/install_sh_test.sh

set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

cat >"$work/curl" <<'STUB'
#!/bin/sh
case "$FAKE_GITHUB" in
  down) echo "curl: (6) Could not resolve host: api.github.com" >&2; exit 6 ;;
  limited) printf '{"message":"API rate limit exceeded"}\n403' ;;
  none) printf '{"message":"Not Found"}\n404' ;;
  empty) printf '{}\n200' ;;
esac
STUB
chmod 755 "$work/curl"

failed=0
expect() {
  case_name=$1 want=$2
  if out=$(FAKE_GITHUB=$case_name PATH="$work:$PATH" sh "$here/install.sh" 2>&1); then
    echo "FAIL $case_name: install.sh succeeded"; failed=1; return
  fi
  case "$out" in
    *"$want"*) echo "ok   $case_name" ;;
    *) echo "FAIL $case_name: wanted \"$want\", got: $out"; failed=1 ;;
  esac
}

expect down "could not look up the latest release of DevbyNaveen/cookie-agent (no answer from GitHub)"
expect limited "GitHub answered HTTP 403"
expect none "DevbyNaveen/cookie-agent has no release yet"
expect empty "could not read the latest release of DevbyNaveen/cookie-agent from GitHub's answer"

# Only a 404 says there is no release.
if FAKE_GITHUB=limited PATH="$work:$PATH" sh "$here/install.sh" 2>&1 | grep -q "no release yet"; then
  echo "FAIL limited: a rate limit was reported as no release"; failed=1
fi

exit "$failed"
