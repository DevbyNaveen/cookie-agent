# Cookie + Enkeon Voice → one Mac app, one repo (design)

Status: agreed in conversation with the founder 2026-11-14; written for the build plan.
Calls marked **(builder call)** were made by Claude, not the founder, and can be overturned.

## Intent

Enkeon has two Mac apps that grew side by side: **Cookie** (notch, voice, real-cursor pointing,
acts on the Mac with approvals, Board, routines; `cookie-agent` repo, ~36k lines Swift + the Rust
harness) and **Enkeon Voice** (system-wide dictation that knows your words; `enkeon-voice` repo,
~14k lines Swift, one commit). Installed together they fight: both start dictating on ⌃⌘, the
person signs in twice, grants every permission twice, and meetings are built two different ways.

The product is **Cookie, by Enkeon**: one Mac app, open source (MIT) beside the agent harness in one
repo. Enkeon stays the account, memory, cells, team and billing. Voice stops being a product and
becomes how you use Cookie with your voice. Cookie on the web/email/Slack (the headless Cookie in
the proprietary gateway) is the same Cookie, always on; the Mac app is Cookie at your desk.

Why one app: dictation is the daily habit (why people install), Enkeon memory is why they stay, and
Cookie doing the work is why they pay. Separately each is a copy (Wispr Flow; Invoko/Clicky); together,
with memory, nobody has it.

## Goals

1. One repo: `github.com/DevbyNaveen/cookie-agent`. Enkeon Voice moves in **with its history**.
2. One Mac app (Cookie.app) that does everything Enkeon Voice does today, plus everything Cookie does.
3. One dictation core (`EnkeonVoiceKit`), imported by Cookie — no copied dictation files.
4. One console: Cookie's existing Home (notch + pop-out window). Voice's main window retires.
5. No floating bar. Dictation shows in the notch and at the text cursor.
6. One sign-in, one keychain store for provider keys, one permission flow.
7. Voice's UI is **moved, not destroyed**: its pages and overlays live on inside Cookie; its app
   shell stays buildable in the repo for later reuse.

## Non-goals

- No change to the headless Cookie, the gateway, or the Rust harness's location/binary name.
- No Temporal or other workflow server. Routines stay on the gateway's Postgres scheduler
  (`thinkingrootdbcloud/services/gateway/src/cookie/routine.rs`) and the Mac scheduler.
  Revisit only when long multi-step jobs with waits outgrow it.
