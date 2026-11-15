#!/bin/sh
# Cut a Cookie for Mac release. A dry run unless --publish is given: nothing leaves this Mac.
#
#   scripts/release.sh 0.2.0                      build + package into build/release/v0.2.0, print the upload plan
#   scripts/release.sh 0.2.0 --notes "…"          release notes (latest.json, the notch notice and the release page)
#   scripts/release.sh 0.2.0 --publish            the same, then GitHub release v0.2.0 on DevbyNaveen/cookie-agent
#   scripts/release.sh 0.2.0 --skip-build         package the build/Cookie.app already there (dry runs only)
#
# What it makes: Cookie.zip (ditto, universal, signed by the team), Cookie.zip.sha256, latest.json
# (version, build, url, sha256, Ed25519 signature, minimumSystemVersion, notes, publishedAt) and
# install.sh stamped with the signing team.
#
#   COOKIE_BUILD         CFBundleVersion (default: the number of commits on HEAD, so it only grows)
#   COOKIE_RELEASE_KEY   the Ed25519 private key (default ~/.cookie-release/update-ed25519.key, 0600, never in git)
#   COOKIE_TEAM_ID       the team every release is signed by (default 3Z97R7N3SR); installed apps refuse any other
#   COOKIE_SIGN_ID       a codesigning identity of that team (default: the keychain's first one)
#
# First release on a new Mac: `swift scripts/update-key.swift keygen ~/.cookie-release/update-ed25519.key`
# makes a key and prints its public half for CookieUpdater.publicKeyBase64. Losing the key means every
# installed Cookie refuses later updates and has to be reinstalled with the one-liner.
set -eu
cd "$(dirname "$0")/.."
MAC="$(pwd)"
REPO="DevbyNaveen/cookie-agent"

fail() { printf 'release: %s\n' "$*" >&2; exit 1; }

VERSION=""; PUBLISH=""; SKIP_BUILD=""; NOTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --publish) PUBLISH=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --notes) [ $# -ge 2 ] || fail "--notes needs text"; NOTES="$2"; shift ;;
    -*) fail "unknown option $1" ;;
    *) [ -z "$VERSION" ] || fail "one version, please"; VERSION="$1" ;;
  esac
  shift
done
[ -n "$VERSION" ] || fail "usage: scripts/release.sh <version> [--notes \"…\"] [--publish] [--skip-build]"
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "version must be like 0.2.0, not $VERSION"
if [ -n "$PUBLISH" ] && [ -n "$SKIP_BUILD" ]; then fail "--publish always builds; drop --skip-build"; fi
TAG="v$VERSION"
NOTES="${NOTES:-Cookie $VERSION}"
BUILD="${COOKIE_BUILD:-$(git rev-list --count HEAD)}"
TEAM_ID="${COOKIE_TEAM_ID:-3Z97R7N3SR}"
KEY="${COOKIE_RELEASE_KEY:-$HOME/.cookie-release/update-ed25519.key}"
OUT="$MAC/build/release/$TAG"
APP="$MAC/build/Cookie.app"
COMMIT="$(git rev-parse HEAD)"

