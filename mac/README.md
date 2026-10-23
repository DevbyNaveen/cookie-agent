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

It thinks through this repo's core (`cookie serve`), bundled inside the app,
with your own model key or your Enkeon sign-in.

## Build

Needs macOS 15 or later, Rust 1.91+ and the Command Line Tools for Xcode
(no full Xcode). From `mac/`:

```sh
(cd cookie-tools && cargo build --release)     # files: spreadsheets, documents, pages, CSV
(cd cookie-recorder && cargo build --release)  # meeting recording
scripts/bundle-python.sh                       # research and decks: Cookie's own Python
./build.sh                                     # → build/Cookie.app
```

`build.sh` builds Cookie's core itself (`cargo build --release --bin cookie
--features bedrock`, so every model provider in Settings can answer) and
bundles each helper it finds; a missing helper is left out with a note, and
the feature it serves is off. `COOKIE_HARNESS_BIN`, `COOKIE_TOOLS_BIN` and
`COOKIE_RECORDER_BIN` point it at binaries you built elsewhere.

Set `COOKIE_SIGN_ID` to your Developer ID to keep macOS's permission grants
across rebuilds; without it the app is signed ad hoc.

## Checks

```sh
python3 scripts/check_cookie_interactions.py
```

Runs the native checks (interactions, setup, voice, the board, permissions).
They draw real windows, so run them in a signed-in macOS session.

## Licence

MIT — see `LICENSE`.
