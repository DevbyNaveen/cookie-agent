import AppKit
import simd

/// Lessons from the screen: which phrases make one (and which never do: "rotate the PDF"); where the
/// picture comes from and what it's refused for; the planner's examples parse with the real SCENE and
/// CARD readers and name only their fields; the new spoken and [VISUAL:…] commands; the stage's eased
/// turn, spin bounds and label toggle; the honest fallback; and a lesson phrase with a fake capture
/// becoming a request that carries the picture and the planner.
@MainActor
enum CookieLessonFromScreenTests {
    final class Fake {
        var window: CGRect? = CGRect(x: 100, y: 100, width: 1200, height: 800)
        var pointer = CGPoint(x: 700, y: 500)
        var screenAllowed = true
        var refusal: String?
        var front: CookieLayerTarget? = CookieLayerTarget(pid: 42, app: "Preview", bundleID: "com.apple.Preview", category: nil)
        var captured: [CGRect] = []
        var capture: (CGRect) throws -> CompanionScreenCaptureUtility.RedactedJPEG? = { _ in (data: Data([1, 2, 3]), hiddenItems: 2, seconds: 0.01) }

        var environment: CookieLessonEnvironment {
            CookieLessonEnvironment(
                frontApp: { [unowned self] in self.front },
                windowFrame: { [unowned self] _ in self.window },
                displayFrame: { _ in CGRect(x: 0, y: 0, width: 1440, height: 900) },
                pointer: { [unowned self] in self.pointer },
                refusal: { [unowned self] _ in self.refusal },
                screenAllowed: { [unowned self] in self.screenAllowed },
                capture: { [unowned self] rect in self.captured.append(rect); return try self.capture(rect) })
        }
    }

    static func run() async {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }

        // MARK: Routing
        typealias Row = (text: String, selection: Bool, circled: Bool, gesture: Bool, spoken: Bool, visual: Bool, expected: CookieLessonSource?)
        let table: [Row] = [
            ("Show me this in 3D", false, false, true, true, false, .pointer),
            ("Can you explain this visually?", false, false, true, false, false, .window),
            ("Make a model of this", false, true, true, true, false, .circle),
            ("make a model of photosynthesis", false, true, true, true, false, nil),
            ("Explain this in 3D", true, false, false, false, false, .selection),
            // "Break it down" and "walk me through this" keep their old routes (guided teaching): no picture.
            ("Break this down", true, false, false, false, false, nil),
            ("Walk me through this.", false, false, true, true, false, nil),
            ("break it down for me", false, false, true, true, false, nil),
            ("Show me this as a model", false, false, true, true, false, .pointer),
            ("Make a model of this", false, false, true, true, false, .pointer),
            ("what's the business model of this company", false, false, true, true, false, nil),
            ("Show me that in 3-D", false, false, true, true, true, .pointer),
            ("Explain photosynthesis visually", false, false, true, true, false, nil),
            ("Walk me through setting up git", false, false, true, true, false, nil),
            ("explain this visually", false, false, false, false, false, nil),
            ("Rotate the PDF", false, false, true, true, false, nil),
            ("rotate the pdf left", false, false, true, true, true, nil),
            ("What does this part do?", false, false, true, true, true, nil),
            ("Break it down", false, false, true, true, true, nil),
            ("Show me this in 3D", false, false, true, true, true, .pointer),
        ]
        for row in table {
            check(CookieLessonFromScreen.source(row.text, selection: row.selection, circled: row.circled, screenGesture: row.gesture,
                                                spoken: row.spoken, visualShowing: row.visual) == row.expected, "routing: \(row.text)")
        }
        // "Rotate the PDF" with no model up is an ordinary request, never a lesson or a model command.
        check(CookieRequestMode.choose("Rotate the PDF", selection: false, visual: false) != .lesson, "rotate the PDF is not a lesson")
        check(CookieLessonVoice.command("Rotate the PDF") == nil && CookieLessonVoice.command("rotate the pdf to the left") == nil,
              "rotate the PDF is not a model command")
        // A follow-up on the model stays a lesson, with the model as context.
        check(CookieRequestMode.choose("What does this part do?", selection: false, visual: true) == .lesson, "follow-up stays a lesson")
        check(CookieRequestMode.choose("spin it slower and tell me why", selection: false, visual: true) == .lesson, "longer spin request goes to the model as a lesson")

