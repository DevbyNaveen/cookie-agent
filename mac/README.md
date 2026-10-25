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

## Checks

```sh
python3 scripts/check_cookie_interactions.py
```

Runs the native checks (interactions, setup, voice, the board, permissions).
They draw real windows, so run them in a signed-in macOS session.

## Licence

MIT — see `LICENSE`.