# The key: present, owner-only, and the one the app trusts (a mismatch would strand every user).
[ -f "$KEY" ] || fail "no release key at $KEY (see the header: update-key.swift keygen)"
case "$(stat -f %Lp "$KEY")" in 600|400) ;; *) fail "$KEY must be chmod 600" ;; esac
EMBEDDED="$(sed -n 's/.*static let publicKeyBase64 = "\([^"]*\)".*/\1/p' Cookie/CookieUpdater.swift)"
DERIVED="$(swift scripts/update-key.swift public "$KEY")"
[ -n "$EMBEDDED" ] && [ "$EMBEDDED" = "$DERIVED" ] ||
  fail "the key at $KEY ($DERIVED) isn't the one Cookie trusts (CookieUpdater.publicKeyBase64 = $EMBEDDED)"

# Publishing: from a clean, pushed commit, to a tag that doesn't exist, newer than what's out.
if [ -n "$PUBLISH" ]; then
  command -v gh >/dev/null || fail "--publish needs the GitHub CLI (gh)"
  gh auth status >/dev/null 2>&1 || fail "gh isn't signed in (gh auth login)"
  [ -z "$(git status --porcelain)" ] || fail "the tree has uncommitted changes; a release is built from a commit"
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists here"
  [ -z "$(git ls-remote --tags origin "refs/tags/$TAG")" ] || fail "tag $TAG already exists on GitHub"
  gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && fail "release $TAG already exists"
  gh api "repos/$REPO/commits/$COMMIT" >/dev/null 2>&1 || fail "commit $COMMIT isn't on GitHub yet; push it first"
  LATEST="$(gh release view --repo "$REPO" --json tagName --jq .tagName 2>/dev/null || true)"
  if [ -n "$LATEST" ]; then
    newest="$(printf '%s\n%s\n' "${LATEST#v}" "$VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
    [ "$newest" = "$VERSION" ] && [ "${LATEST#v}" != "$VERSION" ] || fail "$VERSION isn't newer than the published $LATEST; installed apps would ignore it"
  fi
elif [ -n "$(git status --porcelain)" ]; then
  echo "note: uncommitted changes; fine for a dry run, --publish will refuse"
fi

# The codesigning identity of that team (its certificate's OU is the team).
identity_team() {
  security find-certificate -a -Z -p 2>/dev/null | awk -v hash="$1" '
    /SHA-1 hash:/ { take = ($3 == hash) } take && /BEGIN CERTIFICATE/ { printing = 1 }
    printing { print } /END CERTIFICATE/ { if (printing) exit }' |
    openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p'
}
if [ -z "${COOKIE_SIGN_ID:-}" ]; then
  for hash in $(security find-identity -v -p codesigning | awk '/Apple Development|Developer ID Application/ { print $2 }'); do
    if [ "$(identity_team "$hash")" = "$TEAM_ID" ]; then COOKIE_SIGN_ID="$hash"; break; fi
  done
fi
[ -n "${COOKIE_SIGN_ID:-}" ] || fail "no codesigning identity of team $TEAM_ID in the keychain"
export COOKIE_SIGN_ID

if [ -z "$SKIP_BUILD" ]; then
  COOKIE_VERSION="$VERSION" COOKIE_BUILD="$BUILD" ./build.sh --universal
fi

# The app: the version asked for, signed by the team, sealed, universal throughout.
plist() { plutil -extract "$1" raw -o - "$APP/Contents/Info.plist"; }
[ "$(plist CFBundleShortVersionString)" = "$VERSION" ] || fail "build/Cookie.app is $(plist CFBundleShortVersionString), not $VERSION"
[ "$(plist CFBundleVersion)" = "$BUILD" ] || fail "build/Cookie.app is build $(plist CFBundleVersion), not $BUILD"
MINIMUM="$(plist LSMinimumSystemVersion)"
codesign --verify --strict --deep \
  -R="identifier \"com.enkeon.cookie\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\"" "$APP" ||
  fail "build/Cookie.app isn't validly signed by team $TEAM_ID"
rm -rf "$OUT"
mkdir -p "$OUT"
find "$APP" -type f -print0 | xargs -0 file --no-pad --separator '|' | awk -F'|' '$2 ~ /Mach-O/ { print $1 }' |
  while IFS= read -r file; do printf '%s: %s\n' "${file#"$APP"/}" "$(lipo -archs "$file")"; done > "$OUT/archs.txt"
THIN="$(grep -v ': x86_64 arm64$' "$OUT/archs.txt" || true)"
[ -z "$THIN" ] || fail "not universal: $THIN"

# The archive, its hash and the signature over version + build + hash.
ditto -c -k --keepParent "$APP" "$OUT/Cookie.zip"
SHA256="$(shasum -a 256 "$OUT/Cookie.zip" | awk '{ print $1 }')"
printf '%s  Cookie.zip\n' "$SHA256" > "$OUT/Cookie.zip.sha256"
SIGNATURE="$(swift scripts/update-key.swift sign "$KEY" "$VERSION" "$BUILD" "$SHA256")"
swift scripts/update-key.swift verify "$EMBEDDED" "$VERSION" "$BUILD" "$SHA256" "$SIGNATURE" >/dev/null ||
  fail "the signature doesn't verify against the app's key"
URL="https://github.com/$REPO/releases/download/$TAG/Cookie.zip"
VERSION="$VERSION" BUILD="$BUILD" URL="$URL" SHA256="$SHA256" SIGNATURE="$SIGNATURE" MINIMUM="$MINIMUM" NOTES="$NOTES" \
PUBLISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" python3 -I -c '
import json, os
e = os.environ
print(json.dumps({"version": e["VERSION"], "build": int(e["BUILD"]), "url": e["URL"], "sha256": e["SHA256"],
                  "signature": e["SIGNATURE"], "minimumSystemVersion": e["MINIMUM"], "notes": e["NOTES"],
                  "publishedAt": e["PUBLISHED"]}, indent=2))' > "$OUT/latest.json"
sed "s/@COOKIE_TEAM_ID@/$TEAM_ID/" scripts/install.sh > "$OUT/install.sh"
sh -n "$OUT/install.sh"
grep -q "@COOKIE_TEAM_ID@" "$OUT/install.sh" && fail "install.sh wasn't stamped"

echo ""
echo "Cookie $VERSION (build $BUILD) from $COMMIT, signed by team $TEAM_ID"
echo "$(grep -c . "$OUT/archs.txt") Mach-O files, all x86_64 + arm64 ($OUT/archs.txt)"
echo ""
echo "Upload to GitHub release $TAG on $REPO (marked latest):"
for file in Cookie.zip latest.json install.sh Cookie.zip.sha256; do
  printf '  %-18s %8s  sha256 %s\n' "$file" "$(du -h "$OUT/$file" | cut -f1 | tr -d ' ')" "$(shasum -a 256 "$OUT/$file" | cut -c1-16)…"
done
echo ""
echo "  gh release create $TAG --repo $REPO --target $COMMIT --title \"Cookie $VERSION\" --notes \"…\" --latest \\"
echo "    $OUT/{Cookie.zip,latest.json,install.sh,Cookie.zip.sha256}"
echo ""
echo "Then: curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | sh"
echo "Note: creating tag $TAG also starts .github/workflows/release.yml (tags v*), which builds the cookie CLI"
echo "      archives and attaches them to this same release."

if [ -z "$PUBLISH" ]; then
  echo ""
  echo "Dry run: nothing was uploaded. Run again with --publish to publish."
  exit 0
fi

gh release create "$TAG" --repo "$REPO" --target "$COMMIT" --title "Cookie $VERSION" --notes "$NOTES" --latest \
  "$OUT/Cookie.zip" "$OUT/latest.json" "$OUT/install.sh" "$OUT/Cookie.zip.sha256"
# What users will actually get: the public latest.json must be this one.
curl -fsSL "https://github.com/$REPO/releases/latest/download/latest.json" | cmp -s - "$OUT/latest.json" ||
  fail "published, but releases/latest/download/latest.json isn't this release's yet; check the release page"
echo "Published $TAG."
