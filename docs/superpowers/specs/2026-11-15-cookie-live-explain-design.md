# Cookie live explaining: pointing, paper and 3D — design

Date: 2026-11-15. Branch `feat/cookie-explain`, worktree `~/Desktop/cookie-explain`.

## Why

Cookie explains things on the person's real screen while it speaks: the hand points, the pen
draws, a paper card or a 3D model appears. Today each of those is a separate inline tag the
model scatters through its words. The result feels basic and unreliable:

- The hand guesses pixel coordinates off a 1280 px screenshot and often lands wrong or vanishes.
- Paper cards are six static templates that swap instead of change.
- 3D is at most 24 hand-placed primitives; one bad field silently drops the whole scene.
- Nothing moves the way the real thing moves; the camera never directs attention.
- Deep questions get a single fast pass with no research.

Gemini, ChatGPT and Claude (2026) all draw interactive visuals, but inside a chat window. Cookie's
edge is that voice, hand, pen and model happen together on the person's own screen. The bar is a
great teacher at a whiteboard: things transform in front of you, and the voice, the hand and the
picture always mean the same thing at the same moment.

## Global rules (binding for every part)

1. **The model chooses and parameterises; vetted Swift draws.** The model never writes geometry
   code, shader code or simulation code that runs. It picks from libraries and sets numbers.
2. **Forgiving in, strict out.** Inputs are repaired where the intent is clear (clamp into range,
   nearest palette colour, a capsule too short becomes a cylinder, unknown optional field
   ignored), each repair recorded. Only unrecoverable input is rejected, and then with an exact,
   field-level error the model can fix. Nothing is ever dropped silently: if a visual can't be
   shown, Cookie says so in one short line.
3. **Check before showing.** Every 3D model and every paper visual that comes from a tool call is
   rendered off screen first; the model gets the picture back and may fix it once before the
   person sees it.
4. **One timeline.** Every visual action is a beat on the existing speech clock
   (`CookieSpeechClock`, UTF-16 offsets in the spoken text). The hand, pen, camera, highlights and
   motion all ride that clock.
5. **Instant first, rich next.** Something visual appears within about 1.5 s of speech starting
   (a skeleton, the first beat); detail fills in progressively. No spinner-only waits.
6. Privacy and safety as today: `CaptureGuard.refusal()`, `MacSafety.blocked`, `Redactor.redact`
   before any screen data leaves the Mac, `CookieProof.shared` records screen reads, element
   reads, and downloads. No fake data.
7. Reduce Motion: show end states, no camera flights, no particles, no morphs. VoiceOver: every
   visual has a spoken summary and accessibility labels.
8. Performance: 120 Hz where available via display links; 3D stops rendering when hidden or
   idle (existing `CookieLessonIdle` rule); particles capped; no main-thread blocking for AX,
   OCR, rendering-to-image or network.
9. Code style: Swift 5.9, macOS 15 target, Command Line Tools only (no Xcode), no new
   dependencies, small types, plain-English comments in the files' own voice. Tests are
   `@MainActor enum Cookie<X>Tests { static func run() }` registered in
   `CookieInteractionCheckRunner.main()` with the printed line added to
   `mac/scripts/check_cookie_interactions.py`.

## Part 1 — Pointing at real controls (set-of-marks)

**Goal:** the hand lands on the exact control every time there is one.

- Before a voice reply that includes a screenshot, Cookie runs the existing `look` read of the
  front app (`CookieMac.swift`, ids, roles, labels, frames) off the main actor, in parallel with
  the capture, bounded (≤ 400 elements, ≤ 250 ms; on timeout, no marks this turn).
- The screenshot sent to the model gets small numbered tags drawn on visible, actionable
  elements (set-of-marks): legible, colour-contrasted, not covering the element's own label,
  deduplicated when frames overlap, at most ~120 tags, smallest-first collision avoidance.
  The element list (`[id] role "label"`) goes with it as text. Elements in blocked apps are
  never read or tagged.
- New forms: `[POINT:#12]`, `[POINT:#12:label]`, `[POINT:#12:label:screenN]`. `[FOCUS:#12]` and
  `[DRAW:…:#12…]` already exist and now use the same per-turn element set. Pixel forms remain
  for canvases, images and anything without an element.
- A `#id` point resolves straight to the element's frame centre and is anchored with the
  existing `CookieElementAnchor` (follows moves/scrolls, leaves when destroyed). Unknown id →
  falls back to the label through `CookiePointTarget.resolve`; if that fails, Cookie says in one
  short line that it lost the control.
