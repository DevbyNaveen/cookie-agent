# Cookie - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens the Cookie notch home. Right-click opens a native Settings/Help/Quit menu. First launch presents a resumable graphite setup window with optional, explicitly requested permissions. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it (Apple Speech by default, OpenAI with the person's key), and hands the words — and a screenshot only when asked — to Cookie. Cookie thinks through the bundled `cookie serve` helper (`HarnessClient.swift`, from cookie-agent), answers in text, and speaks it (ElevenLabs with the person's key, else the Mac's own voice). A cursor overlay can fly to and point at what the answer names, on any connected monitor.

No key ships in the app: model keys are the person's own, or their Enkeon sign-in.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **Thinking**: the bundled `cookie serve` (cookie-agent), one process per run, over its JSON-lines protocol (`HarnessProtocol.swift`)
- **Speech-to-Text**: Apple Speech by default; OpenAI transcription when the person adds a key
- **Text-to-Speech**: streamed while the reply is written — one ElevenLabs stream-input WebSocket per reply (Flash v2.5, raw `pcm_24000` into `AVAudioEngine`), through Enkeon's relay (`GET /v1/projects/{p}/cookie/speech/stream`) when signed in and `GET /v1/cookie/session` says `speech`, else straight with the person's key, else `AVSpeechSynthesizer` sentence by sentence
- **One Cookie**: `CookieAPI` serves the Board, jobs, routines, approvals, drafts and settings from the routes Cookie's web page uses — Enkeon's gateway when signed in, else `cookie page` from the bundled helper on 127.0.0.1
- **Screen Capture**: ScreenCaptureKit, multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Cookie's answer embeds a `[POINT:x,y:label:screenN]` tag inline, after the words naming the element. The overlay maps the coordinates to the correct monitor and animates the cursor along a bezier arc to the target when speech reaches the tag. Arrived, the hand shows the tag's label (only when the model gave one; no stock phrases) in Cookie's amber ink pill beside it for 3 s, then flies back.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: none; `CookieAnalytics.swift` sends nothing

### Key Architecture Decisions

**Menu Bar Entry**: `NSStatusItem` opens the existing notch/home on left-click. Right-click (or Control-click) offers a native Open Cookie / Settings / Help / Quit menu; there is no separate companion popup. Help offers shortcuts and setup replay.

**First-Run Setup**: `CookieSetupController` owns a focusable, graphite SwiftUI window with Welcome / Voice / Screen / Shortcuts / Ready steps. `CookieSetupProgress` persists the current step, honors the existing `hasCompletedOnboarding` flag and resumes after a quit/relaunch. Permission steps are skippable; only finishing marks setup complete. Replay does not reset completion. The shortcut monitor and notch hover are suspended while setup is visible. Setup completion does not start a recording, AI demo or music. If no usable model is configured, completion opens the existing model settings.

**Permissions**: `CookiePermissionCenter` is shared by setup and Settings, uses current OS authorization and makes requests only from explicit buttons. Apple Speech permission is included only for providers that need it. Shortcut readiness checks both Accessibility and Input Monitoring. Screen access can be verified with an explicit local, discarded capture; a persisted success is not a permission grant. Typed questions work without screen access. Existing users are not forced through setup when optional grants are missing.

**Notch Interaction**: The notch clips its background and transitioning content as one composited surface. Its original spring is preserved; hover opens after 220 ms and leaving gets a 180 ms grace period. Keyboard focus returns after collapse settles. Layout fits the current screen, with a collapsible sidebar and full-width file preview when space is limited. Reduce Motion disables spatial transitions and decorative animation.

**Compact Notch**: `CookiePeekContent` presents Cookie's live status with its main character, then Latest and Up next, followed by a quick-question field. The character has opt-in breathing, blinking and hover response; its timeline pauses when hidden or Reduce Motion is enabled. Stored work counts do not imply active execution. Listening, replying and approval states use the actual companion state. The rows scroll on short screens while the composer stays available. `CookieNavigation.peekDraft` keeps quick questions in memory across folding/navigation; sending is guarded while a voice/reply interaction is active. Calendar and work actions continue through the existing `PeekAction` routes.

The compact composer swaps its typing controls for `CookieVoiceMedallion` during push-to-talk: the same blue, microphone-level waveform used in the expanded chat, with Listening/Release to send, then thinking or speaking and Stop. The draft binding is retained during the swap. Both surfaces share `CookieComposerPhase` and the same voice indicator; Reduce Motion is respected.

