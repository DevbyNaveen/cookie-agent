# Enkeon

Dictation for macOS that knows your work. Hold a key, speak, and your words land in the app you
are typing in, transcribed on your Mac. With an Enkeon account, names and terms from your Enkeon
memory can improve spelling, and what you say can be saved to it.

Early development. Not ready for use yet.

## Speak and edit

- Hold **Fn** or **Control + Command**, speak, then release to dictate.
- Hold **Control, then Fn** to edit. Without an Apple Fn key, use
  **Option + Control + Command**, holding Option first. The bar shows **Editing selection** or **Editing message**.
  With nothing selected, the current editable field is the message. Say any editing
  instruction, such as “fix the grammar” or “make it shorter”. Ordinary dictation
  always types your words, even if you say “fix it”.
- **Shift** saves a dictation to memory. Combining Shift with editing is refused so an
  edit cannot accidentally become a memory save.
- **Escape** cancels. “Scratch that” in normal dictation undoes the last verified write.
- **Control + Command + C** copies the last result; **Control + Command + V** pastes
  it into the field you focus. Recovery is session-only and works with history off.

The default explicit editor is GPT-6.1 Terra through the OpenAI Responses API.
Connect a personal API key in Settings → Speech; it is stored in Keychain.
Only the edit source and instruction are sent, with `store: false`. No automatic
fallback is enabled. Apple Intelligence is an explicit local alternative in the
same settings. No cloud credential is bundled; live cloud quality and latency have
not been validated without one. A subscription distribution needs an authenticated
Enkeon backend, not a shared provider key in the app. Edit input is limited to
6,000 UTF-16 characters; select a shorter passage for longer documents.

Memory mode offers matching remembered sentences verbatim, labelled “tab · memory”.
It filters weak/outdated recall hits and suppresses competing continuations.
It requires matching sentence-prefix wording; it does not paraphrase retrieved facts.
When memory mode is active, unsupported generative completions are suppressed.
With memory mode off, the existing local Gemma 3 1B model offers ordinary completions;
learned phrases and spelling suggestions remain available. These are suggestions,
not guaranteed factual assertions.

Replacement requires the original field, text and cursor to remain unchanged.
For terminals, only an Accessibility field exposing writable text and selection
can be replaced directly. Scrollback is never treated as a command line. Where
replacement cannot be verified, the bar keeps the revision with **Copy** and
**Dismiss**; it does not append it automatically. Apps that expose neither text nor
a readable selection cannot be edited. Enkeon's own practice field currently supports
dictation, not voice editing. Clipboard-based selection fallback is copy-only.

## Layout

| Path | What |
|---|---|
| `Sources/EnkeonVoiceKit` | The dictation core: push-to-talk chord, microphone, speech providers, verified text insertion, permissions. Shared with [Cookie](https://github.com/DevbyNaveen/cookie-agent). |
| `Sources/Enkeon` | The app. |
| `Sources/EnkeonVoiceKitChecks` | The kit's checks. |
| `Helpers/enkeon-sense` | Apple speech/cleanup and an optional Parakeet Ultra candidate, isolated from the app. |

## Build

Command Line Tools are enough; no Xcode needed. The helper now requires Swift 6.2+.

```sh
SDKROOT="$(scripts/sdk.sh app)" swift build --build-system native
SDKROOT="$(scripts/sdk.sh app)" swift run --build-system native EnkeonVoiceKitChecks

cd Helpers/enkeon-sense && SDKROOT="$(../../scripts/sdk.sh sense)" swift build -c release --build-system native
cd ../.. && scripts/check-sense.py   # a spoken sentence must come back as text
```

The first run of the speech helper asks macOS to install the speech model for your language;
`check-sense.py` exits 2 until it is installed.

Apple remains the speech default. The tested Parakeet candidate has not met the
saved accuracy/latency gates. Developers can explicitly set `VoiceTranscriptionProvider`
to `parakeet` in `App/Info.plist` and rebuild to evaluate it. First preparation downloads
roughly 630 MB and may take minutes compiling Core ML models. It does not fall back.

Reproducible model checks and research: `docs/MODEL-RESEARCH-2026-10-31.txt`.
`EnkeonVoiceKitChecks --live-cloud` uses synthetic fixtures and exits 2 if no editor
credential is available. Ordinary checks mock cloud transport and never need an API key.

## Licence

MIT, see `LICENSE`. "Enkeon" and its logo are trademarks and are not covered by the licence.
