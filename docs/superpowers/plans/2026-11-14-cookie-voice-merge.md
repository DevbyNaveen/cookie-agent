# Cookie + Enkeon Voice merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One Mac app, Cookie.app, in the `cookie-agent` repo, that does everything Enkeon Voice does and everything Cookie does, with one dictation core, one keyboard tap, one console, and no floating bar.

**Architecture:** Enkeon Voice is imported with its history under `mac/voice/` and left in place. Cookie's SwiftPM package gains `EnkeonVoiceKit` as a local target (path `voice/Sources/EnkeonVoiceKit`). The kit owns the keyboard (one `GlobalPushToTalkShortcutMonitor`) and dictation (`DictationController`, already public, wired by closures). Cookie hosts one `DictationController`, subscribes to the kit's monitor for Talk / hover / conversation, and deletes its seven copied dictation files. Voice's UI files move into Cookie (`git mv`) as the Your words / Memory pages and the notch dictation face. The Rust harness at the repo root is not touched.

**Tech Stack:** Swift 5.9 SwiftPM, Command Line Tools only (no Xcode), macOS 15 SDK for the app and macOS 26+ SDK for speech helpers, precondition-style checks (no XCTest), Rust 1.91 for helpers, llama.cpp for Pen.

**Spec:** `docs/superpowers/specs/2026-11-14-cookie-voice-merge-design.md`

## Global Constraints