**Agents**: Every chat belongs to one `CookieAgent` (name, role, detail, kind, the apps it answers in, its routines), kept in `CookieAgentStore` (sealed `agents.sealed`). Only Cookie herself ships. The "+" beside the sidebar search opens `CookieNewAgentView`, a spoken conversation driven by `CookieCreationSession` and drawn by `CookieCreationPresentation`: Cookie asks aloud what the new Cookie should do, the person holds the hotkey or the pill (hotkey transcripts go to the page through `CompanionManager.transcriptInterceptor`, never to the chat) or types, and `converseForNewAgent` returns `{"say", "agent"}` JSON; Cookie answers aloud, asks at most one more question, then the character appears for editing (name, role, what it helps with, kind, the apps it answers in, routines). The same page is a made Cookie's profile (title-row click). Each made Cookie has its own creature keyed by its id; Cookie herself is the default creature. There is no Agents page.

**Place-bound Cookies**: `frontAppAtPress` is captured when the hotkey goes down. `routeToAgent(forApp:)` sends the transcript to the Cookie whose `apps` cover that app (its latest chat, or a new one) before `sendToModel`. Cookie herself never binds.

**Writing where you are**: `CookieWriteGrants` (Privacy & safety → "Writing where you are") lists apps where `type_text`/`set_value`/`replace_selection`, and a `start_task` whose apps are all allowed, are approved without a card; sending, paying and deleting still ask. `typeText` verifies the field took the keystrokes and pastes (restoring the clipboard) when it didn't. `MacOperator.lastTyped` keeps the draft; on the next hotkey press `captureCorrection` compares the field, and `CookieCorrections.summary` sends one learnable sentence to Enkeon as a preference under that Cookie. Text selected in the front app at hotkey press goes to the model as untrusted context; `replace_selection` swaps it for a quick fix.

**Background runs**: `CookieBackgroundRuns` runs up to three Cookies at once, each in its own chat and its own `HarnessClient` (helper process, shut down after), with approvals declined and instructions that say so. Routines (`CookieRoutine`, parsed from one sentence like "every morning, …"; cadences daily, weekdays, weekly, every N minutes) fire from a 30 s scheduler; a routine with "only when …" is a watcher that stays quiet unless the model answers with something other than `NOTHING_NEW`. Results post a notification, a notch notice, and a Board row linked to the chat. `hand_off(agent, brief)` is an outbound tool: after a yes, the named Cookie starts in the background and the Board shows the chain. A kept meeting (`CookieRecorder.decide(keep:)`) turns each promise into a Board row and starts a background follow-up draft.

**Dock**: `CookieAgentDock` floats each active background Cookie at the right screen edge; the reply in front of the person is never in it (the notch already shows Cookie working). A face unfolds into one clipped graphite surface with live voice status, current text, inline activity, Stop and Open. The native window stays fixed while the surface uses the notch spring; streamed text never resizes it. Animated rounded hit regions let the transparent space pass clicks through. Hover uses 220 ms intent and 320 ms exit grace; explicit collapse waits for a new approach. Reduce Motion disables spatial transitions. There is no outer shadow or separate backing beneath the card. The dock follows the screen-recording visibility preference and hides while Cookie's main home is open.

**Hide from screen sharing**: the General setting (`CK.Key.showInRecordings`, default true = visible; the switch reads "hide") is applied by `CookieCaptureShield` to every Cookie window, started once at launch. Off sets `sharingType = .none` (Apple: legacy, not to be relied on) and asks the private `CGSSetWindowCaptureExcludeShape` (resolved with dlsym, never linked) to leave the window out, re-applied on show and resize. It is best effort: QuickTime and macOS screen recording still capture Cookie, and Settings says so. Cookie's own captures exclude its windows separately in `CompanionScreenCaptureUtility`.

**Teach by doing**: the status menu's "Teach Cookie a task" starts `CookieTeach`, a listen-only event tap that records clicks (as the control under the pointer), typing (never from secure fields) and shortcuts; stopping asks for a name and `CookieSkillWriter` writes `~/Library/Application Support/Cookie/skills/taught-<slug>/SKILL.md`. `CookieSkills.directoryForHarness()` merges the app's skills with taught ones for the helper.

**What Cookie saw**: `CookieScreenMemory` OCRs the redacted cursor-screen capture of every look (Vision, off main) and keeps the text for a day, sealed; the `recall_screen` tool answers "what was that number an hour ago" with when and where. Privacy & safety has the switch and "Forget".