        // "Faster" and "turn it" are the model's only while it's open and was just used.
        check(CookieLessonIdle.inUse(collapsed: false, idle: 5) && !CookieLessonIdle.inUse(collapsed: true, idle: 5)
              && !CookieLessonIdle.inUse(collapsed: false, idle: CookieLessonIdle.collapseAfter), "folded or left alone, a model takes no commands")
        let manager = (try? String(contentsOfFile: "Cookie/CompanionManager.swift", encoding: .utf8)) ?? ""
        check(manager.contains("scenePresenter.inUse, let command = CookieLessonVoice.command(transcript)")
              && manager.contains("visual: scenePresenter.inUse || cardPresenter.inUse"), "the voice path asks whether it's in use")
        // Typed, a reply's [VISUAL:…]/[TEACH:…] wait for its own card or model to show, then act on it.
        let typedQueue = manager.range(of: "else { typedVisuals.append(change) }"), shown = manager.range(of: "if let scene { scenePresenter.showNow(scene, near: cardRegion) }"),
            applied = manager.range(of: "typedVisuals.forEach { $0() }")
        check(typedQueue != nil && shown != nil && applied != nil && shown!.upperBound < applied!.lowerBound && !manager.contains("else { change() }\n                    }\n                    if speakReply {"),
              "a typed reply's visual verbs run after its card or model is up, not before")

        // MARK: Commands
        let bodies: [(String, CookieVisualCommand?)] = [
            ("explode", .explode), ("show-all", .showAll), ("zoom-out", .zoomOut), ("rotate-left", .rotate(degrees: -45)),
            ("Rotate-Right", .rotate(degrees: 45)), ("turn-around", .rotate(degrees: 180)), ("rotate:-90", .rotate(degrees: -90)),
            ("rotate: 30", .rotate(degrees: 30)), ("spin", .spin(.start)), ("spin-faster", .spin(.faster)), ("spin-slower", .spin(.slower)),
            ("stop-spin", .spin(.stop)), ("label-all", .labels(shown: true)), ("hide-labels", .labels(shown: false)),
            ("rotate:0", nil), ("rotate:720", nil), ("rotate:nan", nil), ("rotate:abc", nil), ("spin-sideways", nil), ("delete", nil),
        ]
        for (body, expected) in bodies {
            check(CookieVisualCommand(tag: CookieReplyTag(kind: "VISUAL", body: body, offset: 0)) == expected, "VISUAL:\(body)")
        }
        check(CookieVisualCommand(tag: CookieReplyTag(kind: "TEACH", body: "explode", offset: 0)) == nil, "only VISUAL tags are commands")
        let tagged = CookieReplyTags.split("Now [VISUAL:rotate:-90] the back [VISUAL:label-all] shows.")
        check(tagged.tags.compactMap(CookieVisualCommand.init(tag:)) == [.rotate(degrees: -90), .labels(shown: true)], "commands parse from a reply")
        let spoken: [(String, CookieVisualCommand?)] = [
            ("Rotate left", .rotate(degrees: -45)), ("Please turn it to the right.", .rotate(degrees: 45)),
            ("rotate the model left a bit", .rotate(degrees: -45)), ("Turn it around", .rotate(degrees: 180)),
            ("show me the back", .rotate(degrees: 180)), ("rotate it 90 degrees to the left", .rotate(degrees: -90)),
            ("Rotate by 30 degrees", .rotate(degrees: 30)), ("Spin faster", .spin(.faster)), ("slower", .spin(.slower)),
            ("Stop spinning.", .spin(.stop)), ("hold it still", .spin(.stop)), ("spin it", .spin(.start)),
            ("Label everything", .labels(shown: true)), ("label all the parts", .labels(shown: true)),
            ("Hide labels", .labels(shown: false)), ("hide the labels please", .labels(shown: false)), ("don’t spin", .spin(.stop)),
            ("rotate it and tell me about the fan", nil), ("turn left at the next light", nil), ("rotate 900 degrees", nil),
            ("explode", nil), ("label this column", nil),
        ]
        for (text, expected) in spoken {
            check(CookieLessonVoice.command(text) == expected, "spoken: \(text)")
        }

