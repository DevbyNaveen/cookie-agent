import AppKit
import SwiftUI

/// Voice canvas: the model's canvas is taken strictly (dupes, dangling edges, caps, lengths); updates
/// never overlap and coalesce what was said meanwhile, on the canvas's own clock; boxes already placed
/// never move; undo is local; edits are told from ideas; the deck's slides come from the canvas; and a
/// canvas started with a fake microphone and model really becomes a diagram in the workspace.
@MainActor
enum CookieCanvasTests {
    @MainActor final class Fake {
        // The microphone.
        var busy = false
        var recording = false
        var partial = ""
        var power = 0.0
        var partials = true
        var earsError: String?
        var startsWork = true
        var heard: (@MainActor (String) -> Void)?
        var starts = 0
        // Everything else.
        var microphone: CookiePermissionStatus = .allowed
        var speech: CookiePermissionStatus = .allowed
        var missing: String?
        var secure = false
        var free = true
        var clock = Date(timeIntervalSince1970: 50_000)
        var asked: [String] = []
        var inFlight = 0
        var mostInFlight = 0
        var hold = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var fails = false
        var reply: (Int, String) -> String = { _, _ in #"{"title":"","nodes":[],"edges":[],"notes":[]}"# }
        var decks: [(request: String, shown: String)] = []
        var written = Set<String>()
        var writesDeck = true
        var phaseDuringDeck: CookieCanvas.Phase?
        weak var canvas: CookieCanvas?
        var notes: [String] = []
        let store = CookieWorkspaceStore(persistent: false)
        let thread = UUID()

        struct Down: Error {}

        var environment: CookieCanvasEnvironment {
            CookieCanvasEnvironment(
                microphone: { [unowned self] in self.microphone },
                speech: { [unowned self] in self.speech },
                model: { [unowned self] in ("test:model", self.missing) },
                ask: { [unowned self] _, input, _ in
                    self.asked.append(input)
                    let index = self.asked.count
                    self.inFlight += 1
                    self.mostInFlight = max(self.mostInFlight, self.inFlight)
                    defer { self.inFlight -= 1 }
                    if self.hold { await withCheckedContinuation { self.waiters.append($0) } }
                    if self.fails { throw Down() }
                    return self.reply(index, input)
                },
                ears: CookieCanvasEars(
                    start: { [unowned self] heard in
                        self.starts += 1
                        guard self.startsWork else { return }
                        self.heard = heard
                        self.busy = true
                        self.recording = true
                        self.partial = ""
                    },
                    finish: { [unowned self] in
                        self.recording = false
                        self.busy = false
                        let words = self.partial
                        self.heard?(words)
                    },
                    cancel: { [unowned self] in
                        self.recording = false
                        self.busy = false
                    },
                    partial: { [unowned self] in self.partial },
                    power: { [unowned self] in self.power },
                    busy: { [unowned self] in self.busy },
                    recording: { [unowned self] in self.recording },
                    error: { [unowned self] in self.earsError },
                    partials: { [unowned self] in self.partials }),
                secureInput: { [unowned self] in self.secure },
                microphoneFree: { [unowned self] in self.free },
                claimMicrophone: {},
                thread: { [unowned self] in self.thread },
                store: store,
                runDeck: { [unowned self] request, shown in
                    self.decks.append((request, shown))
                    self.phaseDuringDeck = self.canvas?.phase
                    if self.writesDeck, let path = CookieCanvasTests.deckPath(in: request) { self.written.insert(path) }
                },
                deckFolder: { URL(fileURLWithPath: "/Users/test/Desktop") },
                fileExists: { [unowned self] in self.written.contains($0) },
                note: { [unowned self] in self.notes.append($0) },
                now: { [unowned self] in self.clock },
                hideSecrets: { true })
        }

        func release() {
            let waiting = waiters
            waiters = []
            waiting.forEach { $0.resume() }
        }
    }

    static func drain() async { for _ in 0..<60 { await Task.yield() } }