**Drawing on screen**: the model writes up to six `[DRAW:kind:…:label]` tags inline, right after the words they illustrate (circle, arrow, underline, bracket, note, number), in screenshot pixel space or anchored to a `look` element id (`#12`). `CookieReplyTags.split` takes every tag out of the reply (`[KIND:body]`, or `[KIND {json}]` for CARD and SCENE) and keeps each one's UTF-16 offset in the spoken text, which is exactly what the voice speaks. `CookieDrawingResolver.resolve` maps marks to AppKit global points per display (the same scale and flip as pointing) and snaps pixel marks to the control under them via `AXUIElementCopyElementAtPosition`. When Cookie speaks, `onPlaybackStarted` schedules each mark, and the pointer, on the speech clock at its offset; stopped or talked-over speech drops what it hasn't reached. Typed replies (or a voice that never starts) reveal marks at once in order. `CompanionManager.revealMark` adds one mark (0.3 s after the one before when they arrive together), shows the overlay if hidden, and marks clear on any key or click, Escape, the next turn, or 45 s after the latest. `CookieMarksLayer` inks them with `CookieInk` (a Swift port of Rough.js perturbation and perfect-freehand outlines, seeded per mark) in the orb's amber under one soft shadow, drawing each stroke's revealed prefix on frames from the overlay's `NSView.displayLink` at `NSScreen.maximumFramesPerSecond`, paused when the ink is dry. Reduce Motion shows each mark whole on its word. Click-through. Every label, note pill and number, the hand's pill and the hover answer are placed by `CookieOnScreen` inside `CookieMarksLayer.visibleArea` (the display's `NSScreen.visibleFrame`, 12 pt in): a pill that would run off the side it grows towards flips to the other side of its mark (a note's tick turns round), then is nudged in; cards keep the same 12 pt inside the visible frame.

**Reading pen**: `[READ:exact words]` sits inline where Cookie starts talking about text on the screen (at most three a reply). While the voice is prepared, `CookieReadingPen.find` (off the main thread) looks for the words in the app the question is about — never a `MacSafety`-blocked app, never while `CaptureGuard.refusal()` says a password is being typed: it walks the focused window's text elements (AXStaticText, AXTextArea, AXTextField, AXComboBox, AXSearchField, into AXWebArea; `AXManualAccessibility` for Chromium/Electron, as `look` does), matches case-, whitespace- and curly-quote-insensitively (`Folded`), and turns the character range into one screen rect per line with `kAXLineForIndexParameterizedAttribute` / `kAXRangeForLineParameterizedAttribute` / `kAXBoundsForRangeParameterizedAttribute` (a range's single bounds are used only when one line tall; rects must lie in the window). Nothing there: Vision text recognition through `CookieVisionText` (accurate once warm, else fast) on this turn's screenshots, matched across recognised lines, `boundingBox(for:)` → pixels → AppKit via `CookieDrawingResolver.global`. Of several matches the one nearest the pointer wins; none found drops the tag. Each line becomes an underline mark with `readSeconds` (its share of the phrase at ~15 characters a second, 0.3–4 s), scheduled on the speech clock at the offset of the words that begin it; `CookieMarksLayer` inks it as one steady broad highlighter pass at 70 % ink, at an even pace, the hand riding it, and `revealMark` starts the next mark only once a reading line is read. Typed replies show the lines in order at once.

**Spotlight**: `[FOCUS:x,y,w,h]` (screenshot pixels) or `[FOCUS:#id]` (from the latest `look`), with optional `:screenN`, inline where Cookie starts explaining a region. `CookieDrawingResolver.spotlight` places it; `CompanionManager.focus` publishes `spotlight` on its word (typed: the first at once) and sends `CookieHand.rest(beside:)` so the hand rests just outside the cut-out's corner. `CookieSpotlightLayer` (under the marks on every overlay) dims the display black 0.28 (0.4 in Dark Mode; ×0.7 and no animation under Reduce Motion) with a blurred rounded cut-out 12 pt around the region: fades in over 0.25 s, springs to the next region, fades out in place. It lifts when Cookie stops speaking, with the marks (key, click, Escape, next turn, 45 s), and is hidden while `CursorPresence.typing`. Click-through.