- No native Enkeon console app and no iPhone keyboard now (Voice's shell is parked for those).
- No automatic "dictate vs. do this" intent detection. Modes are chosen by keys, always.
- No new features beyond what the two apps already have, except where the merge needs them.

## Anti-goals (a failure even if it "works")

- **Losing someone's words.** A dictation or edit that silently goes nowhere. Every path that cannot
  verify insertion must leave the text recoverable (today: Voice's Copy/Dismiss card).
- Text typed twice or a chord that starts two things at once.
- Cookie's honesty rules weakened: plain dictation only ever types; anything that sends, deletes or
  pays still waits for a yes.
- A user who had Voice or Cookie signed in has to sign in again.
- The headless Cookie breaks because the repo moved.

## Constraints

- **Gateway contract.** The gateway runs the harness as a subprocess, `/usr/local/bin/cookie`, built
  on the box from a cookie-harness checkout (`thinkingrootdbcloud/infra/cookie/cookie-deploy.sh`,
  `services/gateway/src/cookie/harness.rs`). The Rust crate stays at the repo root, the binary stays
  `cookie`, and the `cookie serve` JSON-lines protocol does not change.
- **Builds and native checks run on the founder's Mac** (founder, 2026-11-14: "focus only on my mac
  now"). The Linux VM can't build macOS apps, and the window-drawing checks need Accessibility and
  Input Monitoring that hosted runners can't grant. Disk is tight (~9 GB free): check free space
  before a build, clean `mac/build` and `.build` after each phase. CI is not part of this work.
- **macOS only.** Windows comes later and is out of scope; nothing here should make it harder (keep
  the Rust harness platform-neutral), but nothing is built for it.
- Both apps build with Command Line Tools only (no Xcode) on macOS 15 SDK; speech helpers need SDK 26+.
- Licence: both MIT. "Enkeon" trademark note from Voice's README carries over.
- In-flight work exists in both repos (see Step 0) and must not be lost.

## Decided by the founder

- One repo, open source, beside the harness.
- One console = Cookie's dashboard (already in the notch and a pop-out window).
- Hide the bar. Dictation shows the fluid orb; Cookie's cursor already lives at the real cursor.
- Don't destroy Voice's UI; reuse it.
- Not a new brand; inside Enkeon. (App named Cookie, by Enkeon — Claude's recommendation, not
  contested.)
- No Temporal for now.

## The design

### Repo layout

```
cookie-agent/
  src/ bindings/ evals/ web/ examples/ tests/   unchanged (crate cookie-harness, binary `cookie`)
  mac/
    Package.swift      Cookie app + VoiceKit + VoiceUI as local targets
    Cookie/            the app
    VoiceKit/          ← enkeon-voice/Sources/EnkeonVoiceKit (module name kept: EnkeonVoiceKit)
    VoiceUI/           ← enkeon-voice/Sources/Enkeon pages/overlays used by Cookie (see table)
    voice/             ← enkeon-voice imported whole (subtree); the standalone app stays
                         buildable at git tag `enkeon-voice-app-v0` once its views move into Cookie
    sense/             one speech helper (cookie-sense and enkeon-sense merged)
    cookie-recorder/ cookie-tools/ cookie-py/ skills/ scripts/ Tests/
```

Exact folder names are a **builder call**; the rule is that Voice arrives via `git subtree add`
(history kept), then files move with `git mv`.

### Keys (one family on Fn)

| Hold | Does |
|---|---|
| Fn | Dictate: your words into the focused field (Voice today) |
| Fn + Ctrl | Edit the selection / current message by voice (Voice's ⌃+Fn today) |
| Fn + Shift | Dictate and keep it in memory (Voice's ⇧ during dictation today) |
| Fn + Option | Talk to Cookie (replaces Cookie's ⌃⌥ push-to-talk) |
| Double-press any of the above | Lock hands-free. Cookie's uncommitted ⌥⌘ conversation toggle becomes double-press Fn+Option |
| ⌥⇧ | Explain what's under the pointer (unchanged) |
| Esc | Cancel |

- Voice's **Ask memory** (today on ⌥+Fn: one question to Enkeon memory, answer card back) folds into
  Fn + Option. Cookie already answers from Enkeon memory, so Ask is a subset; Voice's quick answer
  card becomes how Cookie shows a short memory answer. `EnkeonVoiceKitChecks` for Ask are kept and
  pointed at the new route — **builder call**.
- Retire ⌃⌘ as a dictate chord (the collision). Keyboards without Fn keep **one** fallback chord,
  chosen so it doesn't overlap ⌃⌥ or ⌥⇧ — **builder call**, listed in Settings → Shortcuts.
- ⌃⌘C / ⌃⌘V "copy/paste last result" (Voice) stay only if they don't collide once ⌃⌘ is retired —
  **builder call**.
- Existing Cookie users who learned ⌃⌥: keep ⌃⌥ as an alias for one release with a one-time notch
  notice — **builder call**.

### What the person sees

- **No bar.** Voice's `FloatingBar` is removed from the merged app. Its jobs move to the notch:
  - hover orbs (Speak / Meeting / Memory) → the notch peek;
  - state labels ("Listening", "Editing selection", "Listening, saving to memory") → the notch's live activity;
  - the **Copy / Dismiss recovery card** (edit or insertion not verified) → a notch notice that stays
    until acted on. This is the anti-goal guard; it ships before the bar is removed.
- **At the text cursor:** Voice's `CursorPreview` (words faded at the caret while you talk; Tab types,
  Esc keeps in Enkeon). Where an app doesn't report its caret (terminals, many Electron apps) its
  fallback card, today anchored above the bar, anchors under the notch instead.
- **Two orbs, one shader:** Voice's `FluidOrb` (teal/violet/amber) = *your words* (dictate, edit,
  save). Cookie's face = *Cookie* (answering, pointing, acting). The mode is always visible.
- Cookie's real-cursor hand (pointing, reading pen, hover-explain) is unchanged.

### One console (Cookie's Home, notch + pop-out window)

| Voice page | Lands in Cookie as |
|---|---|
| Home (live orb, words/min gauge, streak, timeline) | **Your words** home |
| Dictionary · Snippets · Styles | **Your words** pages (moved as-is) |
| Notes · Context | **Memory** (Enkeon memory and cells) |
| Meetings | Board → Record a meeting (one recorder, below) |
| Connections | Connected apps (Cookie's) |
| Settings (shortcuts, permissions, speech, privacy) | Merged into Cookie's Settings pages |
| Onboarding (access, key, model, tryIt) | Merged into Cookie's setup (Welcome / Voice / Screen / Shortcuts / Ready); "try it" becomes a dictation practice step |

Look: one visual language — Cookie's `DS`. Voice's `Theme` enum becomes a thin layer whose values
point at `DS` tokens, so Voice's pages restyle without being rewritten. The notch is always dark.

### One sign-in, one key store

- Sign-in: Cookie's `com.enkeon.cookie.account` (OAuth 2.1 + PKCE, issuer `api.thinkingroot.com`) with
  the union of scopes (Cookie's already includes Voice's: `ask recall remember search connectors meetings cookie`).
- **No adoption of Voice's sign-in or keys.** The founder is the only person who has either app
  installed (founder, 2026-11-14), and ad-hoc-signed apps can't read each other's keychain items
  without a prompt. The founder signs in once to Cookie and re-enters the editor key in Cookie's
  Settings; macOS permissions are granted once to Cookie's bundle. The "nobody signs in again"
  anti-goal applies from the first public release onward.
- Provider keys: Cookie's `com.enkeon.cookie.provider-keys`, which gains Voice's editor key slot.
- Voice's editor model: the code uses Claude Haiku 4.5; its README says GPT-6.1 Terra. The code is
  the truth; the README is corrected.

### Permissions

Day one asks only what dictation needs: microphone, Accessibility, Input Monitoring (+ Speech
Recognition when the Apple provider is in use). Screen Recording is asked the first time Cookie is
asked to look, or a meeting records system audio. Cookie's `CookiePermissionCenter` is the one
implementation.

### One speech helper, one meeting recorder

- Dictation's default engine is **Apple** (on device). Voice's README is the truth: Parakeet has not
  met its accuracy/latency gates; `App/Info.plist`'s `VoiceTranscriptionProvider = parakeet` is a dev
  setting and is not carried into Cookie. Parakeet stays selectable in Settings → Speech, and its
  ~630 MB download happens only when someone picks it — never at setup — **builder call**.
- Voice's other on-device helpers come along (Goal 2): `enkeon-complete` (llama.cpp sentence
  completion, "Pen") and `enkeon-sense`'s Cleanup/Rewrite workers. CI builds llama.cpp
  (`scripts/llama.sh`). App size grows; acceptable — **builder call**.
- Speech helper: one of `cookie-sense` / `enkeon-sense`, chosen by Voice's existing benchmarks
  (`docs/MODEL-*`, `MAC-TEXT-BENCHMARK-*`) — **builder call** which; the loser's unique abilities
  (Voice's Parakeet candidate, Cookie's screen reading) move into the winner.
- Meetings: on-device transcription is the default (the engine Voice's meetings use today, Parakeet;
  its download happens on the first meeting, with a clear progress notice); Cookie's cloud path
  (`cookie-recorder` → Amazon Transcribe, eu-central-1) is opt-in in Settings. Kept meetings keep
  Cookie's behaviour: promises become Board rows.

## Order of work

0. **Clean ground (both repos have unsaved work).**
   - `cookie-harness`: checked out on `build/notch-2026-10-24`, 24 commits behind `main`, ~26 changed
     files (conversation mode on ⌥⌘, partial transcripts, `CookieProductPanel`, Rust provider failover).
     Commit on its branch, bring it onto `main`.
   - `enkeon-voice`: 4 uncommitted files (`HomeView`, `DictationController`, `TextFieldAccess`,
     `TextInsertion`). Commit them.
   - Nothing is pushed without the founder's say-so.
1. **Import.** `git subtree add` Voice into `mac/`; one local script builds Cookie.app and the Voice
   app target and runs `EnkeonVoiceKitChecks` and the Cookie native checks on the founder's Mac.
2. **One dictation core.** For each duplicated file (`AppBundleConfiguration`,
   `AppleSpeechTranscriptionProvider`, `BuddyAudioConversionSupport`, `BuddyDictationManager`,
   `BuddyTranscriptionProvider`, `GlobalPushToTalkShortcutMonitor`, `OpenAIAudioTranscriptionProvider`):
   diff, port Cookie-only changes into VoiceKit, delete Cookie's copy. One file per commit, each
   buildable. The shortcut monitor goes last and gets the key table above.
3. **Recovery before removal.** Recovery card and CursorPreview fallback re-anchored to the notch.
4. **Voice features into Cookie.** Fn family, CursorPreview, FluidOrb in the notch, Your words pages,
   QuickMemory panel, sign-in/key adoption, merged setup and settings. Then remove the bar.
5. **One speech helper, one recorder.**
6. **Ship.** One release from `cookie-agent`; the `enkeon-voice` GitHub repo archived with a
   "moved to cookie-agent" README. Voice's install/release path retired.

Each step leaves Cookie.app shippable.

## Left to the builder

Folder names; fallback chord for Fn-less keyboards; ⌃⌥ alias period; ⌃⌘C/⌃⌘V; which speech helper
wins (by the benchmarks); test shape per step (the repo's precondition-style checks, no XCTest).

## Parked (kept in the repo, not built now)

- Voice's app shell (rail sidebar, `PageKit`, `Theme`) mirrors the Enkeon web Console's layout — the
  starting point for a native Enkeon app for Mac.
- Voice's SwiftUI pages (Dictionary, Snippets, stats Home, QuickMemory) — the starting point for an
  Enkeon keyboard on iPhone (push-to-talk/AX parts are macOS-only).
- Temporal — when long multi-step jobs with waits outgrow the Postgres scheduler.
- Windows app; macOS CI; Developer ID signing and keychain adoption (needed at first public release).