        // MARK: Stage rotation, spin and labels
        let lessonScene = CookieScene(tag: CookieReplyTags.split(CookieLessonFromScreen.instruction(.pointer, pictured: true)).tags
            .first { $0.kind == "SCENE" && CookieScene(tag: $0)?.title == "Centrifugal pump" }!)!
        check(abs(CookieSceneStage.eased(0)) < 1e-6 && abs(CookieSceneStage.eased(1) - 1) < 1e-6 && abs(CookieSceneStage.eased(0.5) - 0.5) < 1e-6,
              "easing starts at 0, ends at 1, passes the middle")
        check(CookieSceneStage.eased(0.1) < 0.1 && CookieSceneStage.eased(0.9) > 0.9 && CookieSceneStage.eased(2) == 1,
              "easing is slow at both ends and clamps")
        let front = SIMD3<Float>(0, 0, 1)
        func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { simd_length(a - b) < 1e-3 }
        check(close(CookieSceneStage.yawed(simd_quatf(angle: 0, axis: [0, 1, 0]), degrees: 90, progress: 1).act(front), [1, 0, 0]),
              "positive degrees bring the front to the right")
        let stage = CookieSceneStage(scene: lessonScene, reduceMotion: false)
        let start = stage.turn
        stage.apply(.rotate(degrees: 90))
        check(close(stage.turn.act(front), start.act(front)), "a spoken turn starts where the model is")
        let seconds = CookieSceneStage.turnSeconds(90)
        stage.step(seconds / 2)
        check(close(stage.turn.act(front), CookieSceneStage.yawed(start, degrees: 45, progress: 1).act(front)), "halfway through it is halfway round")
        stage.step(seconds)
        let ninety = CookieSceneStage.yawed(start, degrees: 90, progress: 1)
        check(close(stage.turn.act(front), ninety.act(front)), "the turn lands exactly 90° round")
        stage.step(1)
        check(close(stage.turn.act(front), ninety.act(front)), "and stays there")
        stage.apply(.rotate(degrees: -45))
        stage.step(CookieSceneStage.turnSeconds(-45) / 3)
        stage.apply(.rotate(degrees: -45))
        for _ in 0..<120 { stage.step(1 / 60) }
        check(close(stage.turn.act(front), start.act(front)), "left, left mid-turn ends 90° back without a jump")
        stage.drag(CGSize(width: 10, height: 0))
        stage.endDrag()
        let dragged = stage.turn
        stage.apply(.rotate(degrees: 45))
        stage.drag(CGSize(width: 0, height: 0))
        stage.endDrag()
        stage.step(1)
        check(close(stage.turn.act(front), dragged.act(front)), "a drag takes over from a spoken turn")
        let still = CookieSceneStage(scene: lessonScene, reduceMotion: true)
        let stillStart = still.turn
        still.apply(.rotate(degrees: 180))
        check(close(still.turn.act(front), CookieSceneStage.yawed(stillStart, degrees: 180, progress: 1).act(front)), "Reduce Motion turns at once")

