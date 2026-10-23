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

Needs macOS 14.2+ and the Command Line Tools for Xcode (no full Xcode).

```sh
cargo build --release --bin cookie   # from the repo root: Cookie's core
cd mac && ./build.sh                  # → mac/build/Cookie.app
```

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