- Prompt: prefer `#id` whenever a tag exists; pixels only for untagged regions.
- Also raise the screenshot long edge to the model's native size (`maxEdge` 1568) when the
  token budget allows, so pixel points are less coarse.

## Part 2 — Reliable 3D through a tool, with check-before-showing

**Goal:** a model never silently disappears and is visually checked before showing.

- New harness tool `build_model` (effect `read`, registered with the other mac tools in
  `HarnessClient.swift`). Input: the scene JSON (Part 3 format). Output: `{ok, id, repairs:[…],
  errors:[…], snapshot}` where `snapshot` is a PNG of an off-screen render from the default
  camera, plus an exploded view when `explode` is set. The model may call it again with fixes
  (at most twice more per turn).
- The reply then shows it with `[SCENE:#model-id]` at the word where it should appear. The inline
  `[SCENE {json}]` form keeps working (same lenient parser) for compatibility.
- Lenient parser per Global rule 2, returning `(scene, repairs, errors)`.
- If a reply references an unknown model id, or parsing fails, Cookie says "I couldn't build that
  model" in one line instead of nothing.
- Workspace scenes (`CookieWorkspace` kind `scene`) use the same parser and return the same
  field-level errors.
- Off-screen render: RealityKit content rendered to an image off the main thread where the API
  allows, bounded to 2 s; on failure the tool still returns `ok` with `snapshot: null` and says so.

## Part 3 — Parts library and procedural meshes

**Goal:** models look like real machines, not stacks of cylinders.

Part shapes (all generated in Swift with `MeshDescriptor`/`MeshResource.generate(from:)`,
proper normals and UVs, sensible segment counts, cached by parameters):

- primitives: box (with optional corner radius), sphere, cylinder, cone, capsule, torus
- `gear` (teeth, module/radius, thickness, bore), `bevelGear`, `rack`
- `shaft` (radius, length, optional steps), `bearing`
- `bladeRing` (blade count, hub/tip radius, twist degrees, thickness) — fans, compressors, turbines
- `spring` (coils, radius, wire radius, length), `pipe` (path points, radius, bend radius),
  `tube` (outer/inner radius, length)
- `piston`, `crank`, `rod`, `valve`, `wheel`, `propeller`, `screw`
- `lathe` (a 2D profile spun about y), `extrude` (2D outline + depth, optional holes),
  `sweep` (a 2D circle/rect section along a path)
- `arrow`, `label` (text in 3D is not used; labels stay SwiftUI overlays)

Materials: an expanded palette (amber, cream, graphite, sky, mint, rose, steel, glass, copper,
brass, rubber, plastic-white, carbon) with physically based roughness/metalness per tint, plus
finishes `matte | satin | polished` and `cut` (see-through cutaway). Limits rise to 64 parts;
`group` lets parts be explode/isolate/move together.

## Part 4 — Motion, flow and a cinematic camera

**Goal:** the machine works in front of you.

- `joints`: `{"id","kind":"spin|slide|crank","part","axis":[x,y,z],"rate"}`;
  `drives`: `{"from","to","ratio"}` (gear trains, belts), and slider-crank links
  (`crank` → `rod` → `piston`) solved analytically each frame so linked parts move correctly.
- `flows`: particles along a path through named parts (`{"id","through":["fan","comp",…],
  "color","speed","density"}`) for air, fuel, blood, current; capped particle count,
  implemented with RealityKit particles where available on macOS 15 or with instanced
  small spheres on a path otherwise.
- Camera: per beat it frames the named part(s) with an eased, velocity-continuous move (reuse the
  `CookieSpring2D` approach in 3D), orbit-to-reveal, and returns to the overview. Soft contact
  shadow under the model; studio IBL already present.
- X-ray: `cut` parts render translucent with a rim/edge highlight; `isolate` fades others.
- Run/stop, slow-motion, step: new `[VISUAL:…]` verbs (below).

## Part 5 — The director: beats on one timeline

**Goal:** voice, hand, pen, camera and motion are choreographed, not scattered.

- A scene (or card) may carry `beats`: an ordered list of
  `{"at":"exact phrase from the spoken words","do":[actions]}`. Actions:
  `focus:<part>` (camera + highlight + hand), `explode`, `assemble`, `isolate:<part>`,
  `show-all`, `run`, `stop`, `slow`, `flow:<id>:on|off`, `label:<part>`, `cut:<part>:on|off`,
  `view:front|side|top|overview`, `card:<element-id>` for paper.