        var rate = CookieSceneStage.defaultSpinRate
        for _ in 0..<20 { rate = CookieSceneStage.spinRate(.faster, from: rate) }
        check(rate == CookieSceneStage.spinRates.upperBound, "faster stops at the top rate")
        for _ in 0..<20 { rate = CookieSceneStage.spinRate(.slower, from: rate) }
        check(rate == CookieSceneStage.spinRates.lowerBound, "slower stops at the bottom rate")
        check(CookieSceneStage.spinRate(.stop, from: 0.5) == 0.5 && CookieSceneStage.spinRate(.start, from: 9) == CookieSceneStage.spinRates.upperBound,
              "stop keeps the rate; any rate is clamped")
        check(!stage.spinning, "a lesson model starts still")
        stage.apply(.spin(.faster))
        check(stage.spinning && abs(stage.spinRate - CookieSceneStage.defaultSpinRate * CookieSceneStage.spinFactor) < 1e-6, "spin faster starts it a little faster")
        let before = stage.turn
        stage.step(0.5)
        check(!close(stage.turn.act(front), before.act(front)), "spinning turns it")
        stage.apply(.spin(.stop))
        let stopped = stage.turn
        stage.step(0.5)
        check(!stage.spinning && close(stage.turn.act(front), stopped.act(front)), "stop spinning holds it still")
        still.apply(.spin(.start))
        check(!still.spinning, "Reduce Motion never spins")
        check(CookieLessonVoice.note(.spin(.start), rateBefore: 0.35, rateAfter: 0.35, spinning: false, reduceMotion: true, labelled: 4).contains("Reduce Motion"),
              "and says so")
        check(CookieLessonVoice.note(.spin(.faster), rateBefore: 1.6, rateAfter: 1.6, spinning: true, reduceMotion: false, labelled: 4) == "That's as fast as it spins.",
              "the top speed is said honestly")

        let many = CookieScene(title: "Many", parts: (0..<10).map { index in
            CookieScene.Part(id: "p\(index)", label: "Part \(index)", shape: .sphere, size: [0.1], position: [Float(index) * 0.2, 0, 0],
                             rotation: .zero, tint: .sky, cut: false)
        }, explode: false, spin: false)
        let labels = CookieSceneStage(scene: many, reduceMotion: true)
        check(labels.shownLabels == 0 && !labels.allLabels, "labels start unrevealed")
        labels.apply(.labels(shown: true))
        check(labels.shownLabels == 10 && labels.allLabels && !labels.labelsHidden, "label everything shows all ten")
        labels.apply(.labels(shown: false))
        check(labels.labelsHidden && !labels.allLabels, "hide labels hides them")
        labels.apply(.labels(shown: true))
        check(!labels.labelsHidden && labels.shownLabels == 10, "and they come back")
        let size = CookieSceneView.sceneSize
        let rails = (0..<24).map { CookieSceneLabelLayout.centre(index: $0, count: 24, size: size) }
        check(rails.allSatisfy { $0.y >= 0 && $0.y <= size.height } && Set(rails.map { "\($0.x),\($0.y)" }).count == 24,
              "every label of a full model gets its own place inside the view")
        check(CookieSceneLabelLayout.centre(index: 5, count: 6, size: size) == CGPoint(x: size.width - 78, y: size.height - 74),
              "six labels keep their old rails")
        check(CookieLessonVoice.note(.labels(shown: true), rateBefore: 0, rateAfter: 0, spinning: false, reduceMotion: false, labelled: 0)
              == "This model has no labelled parts to show.", "nothing to label is said, not faked")
        // The model in context for follow-ups carries the lesson's parts and its state.
        let context = CookieScenePresenter.teachingContext(labels)
        check(context.contains("p3=Part 3") && context.contains("Labels: shown") && context.contains("Spinning: false"),
              "teaching context names the parts and what the model is doing")
        labels.release(); stage.release(); still.release()

