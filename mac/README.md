<p align="center">
  <img src="../web/public/cookie/cookie-512.png" width="96" alt="Cookie">
</p>

<h2 align="center">Cookie for Mac</h2>

<p align="center">Hold a key and talk. Cookie answers out loud and points to it on your screen.</p>

---

Cookie lives in your menu bar and in the notch. Ask out loud or type; it can
look at your screen when you ask it to, point at the button or line you need,
and work on your Mac with the same rules as everywhere else: what it reads is
never an order, and anything that sends, deletes or pays waits for your yes.

Its voice is timed word by word (ElevenLabs, or the Mac's own), so the
pointer, hand-inked marks, explainer cards and small 3D models each arrive
on the word that names them. Say "every Tuesday at 5, clean up my inbox" and,
after your yes, it's a routine on the Board. The Board is the same list as
Cookie's page: this Mac's own when you're signed out, your team's in Enkeon
when you're signed in. "Hide from screen sharing" in Settings asks macOS to
leave Cookie's windows out of other apps' shares, wherever they honour it.

It thinks through this repo's core (`cookie serve`), bundled inside the app,
with your own model key or your Enkeon sign-in.

## Build

Needs macOS 15 or later, Rust 1.91+ (https://rustup.rs) and either Xcode or
just the Command Line Tools for Xcode (`xcode-select --install`). From `mac/`:

```sh
./build.sh          # → build/Cookie.app
open build/Cookie.app
```

That one command builds Cookie's core (`cookie serve`, with every model
provider Settings offers), its helpers (files, meeting recording, screen
reading and on-device speech) and the app, with the SDKs this Mac has
(`scripts/sdk.sh` picks them):

- **Cookie itself** builds with Xcode, or with the Command Line Tools and their
  macOS 15 SDK. From SDK 26 on, SwiftUI needs a compiler plugin that only Xcode
  has, so with the tools alone a Mac that has only SDK 26+ is told to install
  Xcode or the Command Line Tools for Xcode 16.
- **cookie-sense** needs a macOS 26 or later SDK; without one it is left out
  and Cookie reads the screen in its own process.
- **Research and decks** need Cookie's own Python: run `scripts/bundle-python.sh`
  once before `./build.sh`; without it they are left out.

An app you build yourself opens without Gatekeeper's warning. It is signed ad
hoc, so macOS asks for its permissions again after each rebuild; set
`COOKIE_SIGN_ID` to any code-signing identity you have
(`security find-identity -v -p codesigning`) to keep them.
`COOKIE_HARNESS_BIN`, `COOKIE_TOOLS_BIN`, `COOKIE_RECORDER_BIN` and
`COOKIE_SENSE_BIN` use binaries you built elsewhere.

## Distribution

Anyone on macOS 15 (Sequoia) or later, on Apple silicon or Intel, installs
Cookie with one line in Terminal:

```sh
curl -fsSL https://github.com/DevbyNaveen/cookie-agent/releases/latest/download/install.sh | sh
```

It checks the macOS version, downloads the latest release over HTTPS, checks
its SHA-256 and that the app is validly signed by Cookie's team, quits a
running Cookie, installs into `/Applications` (`~/Applications` when that
isn't writable; never sudo) and opens it. Running it again reinstalls in place.

From then on Cookie updates itself: 30 s after launch and every 6 hours it
reads the release's `latest.json`, and takes a new version only when its
Ed25519 signature matches the key built into the app, the download matches the
signed SHA-256 and the new app is signed by the same team. The notch then says
"Cookie 0.2.0 is ready · Restart to update" (Settings → About has the version,
the last check and the button). Restart waits until no dictation, task,
conversation or recording is running, swaps the app in place and keeps the old
one until the new one has run for 20 s; if it doesn't come up, the old one is
put back and that build isn't offered again.

Why no Developer ID or Sparkle: files downloaded by curl or URLSession get no
quarantine flag, so Gatekeeper never stops them, and signing every build with
the same Apple Development identity keeps macOS's permission grants across
updates.

**Cutting a release** (from `mac/`, on a clean, pushed commit):

```sh
scripts/release.sh 0.2.0 --notes "What changed"            # dry run: builds universal, packages, prints the upload plan
scripts/release.sh 0.2.0 --notes "What changed" --publish  # then creates GitHub release v0.2.0 with the four files
```

`./build.sh --universal` (which the release runs) builds every binary for
arm64 and x86_64 and lipos them, so the app runs natively on both;
`COOKIE_VERSION` and `COOKIE_BUILD` set its version (the build number defaults
to the commit count). It needs `rustup target add x86_64-apple-darwin` and
Rosetta (the Intel Python is installed and import-checked under it). The
release refuses a dirty tree, an existing tag, a version not newer than the
latest, a commit not on GitHub, and an app not signed by team `3Z97R7N3SR`.
It writes `build/release/v<version>/`: `Cookie.zip`, `Cookie.zip.sha256`,
`latest.json` and `install.sh`.

On Intel Macs, Pen (enkeon-complete) runs on the CPU, without Metal, and
cookie-sense needs macOS 26, so on Sequoia Cookie reads the screen and
transcribes in its own process, as it does on any Mac without the helper.

**Key custody.** Updates are signed with the Ed25519 key in
`~/.cookie-release/update-ed25519.key` (0600, never in git); its public half is
`CookieUpdater.publicKeyBase64`. Back the file up somewhere safe: if it is
lost, installed copies refuse every later update and everyone has to run the
install line again. A new key (`swift scripts/update-key.swift keygen …`) needs
a new public key in the app, and only copies installed after that trust it.

**The certificate.** Releases are signed with the "Apple Development"
certificate of team `3Z97R7N3SR`, which expires each year (this one on
17 February 2027); renew it in Xcode or developer.apple.com before then. Every
build is time-stamped, so installed copies keep working after it expires, but
the renewed certificate may change the signing requirement macOS remembers, so
after the first update signed with it macOS may ask for each permission once
more. The team stays the same, so updates keep installing.

## Checks

```sh
python3 scripts/check_cookie_interactions.py
```

Runs the native checks (interactions, setup, voice, the board, permissions).
They draw real windows, so run them in a signed-in macOS session.

## Licence

MIT — see `LICENSE`.