**Show, then do**: before `press`, `set_value`, `type_text`, `scroll`, `drag`, `choose_menu` or `click_at` runs, `MacOperator.cue` names where (the element's AX centre, the caret from `kAXSelectedTextRangeAttribute` + `kAXBoundsForRangeParameterizedAttribute` via `CookieReadingPen.bounds` else the field's leading edge, the first menu-bar title, the `click_at` point, the drag's start and drop) and a 2–4 word pill ("Clicking Save", "Typing", "Opening File"); `perform` awaits `CookieHand.shared.act(at:dragTo:label:)`. The overlay on that display flies the hand there (0.12–0.4 s by distance; no flight when it is already on that control, as in a burst), dips the pointer and spreads an ink ring from the tip (`CookiePressRipple`, a `keyframeAnimator`, 0.18 s), then calls `landed`; a drag's hand rides to the drop point while the drag runs (the drag awaits between steps, so the main thread keeps drawing). With no overlay there, or the hand pointing or guiding, `act` returns after 0.6 s and the action runs anyway. Esc during the cue ends the task (the existing watch) and the action does not run. After the action the hand stays 0.9 s, then goes back. Reduce Motion: the hand jumps, no dip or ring. Keys, scripts and `replace_selection` have no cue. While the hand works during a run the pointer shows instead of the spinner.

**Do it with me**: `wait_for_step(id, say, hint?, step?)` publishes a `CookieGuideStep` through `MacOperator.guiding` to `CompanionManager.guideStep`: the overlay flies the hand to the control's lower right and keeps it there with the instruction pill, `CookieGuideBadge` puts the step's number in an ink disc at the control's top-left corner, and the spotlight (`CookieSpotlightLayer`, fed `spotlight ?? guideStep.spotlight`) dims the rest. The step ends when a listen-only global mouse monitor (`NSEvent.addGlobalMonitorForEvents`) sees a click inside the control's AX frame, its value changes, focus moves to it, or the person answers: while a step waits `isWaitingOnPerson` makes the voice state idle and `isWorking` false, so the hotkey (which then doesn't cancel the run) and the composer route the words to `MacOperator.answerStep` (shown in the chat). "skip" moves on, "done" ticks the badge, anything else goes back to the model. A ticked badge stays 1.2 s unless the next step replaces it. At 45 s the hint replaces the instruction and the hand taps again; at 3 min the step ends unanswered. Escape or Stop ends the run, and `endRun` bumps `runGeneration` and clears the step. The prompt prefers a guided walk-through for "how do I…" unless the person asked Cookie to do it.

**Hover to explain**: hold ⌥⇧ on their own (push-to-talk and circle select hold ⌃⌥; ⌃ or ⌘ with them is never this) and rest the pointer ~350 ms. `GlobalPushToTalkShortcutMonitor` sends `hoverShortcutPublisher` on each modifier change (a key typed while ⌥⇧ are held — they type symbols — ends it until release); `CookieHoverExplainer` polls the pointer every 50 ms while held and checks the keys' physical state. `CookieHoverReading.read` hit-tests `AXUIElementCopyElementAtPosition` on the system-wide element; Cookie's own pid is ignored, and a `MacSafety`-blocked app, `CaptureGuard.refusal()` or an `AXSecureTextField` gets the pill "Cookie doesn't read this" before any attribute is read, with no model call. Otherwise it reads role description, label, value (200 chars), help, the window title, two ancestors' labels and the word/sentence under the pointer (`kAXRangeForPositionParameterizedAttribute`, then `kAXStringForRangeParameterizedAttribute` over ±300 characters), hides `SensitiveText` matches when "hide secrets" is on, and sends it as untrusted «…» text. Only an element with no words at all also sends a 360×240 crop round the pointer (`captureRegionAsJPEG`: Cookie and blocked apps excluded, redacted), and only with screen access. The question is a `HarnessClient.ask` on the explainer's own helper (so it never cancels the reply in front of the person): `HarnessRequest.Ask`, one model call, no tools, MCP, skills, history or Enkeon; `cookie serve` has no per-run output cap, so the stream is stopped past 240 characters. Answers are cached per (app, role, label) for the session (elements with no label aren't cached). Moving off the element (8 pt), another element, or letting go cancels the run. `CookieHoverLayer` draws a 1.6 pt ink outline round the frame (trimmed on in 0.3 s, whole under Reduce Motion) and the answer in an ink pill (≤240 pt, 2 lines) beside the hand; `BlueCursorView.handHovers` glides the hand to the element's lower right (beside the pointer for an element over 480×240); everything fades in 0.15 s and is click-through. Settings → Shortcuts: "Explain what's under the pointer" (`CK.Key.hoverExplain`, on) and "Read hover answers aloud" (`CK.Key.hoverExplainAloud`, off; never over a reply in progress).

**3D scenes**: for a physical thing whose shape matters, the model writes `[SCENE {json}]` (`CookieScene`, parts built from primitives, never code). A reply with a scene shows no card. `CookieScenePresenter` shows it at the tag on the speech clock and reveals each labelled part's label over the following sentence (Reduce Motion: all at once, no spin, explode without motion); `explode` moves parts out from the centroid (×1.6) 0.6 s after it appears. The panel (`CookieCardPanel`, placed by `CookieCardPresenter.frame`) ignores the mouse except while the pointer is over the card; then `DragGesture` turns the model and scroll zooms the camera. Labels are SwiftUI, projected each frame from a `SceneEvents.Update` subscription (run in place on the main thread, handed to it from any other) with `RealityViewCameraContent.project(point:to: .local)`, because RealityView attachments are visionOS-only. The view's background style is the paper, so the card looks the same whether or not RealityView composites transparently. Dismissed like a card (Escape, a click elsewhere, the next turn, 45 s since the last beat or touch); the RealityView and entities are released with the panel.

**Faces**: `characterMood` adds `.sleeping` after an idle hour (`isDozing`); `gazeTowardPointer` turns the eyes toward what Cookie points at; listening eyes look at the person. Pressing the hotkey while Cookie speaks stops speech and listens (push-to-talk is the interrupt; there is no open microphone).

**Sounds**: `CookieSounds` plays macOS's own UI sounds for home open/close (screen-recording start/stop), send (Messages), done (Apple Pay) and listen (mic unmute), read from the system at runtime with a synthesized tone as fallback, and synthesizes a water-drop bloop/plop for the notch peek opening/closing. The General setting "Sounds" (`CK.Key.sounds`, default on) silences them. Ship Cookie's own recordings before a public release.

**Unsent Drafts**: `CompanionManager` owns `CookieDraftStore`, shared by notch and pop-out views. Text and attachments stay with their conversation across view dismissal, navigation and screen changes. New-chat drafts follow the first created thread; deleting chats clears their drafts. Unsent content stays in memory only.

**One Cookie**: `CookieAPI` calls `/v1/projects/{p}/cookie/…` (overview, jobs, `runs/{id}/stream` through a one-use `POST /v1/stream-tickets`, drafts, approvals, routines, chases, prefs with the IANA zone, soul, speech) on Enkeon (`https://api.thinkingroot.com`, the account token; the sign-in asks for the `cookie` scope; `cookie_scope`/`cookie_sign_in` show "Sign in again", `cookie_not_member` signs out) or, signed out, on `LocalCookiePage`: `Contents/Helpers/cookie page <Application Support/Cookie/page/files> --model … --home Application Support/Cookie/page --port <free>` with the chats' model environment, started on first use (never from a peek hover), restarted when the model or keys change, stopped at quit. Routines by voice: the `make_routine` tool (outbound, `job` guarded) takes days and an HH:MM time; after the card's yes, Cookie's own go one per weekday to `POST …/cookie/routines` on whichever backend is in use, so the web board lists them too (400 / 404 Cookie off / 409 twenty already are told in plain words; the same active routine asked again is returned, not doubled). Neither backend's routines name a Cookie, so a named Cookie's routines (`CookieRoutine`, by voice in its chat or in its editor) stay on the Mac's scheduler (`CookieBackgroundRuns`) and show on the Board as "<name>, on this Mac only" with Remove. Each routine is scheduled in exactly one place.

**Board**: One page replaces Today, Work and Lists. `BoardView` is a single feed over the graphite surface: a "Give Cookie a job" field, then Needs you, Cookie's on it, Waiting, Routines, then each imported list as a Not-started group (rows start work through a Start menu or open the work they already began), then Finished folded away; an empty section is hidden. Cookie's rows from `CookieAPI` (drafts to send or skip, approvals, questions to answer, routine offers; live jobs with Stop; follow-ups; routines to pause or resume; finished answers) lead each section and are the same list as the web page; the board is read on show and every 30 s while open. The peek's Now row shows what Cookie's API says needs you before work counts. Rows move by their stage menu, context menu, or by dragging onto a section; narrow widths drop the stage menu and stack the actions. New work stays an inline page (`CookieNewWorkView`), never a dimming sheet, and `CookieNavigation` owns `CookieWorkDraft` so folding the notch preserves it. Work items continue through `WorkStore` and its sealed local persistence/Enkeon plan mirroring; lists through `ListStore` (CSV import lives on the Board). There is no kanban, table or separate lists page.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background. While pressed, a 0.12 s watchdog reads the keys' physical state so a dropped release ends the press; circle select's recovered release goes through the monitor too. A tap disabled by timeout or user input is re-enabled without cancelling the reply.

**Streamed voice**: `CookieSpeaker.beginReply` opens the reply's voice (the socket was opened on key-down by `prepare()` when it can be); `update(text)` takes the reply so far from each text delta, `toolStarted()` flushes (or, with nothing said yet, says "One moment." aside from the reply), `finishReply` sends the rest and `waitUntilDone` returns when it has been heard. `CookieSpokenStream` releases whole words only and holds anything from a "[" that may still be a tag; each tag settles (its offset in the spoken words final) once words follow it and goes to `onTags`, where POINT, DRAW and FOCUS are resolved and put on the clock while the reply is still being written (READ, CARD and SCENE when it is done). The first clause is flushed early (`holdsFirstClause`), then the voice's own schedule batches. ElevenLabs' alignment is per chunk: `CookieAlignmentMapper` maps its characters back onto the sent text (whitespace loose, a few characters' lookahead), `CookieAudioTimeline` keeps audio time across gaps where a chunk came late, `CookieCharacterTimes` gives the clock absolute character times; `alignment`, never `normalizedAlignment`. A socket that closes idle mid-reply reopens; any other failure hands the rest to this Mac's voice from the word being heard, and the clock carries on. Words written after a tool round start on a new line (`HarnessClient`).

**Speech Clock**: `CookieSpeaker.clock` (`CompanionManager.speechClock`) is fed by the streamed character times against the player position (~60 Hz) or by the Mac voice's `willSpeakRangeOfSpeechString` (each sentence's utterance moved by its place in the reply). Offsets are UTF-16 into the spoken text, which grows while it is spoken (`setText`). `schedule(atOffset:)` runs work when speech reaches it; schedule after `beginReply`. Reply progress reads the clock. The voice id lives in UserDefaults (`cookie.elevenlabs.voice`), the key in the Keychain.

**Voice Lifetime and Cancellation**: `CookieSpeaker.speakText` (one line, the same stream) and `waitUntilDone` are asynchronous through the stream and actual playback completion, using speech/audio delegates. `CompanionManager` stays processing while voice is prepared and responding until playback ends; only then does a spoken reply become a compact notice. The compact/expanded composers, closed notch and cursor overlay reflect that shared state. Stop and global Escape cancel dictation, pending captures, model work and playback. An escaped hotkey must be released before it can start again. Session identifiers reject late transcription and playback callbacks.

**Screen Selection Responsiveness**: Circle selection releases its mouse tap on key release, Escape, tap failure or permission loss; a watchdog checks physical shortcut state in case a release event is missed. Cookie controls remain clickable, trail points are bounded and selection callbacks run outside the event-tap callback. Vision redaction/JPEG work runs off the main thread, with the privacy filters retained. Vision's accurate text model loads cold in 13–28 s on an M4 and sometimes fails (e5rt error 13, after which every accurate call in the process fails), ~0.15 s warm: `CookieVisionText` warms it once at launch off the main thread and every screenshot read (redactor, reading pen) uses accurate only once it is ready, else fast; an accurate failure, or a warm-up past 40 s, leaves the app on fast. The redactor fails closed: with "hide secrets" on, a picture whose text can't be read at all is not sent — the whole-screen look becomes a refusal ("Couldn't check the screenshot for private details, so it wasn't sent"; Cookie answers from the words), a circled area is left out with a step saying so, a hover crop isn't attached. Face detection failing alone sends the text-checked picture and adds a step. Capture deadlines also stop waiting immediately on cancellation. Neither cancelled capture results nor late audio downloads may restart a turn.


**Transient Cursor Mode**: When "Show Cookie" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `CookieApp.swift` | ~100 | Menu bar app entry point; wires notch, status menu and first-run setup; reopening routes to the appropriate surface. |
| `CompanionManager.swift` | ~1540 | Central voice/chat state machine. Owns dictation, shortcuts, captures, model replies, speech and overlays; coordinates cancellation and keeps responding active through audio completion. |
| `MenuBarPanelManager.swift` | ~75 | Status item (the Cookie creature rendered via `ImageRenderer`, coloured, not a template) opens the notch; native secondary menu routes Settings, shortcuts, setup replay and Quit. |
| `CookieSetupController.swift` | ~75 | First-run/replay window lifecycle, app activation and completion routing. |
| `CookieSetupState.swift` | ~45 | Resumable setup progress and completion state, isolated for tests. |
| `CookieSetupView.swift` | ~350 | Graphite setup wizard and shared permission rows, with optional access and adaptive scrolling. |
| `CookiePermissions.swift` | ~190 | Current authorization, serialized explicit requests, Settings recovery and local screen verification; injectable OS provider for tests. |
| `OverlayWindow.swift` | ~1300 | Full-screen transparent overlay hosting Cookie's pointer, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, fade-out transitions; `CookieHand` (visits, `act` show-then-do), the guided step's hand, badge and pill, the press ripple. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `ChatCompanionAvatar.swift` | ~245 | The one Cookie creature (nil identity) used by the home header, greeting, notices and the menu bar icon. Opt-in idle expressions and active moods pause when hidden or Reduce Motion is enabled. |
| `CookieCompanionMotion.swift` | ~25 | Pure, testable idle breathing, blinking, gaze and hover poses for the main Cookie character. |
| `CookieAgents.swift` | ~240 | Named Cookies (name, role, detail, kind, apps, routines), `CookieRoutine` cadences parsed from a sentence, JSON draft parsing, sealed store; only Cookie ships. |
| `CookieNewAgentView.swift` | ~190 | Connects the New Cookie conversation, voice controls and profile editor to shared navigation and agent persistence. |
| `CookieCreationSession.swift` | ~135 | Navigation-owned creation draft, cancellable conversation/speech requests and Unicode-safe spoken text reveal. |
| `CookieCreationPresentation.swift` | ~295 | Responsive Imagine / Meet surface, animated character, playback-led text and unified voice/type composer; isolated from audio and persistence for previews. |
| `CookieCreationSession.swift` | ~130 | The New Cookie conversation's state: lines, draft, speech progress, cancel-safe requests. |
| `CookieCreationPresentation.swift` | ~300 | The New Cookie surface: creature, spoken line reveal, hold pill, borderless typed line, buttons. |
| `CookieMac.swift` | ~1020 | `MacOperator`: Cookie's Mac tools (start_task, look, press, set_value, type_text, key, scroll, drag, choose_menu, click_at, run_script, point_at, wait_for_step), the task grant, rate limit, risky-word and blocked-app rules, Esc stop, action log; the hand's cue before each action and guided steps. |
| `CookieWriting.swift` | ~105 | Write grants per app, typed-draft record, correction summaries. |
| `CookieBackgroundRuns.swift` | ~175 | Up to three background Cookies (routines, watchers, hand-offs, meeting follow-ups), the scheduler, the `hand_off` tool. |
| `CookieTeach.swift` | ~230 | Teach by doing: event-tap recorder, SKILL.md writer, merged skills folder. |
| `CookieScreenMemory.swift` | ~125 | OCR of what Cookie looked at, kept a day, the `recall_screen` tool. |
| `CookieMarks.swift` | ~250 | DRAW tag bodies into marks (with their spoken offset), the per-display resolver with AX snapping; `readSeconds` marks a reading-pen line. |
| `CookieReadingPen.swift` | ~270 | READ tags: the words found in the app's text (AX value + bounds per line) or the screenshot (Vision), the nearest match to the pointer, one timed underline per line; `Folded` matching. |
| `CookieHover.swift` | ~380 | Hover to explain: the ⌥⇧ shortcut, the element read under the pointer (with refusals), the quick model question and cache, the outline and pill layer. |
| `CookieSpotlight.swift` | ~140 | FOCUS tags, their resolved region, and the dim with a soft rounded cut-out on each overlay. |
| `CookieReplyTags.swift` | ~125 | Splits a reply into the spoken text and its inline tags (NEXT, DRAW, READ, FOCUS, POINT, CARD, SCENE, LOOK), each with its UTF-16 offset in that text; `[KIND:body]` and `[KIND {json}]`. |
| `CookieInk.swift` | ~450 | Cookie's pen: Rough.js line/ellipse perturbation and perfect-freehand outlines ported to Swift (MIT, see THIRD_PARTY_NOTICES.md); strokes reveal by prefix. |
| `CookieCards.swift` | ~280 | Explainer cards from `[CARD {json}]`: the closed catalog (timeline, steps, flow, list, compare, number) as strict Swift types (an unknown kind, extra field or over-long text drops the card, never the reply), flow ranks, and each element's place on the speech clock across the sentence after the tag. |
| `CookieCardView.swift` | ~670 | The card in Cookie's paper-card language with `CookieInk` rules, rings, boxes and arrows, element by element (whole under Reduce Motion); the presenter floats one at a time beside the notch or the marks, click-through except its close control, dismissed by Escape, a click elsewhere, the next turn or 45 s. |
| `CookieScenes.swift` | ~185 | 3D scenes from `[SCENE {json}]`: title, up to 24 named parts (box, sphere, cylinder, cone, capsule — no torus, RealityKit has no generator for it on macOS 15) with size, position, rotation, palette colour and cut; explode, spin. Strict: an unknown field, shape or colour, or a number that isn't finite or is past 10 drops the scene, never the reply. Bounds, explode placement and label beats on the speech clock. |
| `CookieSceneView.swift` | ~520 | The scene in RealityKit's `RealityView` (macOS 15) on the card's paper: PBR parts, a studio image-based light made in code plus two directional lights, camera framed from the scene's bounds; labels as SwiftUI pills with inked leader lines at `project(point:to:)` points each frame; drag turns, scroll zooms, spin, explode. The presenter places it like a card, click-through until the pointer is over it, releases the RealityView on dismiss. |
| `CookieMarksLayer.swift` | ~370 | Inks marks on each overlay as they're revealed: one Canvas, display-link frames at the screen's top rate, labels, notes and numbers; the reading pen's highlighter at the voice's pace. |
| `CookieAgentDock.swift` | ~185 | Fixed floating panel of background Cookies (never the foreground reply), background-run routing, animated hit regions and pointer/keyboard dismissal. |
| `CookieDockPresentation.swift` | ~235 | One clipped face-to-card surface, shared voice indicator, inline activity and controls; native previews isolated from voice execution. |
| `CookieDockInteraction.swift` | ~65 | Testable dock hover intent, screen geometry and rounded pointer containment. |
| `CookieSounds.swift` | ~130 | System UI sounds with synthesized fallback, plus water-drop peek sounds, behind the Sounds setting. |
| `CookiePeek.swift` | ~410 | Status, Latest and Up next presentation, shared compact layout measurements and quick-question composer with isolated callbacks for previews. |
| `NotchIsland.swift` | ~815 | Notch panel lifecycle, clipped spring transitions, hover intent, screen geometry, voice status/Stop, notices and adaptive pop-out window. |
| `CookieHome.swift` | ~205 | Shared notch/window home, responsive sidebar drawer and file preview layout. |
| `CookieAPI.swift` | ~600 | One Cookie API over Enkeon (signed in) or `cookie page` on this Mac (signed out): board overview, jobs, live streams, drafts, approvals, routines, prefs, soul, session, speech; `LocalCookiePage` lifecycle; `make_routine` (routines by voice). |
| `CookieWork.swift` | ~415 | Work items, stage transitions, sealed local persistence and Enkeon plan mirroring (kept: work items exist only on the Mac, and the plan memories are how AI tools see them). |
| `CookieBoardView.swift` | ~640 | The Board: Cookie's API rows leading each stage, your work by stage, routines, imported lists as not-started groups, finished folded, CSV import, drag onto a stage; empty stages hidden. |
| `CookieWorkEditor.swift` | ~260 | Inline creation, work detail, optional dates, files and activity; no modal backdrop. |
| `CookieWorkPresentation.swift` | ~180 | Navigation-owned work draft, page padding, search and shared work controls (stage label/menu, buttons, headings, empty state). |
| `CookieNavigationViews.swift` | ~385 | Shared sidebar, settings navigation and chat rows with isolated callbacks for native previews. |
| `CookieSettings.swift` | ~595 | Settings pages with a shared header and card layout, accessible native switches and flexible model fields. |
| `CookieChat.swift` | ~510 | Conversation, messages, approvals, file drops and Quick Look preview. |
| `CookieComposer.swift` | ~430 | Unified voice-first composer, expanding text field, attachment chips and separate stop control. Shares the voice medallion and phase with the compact notch; audio callbacks are isolated for native previews. |
| `CookieInteractionState.swift` | ~75 | Testable hover timing and screen/sidebar/preview geometry. |
| `CookieDraftStore.swift` | ~50 | In-memory per-conversation text and attachment drafts independent of views. |
| `CookieCaptureShield.swift` | ~90 | "Hide from screen sharing": `sharingType = .none` plus the private `CGSSetWindowCaptureExcludeShape` (dlsym) on every Cookie window, re-applied on show and resize. Best effort. |
| `CompanionScreenCaptureUtility.swift` | ~200 | Multi-monitor and region capture using ScreenCaptureKit. Redacts and encodes off the main thread; checks cancellation before images can be sent. |
| `CircleSelect.swift` | ~365 | Shortcut-held region selection, bounded animated trail, input-release watchdog and immediate Escape cancellation. |
| `CookieSafety.swift` | ~470 | Capture guards, cancellation-aware deadlines, local redaction (fails closed: `Redactor.Unchecked`), sealed chats and chat lock. |
| `CookieVisionText.swift` | ~95 | The one screenshot text recognizer: accurate model warmed at launch, fast until ready or after it fails. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — Apple Speech or OpenAI. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~190 | System-wide push-to-talk and Escape monitor (also publishes the hover-to-explain keys). Publishes press/release/cancel, recovers missed releases from the keys' physical state, and prevents an escaped held shortcut from restarting. |
| `CookieSpeaker.swift` | ~810 | The streamed voice: one reply at a time (`beginReply`/`update`/`toolStarted`/`finishReply`/`waitUntilDone`, `speakText` for one line), key-down `prepare()`, fallback to the Mac's voice from the word being heard; `CookieCloudVoice` (stream-input socket through Enkeon's relay or ElevenLabs, PCM into `AVAudioEngine`, alignment onto the clock) and `CookieMacVoice` (`AVSpeechSynthesizer` per sentence); the account's voice list. |
| `CookieSpeechStream.swift` | ~190 | Pure streaming arithmetic: `CookieSpokenStream` (whole words out, tags held and settled with their offsets, first-clause flush), `CookieAlignmentMapper`, `CookieAudioTimeline`, `CookieCharacterTimes`. |
| `CookieTurnTiming.swift` | ~75 | One log line per turn (`⏱ turn …`): key held, transcript, capture (redaction's share), request sent, first token, first words to the voice, first audio, done, tool rounds — seconds after the key-up (or the send). Numbers only, never content. |
| `CookieSpeechClock.swift` | ~120 | The one speech clock both voices feed: the UTF-16 offset being heard now and work scheduled at an offset (runs on reach, all on finish, none on stop). |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `CookieAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |

## Build & Run

```bash
# Build Cookie.app with the Command Line Tools (no Xcode). build.sh builds the
# harness (--features bedrock) itself; build the helpers first or they are left out
# (README.md, "Build"): cookie-tools, cookie-recorder, scripts/bundle-python.sh.
./build.sh

# Run the native checks
python3 scripts/check_cookie_interactions.py

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

Interaction and setup regression checks use Command Line Tools without XCTest or `xcodebuild`. Permission tests use an injected fake provider and never modify macOS grants. Add `--render` to inspect native UI previews:

```bash
python3 scripts/check_cookie_interactions.py
```

The checks cover interactions, setup, work presentation, peek presentation, voice flow, Cookie creation and the feature set (place-bound routing, routines, write grants, corrections, taught skills, screen memory, faces).

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