        // MARK: Planner
        let allowedScene = CookieScene.sceneFields.union(CookieScene.partFields)
        // Top-level fields per kind, plus the fields of CookieCard's nested Event, Node, Edge, Column and Step.
        let allowedCard = CookieCard.fields.values.reduce(Set<String>()) { $0.union($1) }
            .union(["label", "when", "id", "icon", "from", "to", "heading", "points", "text"])
        let keyPattern = try! NSRegularExpression(pattern: #""([A-Za-z_]+)"\s*:"#)
        for source in [CookieLessonSource.circle, .pointer, .window, .selection] {
            for pictured in [true, false] {
                let instruction = CookieLessonFromScreen.instruction(source, pictured: pictured)
                let examples = instruction.components(separatedBy: "\n").filter { $0.hasPrefix("Example") }
                check(examples.count == 2, "two worked examples")
                let tags = examples.flatMap { CookieReplyTags.split($0).tags }
                check(tags.compactMap(CookieScene.init(tag:)).count == 1 && tags.compactMap(CookieCard.init(tag:)).count == 1,
                      "the worked SCENE and CARD parse with the real readers")
                let keys = keyPattern.matches(in: instruction, range: NSRange(location: 0, length: instruction.utf16.count))
                    .map { (instruction as NSString).substring(with: $0.range(at: 1)) }
                check(!keys.isEmpty && keys.allSatisfy { allowedScene.contains($0) || allowedCard.contains($0) },
                      "the planner names only fields the readers accept")
                check(instruction.contains("SCENE for a physical") && instruction.contains("CARD for an abstract") && instruction.contains("general knowledge"),
                      "the planner chooses SCENE or CARD and grounds its labels")
            }
        }
        let card = CookieCard(tag: CookieReplyTags.split(CookieLessonFromScreen.instruction(.window, pictured: true)).tags.first { $0.kind == "CARD" && CookieCard(tag: $0) != nil }!)!
        if case .flow(_, let nodes, _, _, _) = card.content {
            check(nodes.map(\.label) == ["main()", "load_user(row)", "row['email']", "KeyError: 'email'"], "the error example is a flow of its cause")
        } else { preconditionFailure("the error example must be a flow") }

        // MARK: Fallback
        let rejected = CookieReplyTags.split(#"[SCENE {"title":"Pump","parts":[{"id":"a","shape":"blob","size":[1],"position":[0,0,0],"color":"steel"}]}]"#).tags
        check(rejected.count == 1 && CookieScene(tag: rejected[0]) == nil, "a scene outside the schema is rejected")
        check(CookieLessonFromScreen.fallbackReason(rejected).contains("didn't pass its checks"), "the fallback says the model was rejected")
        check(CookieLessonFromScreen.fallbackReason([]).contains("words only"), "a reply with no visual says so")
        let status = CookieLessonStatus()
        status.presents = false
        var cancelled = 0
        status.onCancel = { cancelled += 1 }
        status.begin(.pointer)
        check(status.phase == .looking && status.subtitle == "From what you're pointing at", "looking first")
        status.building(.pointer, app: "Preview")
        check(status.phase == .building && status.subtitle == "From what you're pointing at in Preview", "then building your model")
        status.close()
        check(status.phase == nil && cancelled == 1, "Esc while building stops the lesson")
        status.begin(.selection)
        check(status.phase == .building, "a selection lesson has nothing to look at")
        status.fail(CookieLessonFromScreen.fallbackReason(rejected))
        check(status.phase == .failed(CookieLessonFromScreen.fallbackReason(rejected)), "a rejected scene becomes the honest card, not a blank")
        status.close()
        check(status.phase == nil && cancelled == 1, "closing the honest card cancels nothing")
        status.building(.pointer, app: nil)
        check(status.phase == nil, "a dismissed lesson doesn't come back")

        // MARK: Where it looks
        let fake = Fake()
        let box = CookieLessonFromScreen.region(pointer: fake.pointer, window: fake.window, display: CGRect(x: 0, y: 0, width: 1440, height: 900))!
        check(box.size == CookieLessonFromScreen.pointerBox && box.midX == 700 && box.midY == 500, "a box round the pointer")
        let edge = CookieLessonFromScreen.region(pointer: CGPoint(x: 120, y: 120), window: fake.window, display: CGRect(x: 0, y: 0, width: 1440, height: 900))!
        check(edge.size == CookieLessonFromScreen.pointerBox && edge.minX == 100 && edge.minY == 100, "near an edge it slides in, keeping its size")
        check(CookieLessonFromScreen.region(pointer: CGPoint(x: 20, y: 20), window: fake.window, display: nil) == fake.window,
              "pointer outside the window: the window")
        check(CookieLessonFromScreen.region(pointer: CGPoint(x: 150, y: 150), window: CGRect(x: 100, y: 100, width: 300, height: 200), display: nil)
              == CGRect(x: 100, y: 100, width: 300, height: 200), "a small window is taken whole")
        check(CookieLessonFromScreen.region(pointer: CGPoint(x: 10, y: 10), window: nil, display: CGRect(x: 0, y: 0, width: 1440, height: 900))?.origin == .zero,
              "no window: round the pointer on its display")

        // MARK: Wiring: a lesson phrase with a fake capture becomes a request with the picture and the planner
        let phrase = "Show me this in 3D"
        let source = CookieLessonFromScreen.source(phrase, selection: false, circled: false, screenGesture: true, spoken: true, visualShowing: false)!
        let look = await CookieLessonFromScreen.look(source, environment: fake.environment)
        guard case .picture(let data, let hidden, let app, let region)? = look else { preconditionFailure("fake capture must give a picture") }
        check(data == Data([1, 2, 3]) && hidden == 2 && app == "Preview" && region == box && fake.captured == [box],
              "one capture of exactly the pointed region")
        let caption = CookieLessonFromScreen.caption(source, app: app)
        let instruction = CookieLessonFromScreen.instruction(source, pictured: caption.hasPrefix("UNTRUSTED screen"))
        check(caption.hasPrefix("UNTRUSTED screen content") && caption.contains("Preview"), "the picture goes as untrusted screen content")
        check(instruction.contains("LESSON FROM THE SCREEN") && instruction.contains("around the pointer") && instruction.contains("copy every part"),
              "the request carries the planner, grounded in the picture")
        check(await CookieLessonFromScreen.look(.selection, environment: fake.environment) == nil && fake.captured.count == 1,
              "a selection lesson never takes a picture")
        let window = await CookieLessonFromScreen.look(.window, environment: fake.environment)
        if case .picture(_, _, _, let rect)? = window { check(rect == fake.window, "a typed lesson takes the front window") } else { preconditionFailure("window look") }

        // MARK: Refusals
        fake.screenAllowed = false
        check(await CookieLessonFromScreen.look(.pointer, environment: fake.environment) == .refused("Screen access is off"), "no screen permission: said, not looked")
        fake.screenAllowed = true
        fake.refusal = "Cookie doesn't look at 1Password."
        check(await CookieLessonFromScreen.look(.pointer, environment: fake.environment) == .refused("Cookie doesn't look at 1Password."), "a blocked app is refused")
        fake.refusal = nil
        fake.capture = { _ in throw Redactor.Unchecked() }
        check(await CookieLessonFromScreen.look(.pointer, environment: fake.environment) == .refused(Redactor.Unchecked().localizedDescription),
              "a picture that couldn't be checked is never sent")
        fake.capture = { _ in nil }
        check(await CookieLessonFromScreen.look(.pointer, environment: fake.environment) == .refused("Couldn't take a picture of that part of the screen"),
              "an empty capture says so")
        fake.front = nil
        check(await CookieLessonFromScreen.look(.window, environment: fake.environment) == .refused("There's no app in front to look at"), "nothing in front")
        fake.front = CookieLayerTarget(pid: 42, app: "Preview", bundleID: nil, category: nil)
        fake.window = nil
        check(await CookieLessonFromScreen.look(.window, environment: fake.environment) == .refused("Couldn't find Preview's window to look at"), "no window to look at")
        let blind = CookieLessonFromScreen.instruction(.pointer, pictured: false)
        check(blind.contains("couldn't look this time") && !blind.contains("copy every part"), "unpictured lessons are labelled general knowledge")

        print("\(checks) lesson checks passed.")
    }
}