- `at` phrases are matched against the spoken text (folded like `CookieLabelMatch`) to get speech
  clock offsets; an unmatched phrase falls back to even spacing after the tag and is reported as
  a repair.
- New inline verbs for ad-hoc use: `[VISUAL:focus:part]`, `[VISUAL:run]`, `[VISUAL:stop]`,
  `[VISUAL:slow]`, `[VISUAL:flow:id:on]`, `[VISUAL:view:side]`, `[VISUAL:cut:part:on]`.
- The hand follows the active part/element on screen; the existing label reveal is driven by the
  same beats.
- Interrupt (Esc or the person speaking) pauses the timeline at its current state.

## Part 6 — Paper v2: living diagrams

**Goal:** paper explains change, not just structure.

- **Morph:** a card with `states` (2–6) transitions between them, animating matched elements
  (same id) to new positions/labels and fading others; driven by beats (`state:<n>`).
- **New kinds:** `chart` (line/bar/scatter from given numbers, with axis labels; values come from
  the conversation or real sources, never invented), `equation` (see below), `layers`
  (stacked architecture), `cycle` (loop of steps), `tree` (hierarchy), `sim` (below).
- **Live controls:** up to 4 sliders on `sim` and `chart` cards, recomputed locally (reuse the
  diagram slider formula engine in `CookieSheet` for chart formulas).
- **Simulation library** (vetted Swift, the model only sets parameters): `orbit` (gravity,
  initial speed), `spring` (mass, stiffness, damping), `pendulum` (length, gravity, angle),
  `projectile` (speed, angle, gravity, drag), `wave` (frequency, amplitude, two-source
  interference), `queue` (arrival and service rate, shows waiting line), `flow` (pipe
  diameter/pressure → speed), `decay` (half-life), `growth` (rate, compounding). Each draws
  in the paper ink style at 60–120 Hz with a fixed-step integrator, pauses when hidden, and
  exposes its current values to the voice.
- **Equations:** a small built-in math typesetter (no dependencies) for a TeX subset: fractions,
  super/subscripts, roots, Greek letters, common operators, sums/integrals with limits, matrices
  up to 3×3; drawn in ink with term-by-term reveal and highlight on beats. Unsupported input
  shows the source plainly, never broken glyphs.
- **Ink quality:** variable-width strokes with pressure taper at start/end, slight hand jitter
  seeded per stroke (stable across redraws), consistent with `CookieInk`.
- `build_visual` tool mirrors `build_model` for cards: validate, repair, render snapshot, return.

## Part 7 — Depth: research, then teach

**Goal:** "explain in depth" gets an actually deep, well-structured answer.

- Intent detection on the request (words like "in depth", "explain how", "teach me", "deep
  dive", "why does", follow-ups that ask for more) or the person's explicit choice selects a
  **deep explain** turn.
- Deep turn: Cookie says a short line immediately ("let me look into that properly"), runs a
  bounded research step (existing web/search/memory tools, ≤ 20 s, real sources only, recorded),
  then answers with the teaching arc: one-line answer → analogy → structure (visual) → how it
  works step by step (beats) → common misconception → recap, with sources available on request.
- Normal questions stay instant.
- Prompt updates across Parts 1–7 are written once, coherently, in the voice prompt in
  `CompanionManager.swift` — not as appended fragments.

## Part 8 — Real-looking models

**Goal:** when the person wants it to look real, it can.

- `build_model` accepts `{"asset":{"url": "https://…usdz"}}` or a local `.usdz` path: downloaded
  (HTTPS only, ≤ 50 MB, 20 s timeout, recorded to Proof) into `~/Library/Application
  Support/Cookie/Models/`, loaded with `Entity(contentsOf:)`, normalised to the scene's scale and
  centre. Named nodes in the file become pointable parts; a file with no named parts can be
  turned and zoomed but Cookie says it can't point at its parts.
- AI-generated meshes (image/text-to-3D services) are not built in: they need a paid account and
  produce one unnamed blob that can't be taught with. Recorded as a deliberate non-goal for now.

## Non-goals

- Running model-written code of any kind.
- Fluid or physical simulation of 3D machines beyond kinematics and particle paths; Cookie must
  not claim it simulates airflow.
- Generated 3D meshes (Part 8 note).

## Order of work

1 → 2 → 3 → 4 → 5 → 6 → 7 → 8, each its own commit on `feat/cookie-explain` with checks green.
Parts 3–5 share the scene format: Part 3 defines the format, Part 4 adds `joints/drives/flows`,
Part 5 adds `beats`. Part 2's lenient parser is extended by each.