    /// Ten ticks a second for `seconds`, saying `words` (nil: silence, the words so far kept).
    static func run(_ canvas: CookieCanvas, _ fake: Fake, seconds: Double, saying words: String? = nil) async {
        for _ in 0..<Int((seconds * 10).rounded()) {
            if let words, fake.recording {
                fake.partial = words
                fake.power = 0.3
            } else {
                fake.power = 0
            }
            fake.clock = fake.clock.addingTimeInterval(0.1)
            canvas.tick()
            await drain()
        }
    }

    /// One thing said, then a pause long enough to end it.
    static func say(_ canvas: CookieCanvas, _ fake: Fake, _ words: String) async {
        await run(canvas, fake, seconds: 0.6, saying: words)
        await run(canvas, fake, seconds: 1.6)
    }

    static func canvasJSON(_ nodes: [(String, String, String?)], edges: [(String, String, String?)] = [], notes: [String] = [],
                           title: String = "Launch plan") -> String {
        let nodeText = nodes.map { id, label, group in
            #"{"id":"\#(id)","label":"\#(label)""# + (group.map { #","group":"\#($0)""# } ?? "") + "}"
        }.joined(separator: ",")
        let edgeText = edges.map { from, to, label in
            #"{"from":"\#(from)","to":"\#(to)""# + (label.map { #","label":"\#($0)""# } ?? "") + "}"
        }.joined(separator: ",")
        let noteText = notes.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"title":"\#(title)","nodes":[\#(nodeText)],"edges":[\#(edgeText)],"notes":[\#(noteText)]}"#
    }

    nonisolated static func deckPath(in request: String) -> String? {
        guard let start = request.range(of: #""path":""#), let end = request[start.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(request[start.upperBound..<end])
    }

    static func run() async {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }

        // MARK: Schema

        let good = CookieCanvasResponse.parse("Here you go:\n" + canvasJSON([("Pricing", "Pricing tiers", "Strategy"), ("free-tier", "Free tier", nil)],
                                                                             edges: [("pricing", "free-tier", "includes")], notes: ["Decide by Friday"]) + "\nthanks")
        if case .success(let canvas) = good {
            check(canvas.nodes.map(\.id) == ["pricing", "free-tier"], "ids are taken lowercased, in order")
            check(canvas.nodes[0].group == "Strategy" && canvas.nodes[1].group == nil, "groups are optional")
            check(canvas.edges == [CookieCanvasEdge(from: "pricing", to: "free-tier", label: "includes")], "edges keep their label")
            check(canvas.notes == ["Decide by Friday"] && canvas.title == "Launch plan", "title and notes are kept")
        } else { check(false, "a valid canvas parses") }
        func invalid(_ reply: String) -> CookieCanvasInvalid? {
            if case .failure(let why) = CookieCanvasResponse.parse(reply) { return why }
            return nil
        }
        check(invalid(canvasJSON([("a", "A", nil), ("A", "Again", nil)])) == .duplicateID("a"), "duplicate ids are refused, whatever their case")
        check(invalid(canvasJSON([("a", "A", nil)], edges: [("a", "ghost", nil)])) == .danglingEdge("a→ghost"), "an edge to a node that isn't there is refused")
        check(invalid(canvasJSON([("a", "A", nil)], edges: [("a", "a", nil)])) == .selfEdge("a"), "an edge to itself is refused")
        check(invalid(canvasJSON([("a", "A", nil), ("b", "B", nil)], edges: [("a", "b", nil), ("a", "b", "again")])) == .duplicateEdge("a→b"),
              "the same edge twice is refused")
        let fortyOne = (1...41).map { ("n\($0)", "Idea \($0)", String?.none) }
        check(invalid(canvasJSON(fortyOne)) == .tooManyNodes(41), "41 nodes are refused")
        check(CookieCanvasResponse.parse(canvasJSON(Array(fortyOne.prefix(40)))).isSuccess, "40 nodes fit")
        let pairs = (1...11).flatMap { a in (1...11).filter { $0 != a }.map { ("n\(a)", "n\($0)", String?.none) } }
        check(invalid(canvasJSON(Array(fortyOne.prefix(11)), edges: Array(pairs.prefix(61)))) == .tooManyEdges(61), "61 edges are refused")
        check(invalid(canvasJSON([("a", "A", nil)], notes: (1...11).map { "note \($0)" })) == .tooManyNotes(11), "eleven notes are refused")
        check(invalid(canvasJSON([("a", String(repeating: "x", count: 49), nil)])) == .tooLong("node a label"), "a label past 48 characters is refused")
        check(CookieCanvasResponse.parse(canvasJSON([("a", String(repeating: "x", count: 48), nil)])).isSuccess, "a 48-character label fits")
        check(invalid(canvasJSON([("a", "A", String(repeating: "g", count: 33))])) == .tooLong("node a group"), "a long group is refused")
        check(invalid(canvasJSON([("a", "A", nil), ("b", "B", nil)], edges: [("a", "b", String(repeating: "l", count: 33))])) == .tooLong("edge a→b label"),
              "a long edge label is refused")
        check(invalid(canvasJSON([("a", "A", nil)], title: String(repeating: "t", count: 81))) == .tooLong("title"), "a long title is refused")
        check(invalid(canvasJSON([("has space", "A", nil)])) == .badID("has space"), "an id with a space is refused")
        check(invalid(#"{"title":3,"nodes":[]}"#) == .badShape("title"), "a title that isn't text is refused")
        check(invalid(#"{"title":"t","nodes":[{"id":"a","label":"A","group":7}]}"#) == .badShape("node a group"), "a group that isn't text is refused")
        check(invalid(#"{"title":"t","nodes":[{"id":"a","label":"   "}]}"#) == .badShape("node a label"), "an empty label is refused")
        check(invalid("sorry, I can't") == .notJSON, "prose is refused")
        check(CookieCanvasResponse.parse(#"{"title":"t","nodes":[]}"#).isSuccess, "edges and notes may be left out")

        // MARK: Commands

        for phrase in ["start a canvas", "Hey Cookie, start a new canvas please", "let's map this out", "Let's think this through on a canvas", "new canvas"] {
            check(CookieCanvasCommand.parse(phrase) == .start, "\"\(phrase)\" starts a canvas")
        }
        check(CookieCanvasCommand.parse("Stop canvas.") == .stop && CookieCanvasCommand.parse("end the canvas") == .stop, "stop canvas stops")
        check(CookieCanvasCommand.parse("pause the canvas") == .pause && CookieCanvasCommand.parse("resume canvas") == .resume, "pause and resume")
        check(CookieCanvasCommand.parse("undo") == .undo && CookieCanvasCommand.parse("scratch that") == .undo, "undo")
        check(CookieCanvasCommand.parse("make it a deck") == .deck && CookieCanvasCommand.parse("turn this into slides") == .deck, "make it a deck")
        check(CookieCanvasCommand.parse("save canvas") == .save, "save canvas")
        for edit in ["move pricing under strategy", "delete that", "remove the free tier", "rename pricing to price plans",
                     "connect onboarding to retention", "merge ads and seo"] {
            check(CookieCanvasCommand.parse(edit) == .edit(edit), "\"\(edit)\" is an edit")
        }
        for idea in ["we should move faster on pricing", "I want to delete the old plan", "move fast and break things",
                     "don't delete that", "undo the damage the last launch did", "the deck is ready", "how do I start a canvas in Figma",
                     "move the launch to march because the team needs more time to test the onboarding flow properly",
                     "pricing is the hardest part"] {
            check(CookieCanvasCommand.parse(idea) == nil, "\"\(idea)\" is an idea, not a command")
        }

        // MARK: Stable layout

        let three = [CookieCanvasNode(id: "a", label: "A", group: "Growth"), CookieCanvasNode(id: "b", label: "B", group: "Growth"),
                     CookieCanvasNode(id: "c", label: "C", group: "Money")]
        let first = CookieCanvasLayout.place(three, keeping: [:])
        check(Set(first.values).count == 3, "every box gets its own cell")
        let four = three + [CookieCanvasNode(id: "d", label: "D", group: "Growth")]
        let second = CookieCanvasLayout.place(four, keeping: first)
        check(["a", "b", "c"].allSatisfy { second[$0] == first[$0] }, "boxes already placed don't move when one is added")
        func gap(_ x: CookieCanvasCell?, _ y: CookieCanvasCell?) -> Int {
            guard let x, let y else { return 99 }
            return max(abs(x.column - y.column), abs(x.row - y.row))
        }
        check(min(gap(second["d"], second["a"]), gap(second["d"], second["b"])) == 1, "a new idea lands beside its theme")
        let renamed = [CookieCanvasNode(id: "a", label: "A renamed", group: "Money"), three[2]]
        let third = CookieCanvasLayout.place(renamed, keeping: second)
        check(third["a"] == second["a"] && third["c"] == second["c"] && third["b"] == nil, "a rename or a regroup keeps the box where it is; deleted ones go")
        let forty = (1...40).map { CookieCanvasNode(id: "n\($0)", label: "\($0)", group: $0 % 3 == 0 ? nil : "g\($0 % 4)") }
        var grown: [String: CookieCanvasCell] = [:]
        for count in 1...40 {
            let before = grown
            grown = CookieCanvasLayout.place(Array(forty.prefix(count)), keeping: grown)
            check(before.allSatisfy { grown[$0.key] == $0.value }, "growing to \(count) ideas moves none")
        }
        check(Set(grown.values).count == 40 && grown.values.allSatisfy { $0.column < 6 && $0.row < 7 }, "forty ideas fit the grid, one per cell")
        let saved = CookieCanvasCell(column: 4, row: 2)
        check(CookieCanvasCell(point: saved.point) == saved, "a saved x and y come back as the same cell")
        // The console's workspace: 928 × 580 less the chat column and the chrome.
        let console = CookieCanvasGeometry(size: CGSize(width: 593 - 16, height: 400))
        let frames = grown.values.map(console.frame)
        check(console.box.width >= 70 && console.box.height >= 30, "boxes stay readable in the console")
        check(frames.allSatisfy { a in frames.allSatisfy { b in a == b || !a.intersects(b) } }, "no two boxes overlap in the console")
        check(frames.allSatisfy { CGRect(origin: .zero, size: console.size).contains($0) }, "every box is inside the canvas")

        // MARK: Deck

        let plan = CookieCanvasDeck.plan(CookieCanvasState(title: "Launch plan", nodes: four + [CookieCanvasNode(id: "e", label: "E", group: nil)],
                                                           edges: [CookieCanvasEdge(from: "a", to: "c", label: "funds"), CookieCanvasEdge(from: "b", to: "d", label: nil)],
                                                           notes: ["Ship in March"]),
                                         cells: second.merging(["e": CookieCanvasCell(column: 5, row: 6)]) { a, _ in a },
                                         date: Date(timeIntervalSince1970: 1_763_000_000))
        check(plan.title == "Launch plan" && plan.subtitle.hasPrefix("5 ideas · mapped out loud on"), "the title slide is the canvas's title and size")
        check(plan.slides.map(\.title) == ["Growth", "Money", "Other ideas", "Summary"] || plan.slides.map(\.title) == ["Money", "Growth", "Other ideas", "Summary"],
              "one slide per theme, then ideas without one, then the summary")
        let growth = plan.slides.first { $0.title == "Growth" }!
        check(Set(growth.bullets.prefix(3)) == ["A", "B", "D"], "a theme's ideas are its bullets")
        check(growth.bullets.contains("A → C: funds") && !growth.bullets.contains { $0.hasPrefix("B → D") }, "labelled links are its relationships")
        check(plan.slides.last?.bullets == ["Ship in March"], "the summary is the notes")
        let noNotes = CookieCanvasDeck.plan(CookieCanvasState(title: "", nodes: three), cells: first)
        check(noNotes.title == "Canvas" && noNotes.slides.last?.bullets == ["Growth: 2 ideas", "Money: 1 idea"], "without notes the summary counts each theme")
        let loose = CookieCanvasDeck.plan(CookieCanvasState(title: "x", nodes: [CookieCanvasNode(id: "a", label: "A")]), cells: [:])
        check(loose.slides.map(\.title) == ["Ideas"], "no themes: one slide of ideas, and no summary to make up")
        let taken: Set<String> = ["/Users/test/Desktop/Launch plan.pptx", "/Users/test/Desktop/Launch plan 2.pptx"]
        check(CookieCanvasDeck.path(title: "Launch plan", folder: URL(fileURLWithPath: "/Users/test/Desktop"), exists: taken.contains)
              == "/Users/test/Desktop/Launch plan 3.pptx", "a deck never lands on an existing file")
        check(CookieCanvasDeck.path(title: "a/b: c", folder: URL(fileURLWithPath: "/D"), exists: { _ in false }) == "/D/a b  c.pptx", "a title can't make a path")

        // MARK: The controller

        let fake = Fake()
        let proof = CookieProof(file: nil)
        let canvas = CookieCanvas(environment: fake.environment, proof: proof)
        fake.canvas = canvas
        check(!canvas.accepts(.undo) && !canvas.accepts(.edit("delete that")) && canvas.accepts(.start), "with no canvas, only start is the canvas's")
        check(canvas.start(thread: fake.thread) == nil && canvas.phase == .listening, "a canvas starts listening")
        let artifact = { fake.store.project(fake.thread).first { $0.id == canvas.artifactID } }
        check(artifact()?.kind == .diagram && artifact().map(CookieCanvas.isCanvas) == true, "it is a diagram in this chat's workspace at once")
        check(fake.store.session(fake.thread).showing && fake.store.session(fake.thread).artifactID == canvas.artifactID, "the workspace shows it")
        check(canvas.indicator?.text == "Canvas · listening · 0 ideas", "the notch says it's listening")
        check(canvas.accepts(.undo) && canvas.accepts(.edit("delete that")), "with a canvas on, its commands are its")

        // A pause ends what was said, and it goes up with the canvas.
        fake.reply = { _, _ in canvasJSON([("pricing", "Pricing tiers", "Strategy"), ("teams", "Team plan", "Strategy")]) }
        await run(canvas, fake, seconds: 0.2)
        check(fake.starts == 1 && fake.recording, "the microphone opens through the dictation")
        await say(canvas, fake, "pricing tiers and a team plan")
        await canvas.finishUpdates()
        check(fake.asked.count == 1 && fake.asked[0].contains("pricing tiers and a team plan") && fake.asked[0].contains("canvas so far (json)"),
              "a pause sends what was said with the canvas")
        check(canvas.canvas.nodes.count == 2 && canvas.recent == ["pricing", "teams"], "the next canvas is taken, its new ideas marked")
        check(artifact()?.current.content.nodes.map(\.group) == ["Strategy", "Strategy"], "the workspace diagram carries the themes")
        check(canvas.indicator?.text == "Canvas · listening · 2 ideas", "the notch counts the ideas")
        let sent = proof.entries.filter { $0.kind == .sent && $0.feature == "voice canvas" }
        check(sent.count == 1 && sent[0].summary.hasPrefix("29 characters of what you said") && !sent[0].summary.contains("pricing")
              && sent[0].destination == "test:model", "Proof gets the characters sent, never the words")
        let placed = canvas.cells

        // Six seconds of speech without a pause goes up mid-sentence; the rest follows at the pause.
        fake.reply = { _, _ in canvasJSON([("pricing", "Pricing tiers", "Strategy"), ("teams", "Team plan", "Strategy"), ("ads", "Paid ads", "Growth")],
                                          edges: [("ads", "pricing", "feeds")]) }
        var spoken = "we could"
        for second in 0..<7 {
            spoken += " grow with paid ads number \(second)"
            await run(canvas, fake, seconds: 1, saying: spoken)
        }
        await canvas.finishUpdates()
        check(fake.asked.count == 2 && fake.asked[1].contains("paid ads number 5") && fake.recording && canvas.phase == .listening,
              "six seconds of speech is sent without waiting for a pause")
        check(["pricing", "teams"].allSatisfy { canvas.cells[$0] == placed[$0] }, "boxes on the canvas stay put as it grows")
        check(artifact()?.current.content.edges.first?.label == "feeds", "links keep their words in the workspace")
        spoken += " then a waitlist"
        await run(canvas, fake, seconds: 0.5, saying: spoken)
        await run(canvas, fake, seconds: 1.6)
        await canvas.finishUpdates()
        check(fake.asked.count == 3 && !fake.asked[2].contains("number 5") && fake.asked[2].contains("then a waitlist"), "only the rest of the sentence follows")

        // Never two at once: what's said meanwhile waits and goes together.
        fake.hold = true
        fake.reply = { index, _ in canvasJSON([("pricing", "Pricing tiers", "Strategy"), ("teams", "Team plan", "Strategy"), ("ads", "Paid ads", "Growth"),
                                               ("seo", "Search", "Growth")] + (index > 4 ? [("events", "Events", "Growth")] : [])) }
        await say(canvas, fake, "search engine work")
        check(fake.asked.count == 4 && canvas.phase == .updating && canvas.indicator?.text == "Canvas · updating · 3 ideas", "an update is out")
        await say(canvas, fake, "maybe events")
        await say(canvas, fake, "and meetups too")
        check(fake.asked.count == 4 && fake.mostInFlight == 1, "nothing more goes while it is out")
        fake.release()
        await drain()
        check(fake.asked.count == 5 && fake.asked[4].contains("maybe events and meetups too"), "what was said meanwhile goes together, once")
        fake.release()
        await canvas.finishUpdates()
        check(fake.mostInFlight == 1 && canvas.canvas.nodes.count == 5, "never two updates at once")
        fake.hold = false

        // A reply that doesn't fit keeps the last good canvas; it's tried once more, then let go.
        let goodCanvas = canvas.canvas
        fake.reply = { _, _ in canvasJSON([("a", "A", nil), ("a", "B", nil)]) }
        await say(canvas, fake, "something odd")
        await canvas.finishUpdates()
        check(fake.asked.count == 7 && fake.asked[6].contains("something odd"), "an update that didn't fit is tried once more")
        check(canvas.canvas == goodCanvas && artifact().map(CookieCanvas.state) == goodCanvas, "the last good canvas stays")
        check(canvas.status == "Some of what you said didn't make it onto the canvas", "and the canvas says so")

        // Undo is local.
        let asks = fake.asked.count
        let beforeLast = CookieCanvas.state(from: fake.store.project(fake.thread).first { $0.id == canvas.artifactID }!)
        check(canvas.undo() && fake.asked.count == asks, "undo needs no model")
        check(canvas.canvas.nodes.count == 4 && canvas.canvas != beforeLast, "undo puts the previous canvas back")
        check(artifact().map(CookieCanvas.state) == canvas.canvas, "and the workspace shows it")
        check(canvas.undo() && canvas.canvas.nodes.count == 3 && canvas.undo() && canvas.canvas.nodes.count == 2, "undo goes back step by step")
        check(["pricing", "teams"].allSatisfy { canvas.cells[$0] == placed[$0] }, "undone boxes are where they were")
        _ = canvas.undo()
        check(canvas.canvas.isEmpty && !canvas.undo() && !canvas.canUndo, "past the first update there's nothing to undo")

        // Said out loud: edits go up marked as edits; undo and stop never reach the model.
        fake.reply = { _, _ in canvasJSON([("pricing", "Pricing", "Strategy")]) }
        await say(canvas, fake, "pricing")
        await canvas.finishUpdates()
        let afterPricing = fake.asked.count
        fake.reply = { _, _ in canvasJSON([("pricing", "Pricing", "Strategy"), ("ads", "Ads", "Strategy")]) }
        await say(canvas, fake, "move ads under strategy")
        await canvas.finishUpdates()
        check(fake.asked.count == afterPricing + 1 && fake.asked.last!.contains("EDIT the person asked for") && fake.asked.last!.contains("move ads under strategy")
              && !fake.asked.last!.contains("new speech"), "a spoken edit goes up as an edit")
        check(fake.asked.last!.contains("most recently added ids: pricing"), "\"that\" can be found: the newest ids go along")
        await say(canvas, fake, "undo")
        check(fake.asked.count == afterPricing + 1 && canvas.canvas.nodes.map(\.id) == ["pricing"], "a spoken undo is done here")

        // An update out when undo lands is put back and redone on the undone canvas.
        fake.hold = true
        fake.reply = { index, _ in index == afterPricing + 2 ? canvasJSON([("pricing", "Pricing", "Strategy"), ("ads", "Ads", nil), ("beta", "Beta", nil)])
                                                              : canvasJSON([("beta", "Beta", nil)]) }
        await say(canvas, fake, "a beta list")
        check(fake.asked.count == afterPricing + 2, "the update is out")
        // Undo while it's out: back to the empty canvas.
        check(canvas.undo() && canvas.canvas.isEmpty, "undo while an update is out")
        fake.release()
        await drain()
        check(fake.asked.count == afterPricing + 3 && fake.asked.last!.contains("a beta list") && !fake.asked.last!.contains("\"pricing\""),
              "the stale answer is dropped and the words go again on the canvas as it is")
        fake.release()
        await canvas.finishUpdates()
        fake.hold = false
        check(canvas.canvas.nodes.map(\.id) == ["beta"], "the redone update lands")

        // A password field: nothing is heard until it's gone.
        fake.secure = true
        await run(canvas, fake, seconds: 0.2)
        check(canvas.phase == .paused(.password) && !fake.recording && canvas.indicator?.text == "Canvas · paused · password field · 1 idea",
              "a password field pauses the canvas")
        fake.secure = false
        await run(canvas, fake, seconds: 0.3)
        check(canvas.phase == .listening && fake.recording, "and it listens again after")

        // The talk shortcut's dictation: the canvas steps aside, and comes back when the microphone is free.
        canvas.pause(.yielded)
        fake.busy = true
        fake.free = false
        await run(canvas, fake, seconds: 3)
        check(canvas.phase == .paused(.yielded), "it stays aside while Cookie is busy")
        fake.busy = false
        fake.free = true
        await run(canvas, fake, seconds: 2)
        check(canvas.phase == .listening, "it listens again once the microphone is free")

        // "Make it a deck": the normal run, paused meanwhile, and where the file landed.
        check(canvas.perform(.deck).hasPrefix("Making a deck"), "make it a deck starts")
        await drain()
        check(fake.decks.count == 1 && fake.decks[0].request.contains("make_deck") && fake.decks[0].shown == "Make a deck from my canvas “Launch plan”",
              "the deck goes through the normal run with make_deck")
        check(fake.phaseDuringDeck == .paused(.deck) && canvas.phase == .listening, "listening pauses for the run's approval, then carries on")
        check(deckPath(in: fake.decks[0].request) == "/Users/test/Desktop/Launch plan.pptx", "the deck is named after the canvas, on the Desktop")
        check(fake.notes == ["Your deck is on the Desktop: Launch plan.pptx"] && proof.entries.first?.kind == .acted, "the person is told where it is")
        fake.writesDeck = false
        await canvas.makeDeck()
        check(fake.notes.last == "The deck wasn't made, so nothing was written to the Desktop.", "a refused or failed write is said plainly")

        // Save, then stop by voice; the canvas stays and can still become a deck.
        check(canvas.save().hasPrefix("Saved “Launch plan”") && artifact()?.current.summary == "Saved: Launch plan", "save keeps a named version")
        await say(canvas, fake, "stop canvas")
        check(canvas.phase == .stopped && !fake.recording && canvas.hasCanvas && !canvas.isOn, "stop canvas ends listening and keeps the canvas")
        check(canvas.accepts(.deck) && !canvas.accepts(.undo), "a stopped canvas can still become a deck")
        let afterStop = fake.asked.count
        await run(canvas, fake, seconds: 2, saying: "hello")
        check(fake.asked.count == afterStop && fake.starts > 0 && !fake.recording, "nothing is heard after stop")

        // Problems, said plainly.
        let denied = Fake()
        denied.microphone = .denied
        let blocked = CookieCanvas(environment: denied.environment, proof: CookieProof(file: nil))
        check(blocked.start() == .microphoneDenied && blocked.phase == .idle && blocked.indicator?.failed == true, "no microphone: it says how to allow it")
        denied.microphone = .allowed
        denied.speech = .denied
        check(blocked.start() == .speechDenied, "no speech recognition: it says so")
        denied.speech = .allowed
        denied.missing = "Choose a model first"
        check(blocked.start() == .modelUnavailable("Choose a model first"), "no model: it says what's missing")
        denied.missing = nil
        denied.startsWork = false
        denied.earsError = "microphone busy"
        check(blocked.start() == nil, "it starts")
        await run(blocked, denied, seconds: 0.3)
        check(blocked.phase == .stopped && blocked.problem == .listening("microphone busy"), "a microphone that won't open stops it, with why")

        // The model going quiet pauses it rather than losing words silently.
        let down = Fake()
        down.fails = true
        let offline = CookieCanvas(environment: down.environment, proof: CookieProof(file: nil))
        offline.start(thread: down.thread)
        await say(offline, down, "one idea")
        await offline.finishUpdates()
        await say(offline, down, "another idea")
        await offline.finishUpdates()
        check(offline.phase == .paused(.modelDown("no answer")) && offline.canvas.isEmpty, "three unanswered updates pause the canvas")

        // Three quiet minutes pause it.
        let quiet = Fake()
        let still = CookieCanvas(environment: quiet.environment, proof: CookieProof(file: nil))
        still.start(thread: quiet.thread)
        quiet.clock = quiet.clock.addingTimeInterval(181)
        still.tick()
        check(still.phase == .paused(.quiet), "three quiet minutes pause it")

        // Wiring: a canvas started like the console button does, with fake speech and model, is a drawn diagram.
        let wired = Fake()
        wired.reply = { _, _ in canvasJSON([("pricing", "Pricing tiers", "Strategy"), ("teams", "Team plan", "Strategy"), ("ads", "Paid ads", nil)],
                                           edges: [("ads", "pricing", "feeds")], notes: ["Decide by Friday"], title: "Pricing") }
        let live = CookieCanvas(environment: wired.environment, proof: CookieProof(file: nil))
        check(live.perform(.start).hasPrefix("Canvas on"), "start a canvas, as said")
        await say(live, wired, "pricing tiers, a team plan and paid ads that feed pricing; decide by Friday")
        await live.finishUpdates()
        guard let drawn = wired.store.selected(wired.thread) else { return precondition(false, "the canvas is the workspace's output") }
        check(CookieCanvas.isCanvas(drawn) && drawn.title == "Pricing" && drawn.current.content.nodes.count == 3
              && drawn.current.content.blocks.map(\.text) == ["Decide by Friday"], "the canvas is the chat's selected diagram, notes and all")
        check(drawn.current.content.nodes.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) } && wired.store.checks(drawn).isEmpty,
              "its diagram passes the workspace's own checks")
        let board = CookieCanvasBoard(artifact: drawn, canvas: live, selected: "", select: { _ in })
            .frame(width: 577, height: 440).background(Color.black).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: board)
        renderer.scale = 1
        check(renderer.cgImage.map { $0.width == 577 && $0.height == 440 } == true, "the board draws at the console's size")

        print("\(checks) canvas checks passed.")
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { return true } else { return false } }
}