- Gateway contract: the crate stays at the repo root, the binary stays `cookie`, and the `cookie serve` JSON-lines protocol does not change. No task edits `src/`.
- Build and check on the founder's Mac only. Run `df -h /` before every build and stop if fewer than 6 GB are free. Clean `mac/.build`, `mac/build`, `mac/voice/.build` and `mac/voice/build` at the end of every task.
- Commit locally only. Never push. Never add a Claude co-author line (founder preference).
- Checks follow each repo's style: `precondition` in `EnkeonVoiceKitChecks` (`mac/voice/Sources/EnkeonVoiceKitChecks/main.swift`) and in Cookie's `Tests/CookieInteractionTests/*.swift`, run by `mac/scripts/check_cookie_interactions.py`.
- Plain dictation only ever types. Anything that sends, deletes or pays waits for a yes (Cookie's existing approval plane, unchanged).
- Every path that cannot verify insertion leaves the text recoverable. No silent loss of words.
- The look is Cookie's `DS`. Voice's `Theme` statics point at `DS` tokens. The notch is always dark.
- The editor key is Cookie's existing `ANTHROPIC_API_KEY` slot in `com.enkeon.cookie.provider-keys`, because Voice's editor uses Anthropic (`CloudVoiceEditor.swift:5,122`, `claude-haiku-4-5`). There is no new key slot and no adoption from Voice's keychain items.
- Default dictation engine: Apple. Parakeet is selectable and downloads only when chosen, or on the first on-device meeting.
- macOS only. Keep the Rust helpers platform-neutral.

## Review Focus

1. **No caret position**: an app doesn't report its caret (Terminal, VS Code, Slack). The live words must show under the notch and be inserted or recoverable, never dropped. Pinned in Task 6.
2. **Edit can't be verified**: the field changed during a voice edit. A notch notice with Copy / Dismiss must stay until acted on and must not time out. Pinned in Task 6.
3. **macOS's own Globe/Fn setting**: "Press 🌐 key to: Start Dictation" or "Show Emoji" is on. Holding Fn must not also open Apple dictation or the emoji picker, and Settings must say how to turn that off when it's detected. Pinned in Task 4.
4. **Two voice modes at once**: Fn is pressed while Cookie is listening or speaking (Fn+Option session or a locked conversation). Exactly one mode runs and nothing is typed twice. Pinned in Task 4 (chord) and Task 5 (host).
5. **Secure fields**: the focus is a password field (`AXSecureTextField`). A voice edit must refuse to read it, and the saved-to-memory dictation path must refuse. Pinned in Task 5.

---

### Task 0: Clean ground in both repos

**Files:** none created. Commits existing work.

**Interfaces:**
- Produces: `cookie-harness` `main` contains the conversation-mode work plus design commit `b1da771`, and a working branch `feat/one-app` is cut from it. `enkeon-voice` `main` is clean.

- [ ] **Step 1: In `~/Desktop/enkeon-voice`, review the 4 changed files** (`git diff`: `HomeView`, `DictationController`, `TextFieldAccess`, `TextInsertion`). If the diff is coherent, commit it as `wip(voice): <what the diff does>`. If it looks half-done, stop and ask the founder.
- [ ] **Step 2: Run Voice's checks**
  Run: `cd ~/Desktop/enkeon-voice && SDKROOT="$(scripts/sdk.sh app)" swift run --build-system native EnkeonVoiceKitChecks`
  Expected: exit 0. Record the final summary line for later comparison.
- [ ] **Step 3: In `~/Desktop/cookie-harness` (branch `build/notch-2026-10-24`), commit the 26 changed and untracked files** in two commits: `feat(mac): conversation mode on ⌥⌘` (Swift + AGENTS.md) and `feat(providers): failover` (`src/providers/failover.rs` + any Rust it touches). Run `cargo test` for the Rust commit only if `df` shows ≥ 6 GB free; otherwise note it and skip.
- [ ] **Step 4: Bring the branch onto `main`**: `git checkout main && git merge --no-ff build/notch-2026-10-24`. Resolve conflicts against `main`'s 24 newer commits. On a semantic conflict in a Swift file, keep both behaviours and note it in the merge message.
- [ ] **Step 5: Run Cookie's native checks**
  Run: `cd mac && python3 scripts/check_cookie_interactions.py`
  Expected: exit 0 with every summary line the script asserts. This needs a logged-in GUI session.
- [ ] **Step 6: Cut the working branch**: `git checkout -b feat/one-app`.

---

### Task 1: Import Voice with history; one local check script

**Files:**
- Create: `mac/voice/**` (via subtree)
- Create: `mac/scripts/check-all.sh`
- Modify: `mac/Package.swift`

**Interfaces:**
- Produces: SwiftPM target `EnkeonVoiceKit` in `mac/Package.swift` (path `voice/Sources/EnkeonVoiceKit`), and `mac/scripts/check-all.sh`, which runs, in order: a disk guard, `EnkeonVoiceKitChecks`, then `check_cookie_interactions.py`. Every later task verifies with `mac/scripts/check-all.sh`.

- [ ] **Step 1: Import**: `git subtree add --prefix=mac/voice ~/Desktop/enkeon-voice main`. Expected: `git log --oneline -- mac/voice` shows Voice's commits.
- [ ] **Step 1b: Tag the standalone Voice app as it is**: `git tag enkeon-voice-app-v0`. The parked app shell stays buildable at this tag (`git worktree add /tmp/voice enkeon-voice-app-v0 && cd /tmp/voice/mac/voice && ./build.sh`), because Tasks 6, 7 and 10 move its views into Cookie.
- [ ] **Step 2: Add the kit target** to `mac/Package.swift`: `.target(name: "EnkeonVoiceKit", path: "voice/Sources/EnkeonVoiceKit")`. Do not add it to Cookie's dependencies yet.
- [ ] **Step 3: Write `mac/scripts/check-all.sh`.** It must:
  - exit 1 with a message when `df` reports fewer than 6 GB free;
  - run Voice's checks from `mac/voice` (Task 0 Step 2 command);
  - run `python3 scripts/check_cookie_interactions.py`;
  - exit with the first failing status.
- [ ] **Step 4: Run** `mac/scripts/check-all.sh`. Expected: both suites pass, with the same summary lines as Task 0.
- [ ] **Step 5: Commit** `chore(mac): Enkeon Voice joins the repo under mac/voice, history kept` and clean the build dirs.

---

### Task 2: Cookie imports the kit; five small duplicates go

The duplicated files are `AppBundleConfiguration` (2 diff lines), `OpenAIAudioTranscriptionProvider` (6), `BuddyAudioConversionSupport` (20), `BuddyTranscriptionProvider` (27) and `AppleSpeechTranscriptionProvider` (96).

**Files:**
- Modify: `mac/Package.swift` (Cookie depends on `EnkeonVoiceKit`)
- Modify: `mac/scripts/check_cookie_interactions.py`
- Modify: the 5 kit files above under `mac/voice/Sources/EnkeonVoiceKit/`
- Delete: the same 5 files under `mac/Cookie/`
- Modify: Cookie files that use them (add `import EnkeonVoiceKit`)

**Interfaces:**
- Consumes: the `EnkeonVoiceKit` target (Task 1).
- Produces: the kit declares `public` on `BuddyTranscriptionProvider` (protocol incl. Cookie's `supportsPartialTranscripts`), the provider classes and `AppBundleConfiguration` members that Cookie references. `check_cookie_interactions.py` builds the kit as a separate static module before compiling Cookie.

- [ ] **Step 1: Make the check script link the kit.**
  - First: `swiftc -parse-as-library -emit-library -static -emit-module -module-name EnkeonVoiceKit -o <out>/libEnkeonVoiceKit.a voice/Sources/EnkeonVoiceKit/*.swift`, with the same `-sdk`, `-target` and module cache as the existing call.
  - Then add `-I <out> -L <out> -lEnkeonVoiceKit` to the Cookie compile.
  - Run it with nothing else changed. Expected: passes.
- [ ] **Step 2: For each of the 5 files, smallest first:**
  - `diff mac/Cookie/X.swift mac/voice/Sources/EnkeonVoiceKit/X.swift`;
  - port every Cookie-only behaviour into the kit file (`supportsPartialTranscripts` is one), plus `public` on what Cookie uses;
  - `git rm mac/Cookie/X.swift`;
  - add `import EnkeonVoiceKit` where Cookie fails to compile.
- [ ] **Step 3: Add a kit check** in `EnkeonVoiceKitChecks/main.swift`: `func checkPartialTranscripts()`. It asserts `AppleSpeechTranscriptionProvider().supportsPartialTranscripts == true` and `OpenAIAudioTranscriptionProvider(...).supportsPartialTranscripts == false`, with whatever values Cookie's copy defined (copy them exactly). Call it from the checks' entry point.
- [ ] **Step 4: Run** `mac/scripts/check-all.sh`. Expected: PASS, including the new check.
- [ ] **Step 5: Commit** `refactor(mac): Cookie's transcription providers come from EnkeonVoiceKit`.

---

### Task 3: One dictation manager

`BuddyDictationManager`: Cookie 895 lines, kit 936, 193 differing lines.

**Files:**
- Modify: `mac/voice/Sources/EnkeonVoiceKit/BuddyDictationManager.swift`
- Delete: `mac/Cookie/BuddyDictationManager.swift`
- Modify: `mac/Cookie/CompanionManager.swift`, `CookieChat.swift`, `CookieNewAgentView.swift` (the call sites)

**Interfaces:**
- Consumes: Task 2's public providers.
- Produces: `public final class BuddyDictationManager`, with `public` on every member these three Cookie files use today (start/stop/finalize, transcript and level publishers, contextual keyterms, partial-transcript stream).

- [ ] **Step 1: Diff and list each difference** as "Cookie-only", "kit-only" or "conflict", in the commit message draft.
- [ ] **Step 2: Port Cookie-only behaviour into the kit.** Cookie's partial transcripts feed conversation mode (`CompanionManager.swift:718-800`), and that path must keep working. On a conflict, keep the kit's verified-insertion behaviour and Cookie's turn-taking behaviour.
- [ ] **Step 3: Delete Cookie's copy and fix the call sites.**
- [ ] **Step 4: Run** `mac/scripts/check-all.sh`. Expected: PASS. In particular `CookieConversationModeTests` and `CookieVoiceFlowTests` keep their counts ("8 voice flow checks passed.").
- [ ] **Step 5: Commit** `refactor(mac): one BuddyDictationManager, in EnkeonVoiceKit`.

---

### Task 4: One keyboard: the Fn family

**Files:**
- Modify: `mac/voice/Sources/EnkeonVoiceKit/GlobalPushToTalkShortcutMonitor.swift`
- Modify: `mac/voice/Sources/EnkeonVoiceKit/DictationController.swift` (Ask leaves; monitor exposed)
- Delete: `mac/Cookie/GlobalPushToTalkShortcutMonitor.swift`
- Modify: `mac/Cookie/CompanionManager.swift`, `CookieHover.swift` (subscribe to the kit's monitor)
- Modify: `mac/voice/Sources/EnkeonVoiceKitChecks/main.swift` (`checkDictationChord`, `checkFnChord`)

**Interfaces:**
- Produces, in the kit (all `public`):
  - `enum VoiceChord: Equatable { case dictate, edit, memory, talk }`
  - `static func GlobalPushToTalkShortcutMonitor.chord(_ raw: UInt64) -> VoiceChord?`. Mapping: Fn → `.dictate`; Fn+⌃ → `.edit`; Fn+⇧ → `.memory`; Fn+⌥ → `.talk`; ⌃⌥ alone → `.talk` (one-release alias); the Fn-less fallback chord → `.dictate` (builder picks one that overlaps neither ⌃⌥ nor ⌥⇧ and records it in `AGENTS.md`); ⌃⌘ → `nil`.
  - `static func hoverHeld(_ raw: UInt64) -> Bool`: ⌥⇧ only, with no ⌃ and no ⌘.
  - `struct DoublePress { init(window: TimeInterval = 0.35); mutating func press(at t: TimeInterval) -> Bool }`: returns true on the second press inside the window.
  - Publishers on the monitor: `chordPublisher: PassthroughSubject<(VoiceChord, BuddyPushToTalkShortcut.ShortcutTransition), Never>`, `lockPublisher: PassthroughSubject<VoiceChord, Never>` (double-press), `hoverShortcutPublisher: PassthroughSubject<Bool, Never>`, plus the existing `cancellationPublisher`, `dictationAbortPublisher` and `recoveryPublisher`.
  - `DictationController.shortcuts` becomes `public let shortcuts: GlobalPushToTalkShortcutMonitor`. The process has exactly one event tap. `DictationController` reacts only to `.dictate`, `.edit` and `.memory`, and its `askMemory` route is removed (Ask is served by Talk to Cookie).
  - `static func globeKeyConflict() -> String?`: reads `com.apple.HIToolbox` `AppleFnUsageType`. Returns nil when it's "Do Nothing"; otherwise returns the plain-words fix shown in Settings → Shortcuts.

- [ ] **Step 1: Write the failing checks.** Replace `checkDictationChord` and extend `checkFnChord`:
  ```swift
  typealias M = GlobalPushToTalkShortcutMonitor
  let fn = CGEventFlags.maskSecondaryFn.rawValue
  precondition(M.chord(fn) == .dictate)
  precondition(M.chord(fn | CGEventFlags.maskControl.rawValue) == .edit)
  precondition(M.chord(fn | CGEventFlags.maskShift.rawValue) == .memory)
  precondition(M.chord(fn | CGEventFlags.maskAlternate.rawValue) == .talk)
  precondition(M.chord(CGEventFlags([.maskControl, .maskAlternate]).rawValue) == .talk, "⌃⌥ alias")
  precondition(M.chord(CGEventFlags([.maskControl, .maskCommand]).rawValue) == nil, "⌃⌘ retired")
  precondition(M.hoverHeld(CGEventFlags([.maskAlternate, .maskShift]).rawValue))
  precondition(!M.hoverHeld(CGEventFlags([.maskAlternate, .maskShift, .maskControl]).rawValue))
  var d = DoublePress(); precondition(!d.press(at: 0)); precondition(d.press(at: 0.3)); precondition(!d.press(at: 2))
  ```
  Also add the Review Focus #4 check: with a `.talk` session held, a `.dictate` press transition is not emitted (model the guard as `static func accepts(_ new: VoiceChord, whileHeld: VoiceChord?) -> Bool`, false whenever `whileHeld != nil`).
- [ ] **Step 2: Run** the Voice checks. Expected: FAIL (`VoiceChord` undefined).
- [ ] **Step 3: Implement** the monitor from the kit's version, plus Cookie's hover, conversation toggle (now `lockPublisher` on `.talk`) and escape behaviour. Delete Cookie's copy. `CompanionManager` subscribes to `dictation.shortcuts` (the host's controller from Task 5; until then construct one `DictationController` in `CompanionManager` and expose it). Remove Cookie's ⌥⌘ toggle.
- [ ] **Step 4: Run** `mac/scripts/check-all.sh`. Expected: PASS. Update `CookieConversationModeTests` expectations from ⌥⌘ to double-press Fn+⌥, with the same counts.
- [ ] **Step 5: Commit** `feat(mac): one keyboard: Fn dictates, ⌃ edits, ⇧ keeps, ⌥ talks to Cookie`.

---

### Task 5: Cookie hosts dictation

**Files:**
- Create: `mac/Cookie/CookieDictation.swift` (owns the one `DictationController` and wires its closures)
- Modify: `mac/Cookie/CookieVoiceActions.swift` (remove Cookie's own direct-dictation and insertion/undo path, which the kit's `TextInsertion` now does)
- Modify: `mac/Cookie/CookieApp.swift` / `CompanionManager.swift` (use `CookieDictation.shared.controller`)
- Test: `mac/Tests/CookieInteractionTests/CookieDictationHostTests.swift`

**Interfaces:**
- Consumes: `DictationController` (kit, public), `CookieAPI`/`CookieAccount` (Enkeon remember), Cookie's provider-key store.
- Produces: `@MainActor final class CookieDictation { static let shared; let controller: DictationController; func start() }`. Wiring:
  - `saveToMemory` → Enkeon `remember` through the signed-in account, returning `("Kept in Enkeon", true)` or the plain error.
  - `editSelection` → the kit's `CloudVoiceEditor` with the key from `ANTHROPIC_API_KEY`, or Apple on-device when Settings says so.
  - `enkeonTerms` → loaded from Enkeon on sign-in, as Voice's `AppModel` does.
  - `onRecord`, `onLearned`, `expand`, `cleanupStyle` → Voice's stores, which arrive in Task 7. Leave them nil until then.

- [ ] **Step 1: Write the failing checks** in `CookieDictationHostTests.run()` (registered in the checks' entry point and in the script's expected summary as `"N dictation host checks passed."`):
  - `CookieDictation.shared.controller.shortcuts === CompanionManager`'s monitor (one tap).
  - Review Focus #5: `CookieDictation.refusesSecure(role: "AXSecureTextField") == true` and `refusesSecure(role: "AXTextField") == false`. The controller's `editSelection` and `saveToMemory` wrappers return a refusal for a secure destination without calling the closure. Assert with a closure that sets a flag.
- [ ] **Step 2: Run** `python3 scripts/check_cookie_interactions.py`. Expected: FAIL.
- [ ] **Step 3: Implement** `CookieDictation` and the wiring above, and delete Cookie's duplicate insertion path in `CookieVoiceActions`, keeping its local routing and lessons.
- [ ] **Step 4: Run** `mac/scripts/check-all.sh`. Expected: PASS.
- [ ] **Step 5: Hand-check on the Mac** (`./build.sh`, open `build/Cookie.app`):
  - Fn dictation types into TextEdit;
  - Fn+⌃ rewrites a selection;
  - Fn+⇧ keeps a sentence in Enkeon (see it on enkeon.com);
  - Fn+⌥ talks to Cookie.
- [ ] **Step 6: Commit** `feat(mac): Cookie hosts Enkeon dictation` and clean the build dirs.

---

### Task 6: Dictation's face in the notch and at the caret

**Files:**
- Move: `mac/voice/Sources/Enkeon/{FluidOrb,CursorPreview,BrandMotion}.swift` → `mac/Cookie/` (`git mv`)
- Modify: `mac/Cookie/NotchIsland.swift`, `CookieInteractionState.swift`
- Test: `mac/Tests/CookieInteractionTests/CookieDictationFaceTests.swift`

**Interfaces:**
- Consumes: `DictationController.phase`, `.isEditing`, `.toMemory`, `.liveText`, `.recoveryText`, `.level`.
- Produces: `enum NotchVoiceFace: Equatable { case none, words(label: String), cookie }` and `static func face(phase:isEditing:toMemory:cookieActive:) -> NotchVoiceFace`. Labels (exact copy from Voice): "Listening", "Editing selection", "Editing message", "Listening, saving to memory". Also `CookieInteractionState` gains `.notice(.recovery(text: String))`, which never auto-dismisses.

- [ ] **Step 1: Write the failing checks:**
  - `face(phase: .listening(handsFree: false), isEditing: false, toMemory: false, cookieActive: false) == .words(label: "Listening")`;
  - `toMemory: true` → `"Listening, saving to memory"`;
  - `cookieActive: true` → `.cookie`;
  - Review Focus #2: given `recoveryText = "hello"`, the state is `.notice(.recovery(text: "hello"))`, and after a simulated 60 s with no action it is still that notice;
  - Review Focus #1: `CursorPreview.anchor(caret: nil)` returns `.underNotch` (rename Voice's bar-anchored fallback), and `anchor(caret: rect)` returns `.caret(rect)`.
- [ ] **Step 2: Run** the checks. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Show `FluidOrb` (Voice palette) in the notch's live activity for `.words`, and Cookie's face for `.cookie`.
  - Re-anchor CursorPreview's fallback under the notch.
  - Map `recoveryText` to the persistent notice with Copy and Dismiss, whose actions go to `controller.copyLast()` / clear.
  - Move Voice's hover orbs (Speak / Meeting / Memory) into the notch peek.
- [ ] **Step 4: Run** `mac/scripts/check-all.sh`. Expected: PASS.
- [ ] **Step 5: Hand-check:**
  - dictate into Terminal (no caret): the words appear under the notch and are inserted;
  - change a field mid-edit: the recovery notice stays and Copy works.
- [ ] **Step 6: Commit** `feat(mac): your words show in the notch and at the caret; recovery never times out`.

---

### Task 7: One console: Your words and Memory pages

**Files:**
- Move (`git mv`, from `mac/voice/Sources/Enkeon/` to `mac/Cookie/`): `Pages.swift` (Dictionary, Snippets, Styles), `HomeView.swift` (Your words home), `QuickMemoryView.swift`, `MemoryPanelAnchor.swift`, `MemoryNoteStore.swift`, `HistoryStore.swift`, `Snippets.swift`, `PageKit.swift`, `Theme.swift`, `PhosphorIcon*.swift`, `MemoryCardsIcon.swift`
- Modify: `mac/Cookie/Theme.swift` (statics → `DS` tokens), `CookieNavigationViews.swift`, `CookieUI.swift` (sections), `CookieDictation.swift` (wire `onRecord`, `onLearned`, `expand`, `cleanupStyle` to the moved stores)
- Test: `mac/Tests/CookieInteractionTests/CookieWordsPagesTests.swift`

**Interfaces:**
- Consumes: `CookieDictation.shared.controller`.
- Produces:
  - sidebar order **Board · Your words · Memory · Chats**;
  - Your words tabs **Home · Dictionary · Snippets · Styles**;
  - Memory shows Voice's Notes and Context content.
  - Voice's `AppModel` responsibilities that the moved views need are re-homed on `CookieDictation`. Don't move `AppModel` itself.
  - The stores keep their existing on-disk paths (`~/Library/Application Support/Enkeon/…`), so the founder's history survives.

- [ ] **Step 1: Write the failing checks:**
  - the sidebar sections equal `["Board", "Your words", "Memory", "Chats"]`;
  - `Theme.accent` resolves to `DS.Colors.accent`;
  - `HistoryStore` path ends with `Application Support/Enkeon/history.json`;
  - after `controller.onRecord?(record)` the store contains the record.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** the moves, the Theme→DS mapping, the navigation and the wiring. In `mac/voice/Package.swift`, remove the `Enkeon` executable target, because its views now live in Cookie. Keep the kit and `EnkeonVoiceKitChecks` targets. The full app stays at tag `enkeon-voice-app-v0`.
- [ ] **Step 4: Run** `mac/scripts/check-all.sh`. Expected: PASS.
- [ ] **Step 5: Hand-check** in the notch and the pop-out window: the Your words home shows real words-per-minute and timeline data after a few dictations.
- [ ] **Step 6: Commit** `feat(mac): one console: Your words and Memory join Cookie's Board`.

---

### Task 8: Setup and Settings merged

**Files:**
- Modify: `mac/Cookie/CookieSetupState.swift`, `CookieSetupView.swift`, `CookieSettings.swift`, `CookieUI.swift`
- Test: extend `CookieSetupTests.swift`

**Interfaces:**
- Produces:
  - setup steps **Welcome · Voice · Practice · Screen · Shortcuts · Ready**. Practice is Voice's tryIt field, with dictation into it.
  - Settings → Shortcuts lists the Task 4 table, verbatim, plus the Fn-less fallback and the `globeKeyConflict()` warning when non-nil.
  - Settings → Speech: engine **Apple** (default) or **Parakeet** (shows "downloads about 630 MB"), editor **Claude Haiku 4.5 · cloud** or **Apple · on device**, and Pen on/off.
  - Permissions at setup: microphone, Accessibility and Input Monitoring (+ Speech Recognition for Apple). Screen stays on its own step and is skippable.

- [ ] **Step 1: Write the failing checks:**
  - `CookieSetupState.Step.allCases.map(\.title) == ["Welcome", "Voice", "Practice", "Screen", "Shortcuts", "Ready"]`;
  - the default `VoiceTranscriptionProvider` reads as Apple when the key is absent;
  - the Practice step's field accepts a fixture dictation (reuse `scripts/CookieDictationFixture.swift`).
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.** Also remove `VoiceTranscriptionProvider = parakeet` from what Cookie's Info.plist carries.
- [ ] **Step 4: Run** `mac/scripts/check-all.sh`. Expected: PASS, and the setup count matches the new total in the script's expected line.
- [ ] **Step 5: Commit** `feat(mac): one setup and one Settings for voice and Cookie`.

---

### Task 9: Helpers: one speech helper, plus Pen

**Files:**
- Modify: `mac/cookie-sense/**` (gains Voice's Cleanup/Rewrite workers and the Parakeet path from `mac/voice/Helpers/enkeon-sense`)
- Modify: `mac/build.sh` (bundles `enkeon-complete` via `voice/scripts/llama.sh`; drops building enkeon-sense)
- Modify: kit `SpeechHelper.swift` (points at `cookie-sense`'s binary name and protocol)

**Interfaces:**
- Produces: one helper binary `Contents/Helpers/cookie-sense` that serves both Cookie's requests (Vision text, faces, SpeechAnalyzer) and Voice's requests (cleanup, rewrite, Parakeet), plus `Contents/Helpers/enkeon-complete`. **Builder call:** if Voice's benchmarks (`mac/voice/docs/MODEL-*`, `MAC-TEXT-BENCHMARK-*`) show enkeon-sense's speech path is better, `cookie-sense` takes that path's code. Record the choice and the numbers in the commit message.

- [ ] **Step 1: Write the failing check.** Extend `mac/voice/scripts/check-sense.py` (or copy it to `mac/scripts/`) so it runs against `cookie-sense` and asserts that a spoken sentence comes back as text *and* that a cleanup request returns text (exit 2 while the macOS speech model isn't installed is still allowed).
- [ ] **Step 2: Run.** Expected: FAIL (cleanup is unknown to cookie-sense).
- [ ] **Step 3: Implement** the port, the `build.sh` changes and the `SpeechHelper` change.
- [ ] **Step 4: Run** `./build.sh`, the sense check, then `mac/scripts/check-all.sh`. Expected: PASS, and `Cookie.app/Contents/Helpers/` contains `cookie`, `cookie-tools`, `cookie-recorder`, `cookie-sense` and `enkeon-complete`, all with the hardened runtime.
- [ ] **Step 5: Commit** `feat(mac): one speech helper; Pen sentence completion ships in Cookie` and clean the build dirs.

---

### Task 10: One meeting recorder, on device by default

**Files:**
- Move: `mac/voice/Sources/Enkeon/{MeetingModel,MeetingsView}.swift` → `mac/Cookie/` (adapted into Board → Record a meeting)
- Modify: `mac/Cookie/CookieRecorder.swift`, `CookieBoardView.swift`, `CookieSettings.swift`
- Test: `mac/Tests/CookieInteractionTests/CookieMeetingTests.swift`

**Interfaces:**
- Consumes: kit `MeetingCapture` (on-device, Parakeet), `cookie-recorder` (cloud).
- Produces:
  - `enum MeetingTranscription { case onDevice, cloud }`, with default `.onDevice`, and Settings → Privacy "Transcribe meetings in the cloud" (off).
  - Either path ends in the same keep step, `CookieRecorder.decide(keep:)`, taking the transcript text, so kept meetings still turn promises into Board rows.

- [ ] **Step 1: Write the failing checks:**
  - default `.onDevice`;
  - for an on-device fixture transcript with "I'll send the deck Thursday", `decide(keep: true)` produces one Board row whose text contains "send the deck";
  - with Parakeet absent, starting a meeting reports "downloading the meeting model" rather than failing silently.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `mac/scripts/check-all.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(mac): meetings transcribe on this Mac by default; cloud is opt-in`.

---

### Task 11: Finish: no bar, docs, release build

**Files:**
- Modify: `mac/README.md`, `mac/AGENTS.md`, root `README.md` (the Fn table, Your words, meetings, "Enkeon Voice now lives here")
- Modify: `mac/voice/README.md` (a header saying the standalone app is parked and not shipped; correct the editor model to Claude Haiku 4.5)
- Check: Cookie never compiles `FloatingBar.swift`

**Interfaces:**
- Produces: a release `./build.sh` of Cookie.app that the founder installs. The `enkeon-voice` GitHub archive note is prepared but **not pushed**; the founder is asked.

- [ ] **Step 1: Write the failing check:** `CookieWordsPagesTests` asserts that no type named `FloatingBar` or `FloatingBarPanel` exists in Cookie's module (search the source list in the check script: `grep -L`-style assertion in `check-all.sh`).
- [ ] **Step 2: Run.** Expected: PASS if Tasks 6–7 never moved it; otherwise FAIL, and remove it.
- [ ] **Step 3: Update the docs** as listed.
- [ ] **Step 4: Run** `mac/scripts/check-all.sh`, then `./build.sh`, then `open build/Cookie.app`. Hand-check the full list from Tasks 5, 6, 7 and 10, plus Review Focus #3: with Globe set to "Start Dictation", Settings shows the warning, and holding Fn types once.
- [ ] **Step 5: Quit the old apps** (Enkeon.app, older Cookie.app) and move them to the Trash only after the founder confirms.
- [ ] **Step 6: Commit** `docs: one app: Cookie with Enkeon dictation` and clean every build dir.
- [ ] **Step 7: Ask the founder** before merging `feat/one-app` into `main`, pushing, or archiving the `enkeon-voice` repo.
