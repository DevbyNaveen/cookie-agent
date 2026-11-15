# Cookie: eight features nobody has — design

Branch `feat/cookie-sota` (worktree `~/Desktop/cookie-sota`). Mac app in `mac/`.

## Why
Every 2026 desktop agent (Claude computer use, ChatGPT desktop, Perplexity Personal Computer, Gemini Spark)
clicks and types. Cookie's edge is what they lack: it lives at the notch and the cursor, it draws on the real
screen, it is voice-first, and Enkeon memory is shared across the person's AIs and team. Each feature below
leans on that edge, and on code Cookie already has.

## Global rules (every feature)
- **Explicit, never ambient by default.** Anything that watches the screen or input is opt-in, off by default,
  visible while running (notch indicator), and stops on Esc. No background screen recording, ever.
- **Honest data.** Every count, card and claim comes from a real source. Empty source → show nothing or say so.
- **Proof.** Every screen read, upload, redaction, Mac action and memory write is recorded in `CookieProof`
  (feature 8). Features 1–7 must call it.
- **Existing safety stays.** `CaptureGuard.refusal()`, `MacSafety.blocked`, `Redactor.redact` before anything
  leaves the Mac, approvals for anything that sends, deletes, pays or publishes.
- **Code style.** Match the files around it: small enums/structs, plain-English comments, no new dependencies.
  One new file per feature where possible; hooks into shared files stay small.
- **Checks.** Each feature adds `Tests/CookieInteractionTests/Cookie<Feature>Tests.swift`, registers it in
  `CookieInteractionCheckRunner.main()`, and adds its "N … checks passed." line to
  `scripts/check_cookie_interactions.py`. `python3 mac/scripts/check_cookie_interactions.py` must pass.
- **Commits.** One commit per feature, user-authored style, no Co-Authored-By line, no push.

## 8. Private by proof — `CookieProof.swift` (foundation, built first)
A local ledger of what Cookie saw, sent, hid, did and remembered, with a live notch meter.
- `@MainActor final class CookieProof: ObservableObject { static let shared }`
  - `enum Kind: String, Codable { case saw, sent, redacted, acted, remembered }`
  - `struct Entry: Codable, Identifiable, Equatable { id: UUID; date: Date; kind: Kind; feature: String;
    app: String?; summary: String; destination: String?; bytes: Int?; hidden: Int }`
  - `func record(_ kind: Kind, feature: String, app: String? = nil, summary: String,
    destination: String? = nil, bytes: Int? = nil, hidden: Int = 0)`
  - `@Published private(set) var entries: [Entry]` — newest first, kept 7 days, max 2,000, stored at
    `~/Library/Application Support/Cookie/proof.json` (atomic write, 0600). Summaries never contain screen
    text, typed text or secrets: only what kind of thing, which app, how much, where to.
  - `func forget(_ id: UUID)`, `func forgetToday()` — removes ledger rows and the matching local copies Cookie
    owns (screen-memory entries from the same minute/app). For data already sent to a model provider the UI
    says plainly it cannot be recalled from there.
  - `var lastMinute: (sent: Int, saw: Int)` for the meter.
- Hooks: screen captures (`CompanionScreenCaptureUtility` capture functions) → `.saw`; redaction results →
  `.redacted` with `hidden` count; `HarnessClient.run` with images → `.sent` (destination = model name,
  bytes = image bytes); `MacOperator.log` → `.acted`; `EnkeonDirect.remember*` → `.remembered`.
- Notch meter: a small dot/pill beside the notch while anything was sent in the last 10 s ("Sent 1 screen ·
  2 hidden"); clicking opens the Proof page.
- Proof page: in Settings → Privacy, a "Proof" list for today (time, kind icon, app, summary, destination),
  "Forget" per row and "Forget today".

## 7. Time machine — `CookieTimeMachine.swift`
Every Cookie change to the person's work gets a receipt with before and after, scrubbable and restorable.
- `struct CookieReceipt: Codable, Identifiable { id; date; app; tool; target: String; before: String?;
  after: String?; file: String?; snapshot: String?; restorable: Bool }`
- Capture: `set_value`, `type_text`, `replace_selection`, dictation insert/correction → AX value before/after
  (bounded 20 KB, secrets masked with `SensitiveText`). `run_script` on Office/iWork with a resolvable front
  document path → copy the file to `~/Library/Application Support/Cookie/snapshots/<id>/` before the script
  runs (max 50 MB per file, 1 GB total, oldest pruned). Ghost actions likewise.
- Restore: text receipts restore only if the field still holds `after` exactly (same verify rule as
  `CookieTextInsertion.undo`); file receipts restore by replacing the file after an approval ("Put
  Budget.xlsx back to 14:02?"), keeping the current version as a new snapshot.
- UI: a "Time machine" section on the Board/console: a horizontal scrubber of today's receipts; selecting one
  shows a before/after diff (word-level for text, name/size/time for files) and Restore.
- Voice: "show me how this looked before Cookie edited it" / "undo what Cookie did to this" → model tool
  `time_machine {action: list|show|restore, id?}` (restore is `outbound` → approval).
- Each receipt also writes a `CookieProof` `.acted` row.

## 4. Second brain cursor — extends `CookieHover.swift`
Hold the hover keys over a name, number or project in any app → a small card at the cursor with what Enkeon
knows, sourced and dated.
- Trigger: existing ⌥⇧ hover hold; new mode when the text under the pointer looks like an entity (a
  capitalised name/phrase, a project/ticket id, an email local-part, an amount with currency). Pure function
  `CookieEntity.extract(from: String, at: Int) -> CookieEntity?` (kind: person, project, number, id).
- Lookup: `EnkeonDirect.recall(query:)` with the entity text, cached 10 min per entity; result trimmed to 3
  statements with date + source id. Nothing found → no card (the normal hover explanation continues).
- Card: compact pill under the cursor, matching `CookieOnScreen` style: entity, up to 3 lines, "from Enkeon".
- Setting: "Memory at your cursor" (default on when signed in to Enkeon). Proof: `.sent` (entity text only,
  destination Enkeon).

## 1. Live screen layers — `CookieLayers.swift`
A smart layer drawn over any app's window, re-anchored as it scrolls. Lenses:
- **Translate**: "translate this page" → each OCR line of the front window gets its translation drawn in place
  (a soft card over the original line, same box).
- **Review**: "check this contract" / "anything risky here?" → model returns flagged spans with a one-line
  reason; drawn as an underline + side note at those spans.
- **Owed**: "who do I owe a reply?" → names on screen matched against Enkeon promises/open Board items; drawn
  as a small badge beside each matched name.
Mechanics:
- Start by voice or the talk shortcut; one lens at a time; front window only; notch shows "Layer: Translate ·
  Esc to stop". Stops on Esc, app switch, or 10 minutes.
- Capture the front window region (`captureRegionAsJPEG` of the AX window frame — redacted), OCR lines with
  boxes (`CookieVisionText.lines`), send only redacted line text (not the image) to the model with a strict
  JSON schema `{items:[{line: Int, text: String, kind: translate|flag|badge, note?: String}]}`.
- Anchoring: items attach to OCR line boxes; every 1.5 s while active, re-OCR locally (no upload) and
  re-match lines by normalised text to follow scroll; lines that leave the window hide their items; new
  unseen lines are batched to the model at most every 4 s.
- Drawing: new `CookieLayerView` inside `BlueCursorView` per screen (click-through overlay that already
  exists), not the 6-mark-limited DRAW path.
- Proof: each upload `.sent` with line count; each local re-OCR `.saw` (coalesced per minute).

## 2. Explain anything as a live 3D lesson — `CookieLessonFromScreen.swift`
Point at anything (an error, a balance sheet, a molecule, a diagram) and say "show me in 3D" / "explain this
visually" → a scene (or a card when 3D doesn't fit) built from what is on screen, explorable by voice.
- Entry: the existing point/screen path; `CookieRequestMode` routes "in 3d", "visually", "as a model",
  "break this down" to `.lesson` with a forced screen look of the pointed region.
- Prompt add-on: a lesson-planner instruction that must pick `SCENE` (physical/spatial things) or `CARD`
  (flow/steps/compare/timeline for abstract things) and ground every part label in visible text.
- New voice commands mapped to `CookieVisualCommand`: "rotate left/right" (adds yaw step to the stage, new
  case `rotate(degrees)`), "slower/faster" spin, "label everything".
- Follow-ups keep the scene ("what does this part do?" → `[TEACH:id]`).
- Checks: routing, new commands parse, scene from screen keeps strict schema.

## 6. Voice canvas — `CookieCanvas.swift`
Think out loud; a diagram grows live as you talk; leave with a deck.
- Start: "start a canvas" (or console button). Hands-free listening (existing hands-free path), notch shows
  "Canvas · listening".
- Every ~6 s of new speech (or on a pause), the transcript delta is sent with the current canvas JSON to the
  model, which returns the next canvas: `{title, nodes:[{id,label,group?}], edges:[{from,to,label?}], notes:[...]}`
  (validated, max 40 nodes). Rendered in the workspace as a `diagram` artifact (existing renderer), updated in
  place with a gentle animation.
- Voice edits: "move pricing under strategy", "delete that", "rename X to Y" → applied by the same update.
- "Make it a deck" → calls cookie-py `make_deck` through the harness with slides derived from the canvas
  groups (title slide + one per group + summary). "Stop canvas" ends listening.
- Proof: each update `.sent` (transcript characters).

## 3. Shadow apprentice — `CookieApprentice.swift`
Cookie notices tasks you repeat and offers to take them.
- Opt-in setting "Notice repeated tasks" (off by default). While on, a listen-only event tap (same pattern as
  `CookieTeach`) records structural steps only: app bundle, AX role + label of pressed controls, menu items,
  key combos. Never typed text (typing becomes a `typed` placeholder), never in blocked apps or secure input.
  Kept 7 days locally in `apprentice.json`, never uploaded.
- Miner (pure, testable): `CookieApprentice.repeats(in: [Step], minLength: 3, minCount: 3) -> [Pattern]` —
  finds repeated contiguous step sequences across sessions (normalised; a session is split by 5 min idle),
  ranks by count × length.
- Offer: at most once per pattern per day, a notch notice "You've done ‘Export → PDF → Mail’ 4 times this
  week. Want Cookie to take it?" → Yes opens the existing teach review with the pattern pre-filled as
  `CookieTeachStep`s (typed placeholders become "ask me" steps), then saves as a taught skill and offers
  scheduling.
- Indicator: notch dot "Noticing" while the tap runs. Proof: nothing is sent; a daily `.saw` summary row.

## 5. Team relay — `CookieRelay.swift`
Hand a half-finished task to a teammate's Cookie with context, steps done and steps left.
- "Hand this to Priya" / Board item → Relay → builds a `CookieRelayPacket {version, from, to, title, brief,
  done:[String], next:[CookieTeachStep|String], memoryRefs:[String], createdAt}`. No screenshots, no secrets
  (SensitiveText masked), the person previews it before it is shared.
- Transport (honest, no new backend): (a) export a `.cookierelay` file (JSON, signed with an HMAC of the
  packet using a per-install key so tampering is detected; shown as "From Naveen's Cookie") that can be sent
  by AirDrop/Slack/Mail; (b) if signed in to Enkeon, also `rememberPlan` it to Enkeon with `owner: <name>` so
  it appears on their Board via existing shared memory. The UI says which of the two happened.
- Receiving: Cookie registers the `.cookierelay` document type; opening one shows the packet, then "Pick it
  up" creates a Board item + a Cookie chat seeded with the brief; `next` steps run only through the normal
  `start_task` approval.
- Proof: export/remember → `.sent` with destination.

## Build order
8 → 7 → 4 → 1 → 2 → 6 → 3 → 5 (foundation first; each later feature records to Proof).

## Out of scope
- Any always-on screen recording; cloud relay service; cross-person live agent chat.
