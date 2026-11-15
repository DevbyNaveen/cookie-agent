import AppKit
import SwiftUI

/// Paper v2: forgiving card reading, the new kinds, states that morph on the speech clock,
/// the pen's taper and wobble, and build_visual from a tool call through to [CARD:#id].
@MainActor
enum CookiePaperTests {
    static func run() async {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            count += 1
        }

        // MARK: Forgiving in, strict out
        let messy = CookieCard.read(#"{"kind":"diagram","title":"How a leaf makes sugar and keeps going all day long under the sun","colour":"red","nodes":[{"id":"sun","label":"Sunlight","icon":"sun.glow"},{"id":"leaf","label":"Leaf"},{"id":"leaf","label":"Again"}],"edges":[{"from":"sun","to":"leaf"},{"from":"leaf","to":"moon"}]}"#)
        check(messy.card != nil && messy.errors.isEmpty, "a card whose intent is clear is repaired, not dropped")
        check(messy.repairs.contains { $0.hasPrefix("kind: read \"diagram\"") } && messy.repairs.contains { $0.hasPrefix("colour:") }
              && messy.repairs.contains { $0.contains("sun.glow") } && messy.repairs.contains { $0.hasPrefix("title: shortened") }
              && messy.repairs.contains { $0.contains("repeats id leaf") } && messy.repairs.contains { $0.contains("moon isn't a node") },
              "every repair is written down: \(messy.repairs)")
        if case .flow(let title, let nodes, let edges, _, _)? = messy.card?.content {
            check(title.count <= CookieCard.titleLength && title.hasSuffix("…") && nodes.count == 2 && nodes[0].icon == nil && edges.count == 1,
                  "the repairs are what was drawn")
        } else { preconditionFailure("an alias of flow reads as a flow") }
        let missing = CookieCard.read(#"{"kind":"steps","steps":[{"text":"one"},{"nope":1}]}"#)
        check(missing.card == nil && missing.errors.contains("title: required") && missing.errors.contains("steps[1].text: required"),
              "what can't be guessed is an error naming its field: \(missing.errors)")
        let loop = CookieCard.read(#"{"kind":"flow","title":"Loop","nodes":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"edges":[{"from":"a","to":"b"},{"from":"b","to":"a"}]}"#)
        check(loop.card == nil && loop.errors.first?.contains("cycle") == true, "a looping flow points at the cycle kind")
        check(CookieCard.read("not json").errors == ["card: not a JSON object"] && CookieCard.read(#"{"kind":"poem"}"#).errors.first?.hasPrefix("kind:") == true,
              "garbage and unknown kinds are refused plainly")

        // MARK: New kinds
        let cycle = CookieCard.read(#"{"kind":"cycle","title":"The water cycle","steps":[{"id":"e","label":"Evaporation","icon":"sun.max"},{"id":"c","label":"Condensation","icon":"cloud"},{"id":"p","label":"Rain","icon":"drop"}]}"#).card!
        check(cycle.elements == [.title, .node("e"), .node("c"), .edge(0), .node("p"), .edge(1), .edge(2)],
              "a cycle draws each step, the arrow into it, and the arrow that closes the loop")
        check(CookieCardView.cycleArc(from: 0, count: 3).allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) }, "cycle arcs stay on the canvas")
        let tree = CookieCard.read(#"{"kind":"tree","title":"Animals","nodes":[{"id":"m","label":"Mammals","parent":"a"},{"id":"a","label":"Animals"},{"id":"d","label":"Dogs","parent":"m"},{"id":"b","label":"Birds","parent":"a"}]}"#).card!
        if case .tree(_, let nodes) = tree.content {
            check(nodes.map(\.id) == ["a", "m", "b", "d"], "a tree reads root first, level by level")
            let layout = CookieCardView.treeLayout(nodes)
            check(layout.boxes["a"]!.midX == (layout.boxes["d"]!.midX + layout.boxes["b"]!.midX) / 2 || layout.boxes["a"]!.minY < layout.boxes["m"]!.minY,
                  "parents sit above their children")
        }
        check(CookieCard.read(#"{"kind":"tree","title":"T","nodes":[{"id":"a","label":"A"},{"id":"b","label":"B"}]}"#).errors.first?.contains("one root") == true,
              "a tree with two roots is refused with the reason")
        let layers = CookieCard.read(#"{"kind":"stack","title":"The web","layers":[{"id":"app","label":"HTTP","note":"what the page asks for"},{"id":"tcp","label":"TCP"}]}"#).card!
        check(layers.nodes.map(\.id) == ["app", "tcp"] && layers.nodes[0].note == "what the page asks for", "layers keep their order and notes")

        // MARK: Charts and their sliders
        let chartJSON = #"{"kind":"chart","title":"Distance fallen","style":"line","xLabel":"time (s)","yLabel":"metres","series":[{"id":"d","label":"distance","formula":"0.5*A1*x*x","from":0,"to":3}],"sliders":[{"id":"g","label":"gravity","min":1,"max":20,"value":9.8,"unit":"m/s²"}],"source":"d = ½gt²"}"#
        let chartReading = CookieCard.read(chartJSON)
        guard case .chart(let chart)? = chartReading.card?.content else { preconditionFailure("chart: \(chartReading.errors)") }
        check(chartReading.repairs.contains { $0.contains("added the leading =") } && chartReading.repairs.contains { $0.contains("read x as B1") }
              && chartReading.repairs.contains { $0.contains("read min as minimum") }, "formulas and slider fields are repaired: \(chartReading.repairs)")
        let at3 = chart.plots([9.8])[0].points.last!
        check(abs(at3.x - 3) < 1e-9 && abs(at3.y - 44.1) < 1e-6, "the formula is the sheet engine's, x as B1 and the slider as A1")
        check(abs(chart.plots([20])[0].points.last!.y - 90) < 1e-6 && chart.yRange.upperBound >= 90,
              "dragging the slider recomputes, and the axes already cover its whole range")
        let badFormula = CookieCard.read(#"{"kind":"chart","title":"T","style":"line","xLabel":"x","yLabel":"y","series":[{"id":"a","label":"a","formula":"=A3*x","from":0,"to":1}],"sliders":[{"id":"k","label":"k","minimum":0,"maximum":1}]}"#)
        check(badFormula.card == nil && badFormula.errors.first?.contains("A3 isn't an input") == true, "a formula naming a slider that isn't there is refused: \(badFormula.errors)")
        let bars = CookieCard.read(#"{"kind":"chart","title":"Sales","yLabel":"units","series":[{"id":"q1","label":"Q1","value":12},{"id":"q2","label":"Q2","value":"18"}]}"#)
        if case .chart(let barChart)? = bars.card?.content {
            check(barChart.style == .bar && barChart.yRange.lowerBound <= 0 && bars.repairs.contains { $0.contains("drew it as bar") },
                  "a chart of values is drawn as bars from zero, and says it guessed the style")
        } else { preconditionFailure("bars: \(bars.errors)") }
        check(CookieCard.summary(chartReading.card!.content).contains("distance from 0 to " + CookieCard.format(44.1)), "a chart is said, numbers and all: \(CookieCard.summary(chartReading.card!.content))")

        // MARK: States on the speech clock
        let prompt = CompanionManager.companionVoiceResponseSystemPrompt
        let example = prompt.components(separatedBy: "\n").first { $0.contains("for example: \"a request goes through three hops") }!
        let split = CookieReplyTags.split(example)
        let staged = CookieCard(tag: split.tags.first { $0.kind == "CARD" }!)!
        check(staged.states.count == 2 && staged.cues == [nil, "with a cache"], "the prompt's worked example morphs through two states")
        let spoken = split.spoken
        let cue = staged.stateOffsets(in: spoken, after: staged.offset)
        check(cue.offsets == [(spoken as NSString).range(of: "with a cache").location] && cue.unmatched.isEmpty,
              "a state arrives on its own words")
        let unmatched = CookieCard(states: staged.states + [staged.states[0]], cues: [nil, "nowhere in the words", nil], offset: 0)
        let spread = unmatched.stateOffsets(in: "one two three four five six seven eight", after: 8)
        check(spread.unmatched == [2, 3] && spread.offsets == [8 + 31 / 3, 8 + 62 / 3], "states without words are spaced evenly after the tag: \(spread)")
        let wrongKind = CookieCard.read(#"{"kind":"list","title":"T","items":["a"],"states":[{},{"items":["b"]}]}"#)
        check(wrongKind.card?.states.count == 1 && wrongKind.repairs.contains { $0.contains("can't change between states") }, "a list doesn't morph, and says so")
        let oneBad = CookieCard.read(#"{"kind":"layers","title":"T","layers":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"states":[{},{"at":"then","layers":[{"id":"a"}]},{"at":"later","layers":[{"id":"b","label":"B"},{"id":"a","label":"A"}]}]}"#)
        check(oneBad.card?.states.count == 2 && oneBad.repairs.contains { $0.hasPrefix("states[1]: left out") }, "a state that can't be read is dropped and named, the card kept")

        // MARK: Morph
        check(CookieVisualCommand(body: "state:2") == .state(2) && CookieVisualCommand(body: "state:9") == nil && CookieVisualCommand(body: "state:x") == nil,
              "[VISUAL:state:n] is a stage, one to six")
        check(!CookieScenePresenter().apply(.state(2)), "a stage is never a 3D model's")
        let reveal = CookieCardReveal(card: staged)
        var changed: [Int] = []
        reveal.onStateChange = { changed.append($0) }
        reveal.reveal(through: 1, instant: true)
        check(reveal.show(state: 1) && reveal.state == 1 && reveal.elements.contains(.node("c")) && reveal.shown == reveal.elements.count && changed == [1],
              "moving to a state shows all of it, cache included")
        check(!reveal.show(state: 4) && reveal.state == 1, "a stage the card doesn't have is refused")
        let presenter = CookieCardPresenter()
        presenter.showNow(staged, near: nil)
        check(presenter.apply(.state(2)) && presenter.teachingContext?.contains("Stage 2 of 2") == true && presenter.focus("c"),
              "the reply's [VISUAL:state:2] reaches the card on screen, and follow-ups see the stage")
        presenter.dismiss()

        // MARK: Ink
        let line = (0...100).map { CGPoint(x: CGFloat($0) * 2, y: 0) }
        let inkA = CookieInkStroke(line, size: 4, seed: 7).outline(revealed: 200)!, inkB = CookieInkStroke(line, size: 4, seed: 7).outline(revealed: 200)!
        check(inkA == inkB && inkA != CookieInkStroke(line, size: 4, seed: 8).outline(revealed: 200)!, "a stroke's wobble is seeded: the same every redraw, its own per stroke")
        let outline = CookieFreehand.outline(line, size: 4, complete: true, seed: 7)
        let nib = outline.filter { $0.x > -1.5 && $0.x < 1.5 }.map { abs($0.y) }.max() ?? 0
        let body = outline.filter { $0.x > 95 && $0.x < 105 }.map { abs($0.y) }.max() ?? 0
        check(nib < body * 0.8, "the stroke tapers where the nib lands (\(nib) vs \(body))")
        check((0..<200).allSatisfy { abs(CookieFreehand.pressureWobble(at: CGFloat($0), seed: 3) - 1) <= CookieFreehand.wobble + 1e-6 }
              && CookieFreehand.pressureWobble(at: 40, seed: 0) == 1, "the wobble is slight and absent without a seed")
        check(CookieInkCache.strokeSeed(5, 0) != CookieInkCache.strokeSeed(5, 1), "a mark's strokes each have their own hand")

        // MARK: build_visual, from the tool call to [CARD:#id]
        check(HarnessClient.tools(backgroundProject: false, unattended: false, workspace: false).contains { $0.name == "build_visual" && $0.effect == "read" },
              "every voice run can check a card")
        let shelf = CookieBuiltVisuals()
        let built = await CookieVisualBuilder.perform(["card": #"{"kind":"cycle","title":"The water cycle","steps":["Evaporation","Condensation","Rain"]}"#, "id": "water"], into: shelf)
        let answer = try! JSONSerialization.jsonObject(with: Data(built.0.utf8)) as! [String: Any]
        check(!built.1 && answer["ok"] as? Bool == true && answer["id"] as? String == "water" && answer["snapshot"] is NSNull
              && (answer["layout"] as? String)?.contains("Cycle clockwise from the top") == true && (answer["layout"] as? String)?.contains("pt card") == true
              && (answer["repairs"] as? [String])?.contains { $0.contains("read as {id: \"rain\"") } == true,
              "build_visual repairs, renders off screen and describes the render: \(built.0)")
        let reply = CookieReplyTags.split("water goes round [CARD:#water] it rises as evaporation, gathers by condensation and falls as rain.")
        check(shelf.card(for: reply.tags[0])?.nodes.map(\.id) == ["evaporation", "condensation", "rain"] && shelf.card(for: reply.tags[0])?.offset == reply.tags[0].offset,
              "the reply shows the built card by its id, at its tag")
        check(CookieCard(tag: reply.tags[0]) == nil, "an id is the turn's to resolve, never a card from some other run")
        let lost = CookieReplyTags.split("here [CARD:#never-built] it is.").tags
        check(shelf.card(for: lost[0]) == nil && CompanionManager.pictureFailed(lost, shown: false), "an id nobody built is said, not silently skipped")
        let failed = await CookieVisualBuilder.perform(["card": #"{"kind":"tree","title":"T","nodes":[{"id":"a","label":"A"},{"id":"b","label":"B"}]}"#], into: shelf)
        check(failed.1 && failed.0.contains("one root") && failed.0.contains("\"ok\":false"), "a card that can't be built comes back with its field errors")
        let other = CookieBuiltVisuals()
        other.beginTurn()
        _ = await CookieVisualBuilder.perform(["card": "{}"], into: shelf)
        let fourth = await CookieVisualBuilder.perform(["card": "{}"], into: shelf)
        check(fourth.0.contains("tries this turn"), "three tries a turn, then words")
        let elsewhere = await CookieVisualBuilder.perform(["card": "{}"], into: other)
        check(!elsewhere.0.contains("tries this turn"),
              "each client counts its own tries: another run starting doesn't reset or spend this one's")
        // Next turn: a failed build under last turn's id shows nothing old, and the reply says the picture failed.
        shelf.beginTurn()
        _ = await CookieVisualBuilder.perform(["card": #"{"kind":"tree","title":"T","nodes":[{"id":"a","label":"A"},{"id":"b","label":"B"}]}"#, "id": "water"], into: shelf)
        let stale = CookieReplyTags.split("again [CARD:#water] here.").tags
        check(shelf.card(for: stale[0]) == nil && CompanionManager.pictureFailureNote(stale, scene: false, cards: false) != nil,
              "an id built in an earlier turn doesn't resolve: no stale card, and the failure is said")
        // The off-screen render gives the main actor a turn between stages and stops when the budget is spent.
        let spent = await CookieVisualBuilder.render(staged, budget: 0)
        check(spent.skipped && spent.renders.isEmpty && CookieVisualBuilder.describe(staged, renders: spent).contains("not rendered (over the"),
              "past the render budget the stages left aren't drawn, and the layout says so")
        let whole = await CookieVisualBuilder.render(staged)
        check(!whole.skipped && whole.renders.count == staged.states.count, "within it every stage is drawn")
        shelf.beginTurn()
        check(prompt.contains("build_visual") && prompt.contains("[CARD:#id]") && prompt.contains("[VISUAL:state:n]") && prompt.contains("never made up"),
              "the voice prompt teaches checking, showing by id, stages and honest numbers")

        render([("cycle", cycle, 0), ("tree", tree, 0), ("layers", layers, 0), ("chart", chartReading.card!, 0), ("bars", bars.card!, 0),
                ("flow-1", staged, 0), ("flow-2", staged, 1)])
        print("\(count) paper checks passed.")
    }

    /// With `--render-paper <folder>`: each card whole, light and dark, as PNGs there. For eyes, not for checks.
    static func render(_ cards: [(String, CookieCard, Int)]) {
        guard let at = CommandLine.arguments.firstIndex(of: "--render-paper"), at + 1 < CommandLine.arguments.count else { return }
        let folder = URL(fileURLWithPath: CommandLine.arguments[at + 1])
        for (name, card, state) in cards {
            for scheme in [ColorScheme.light, .dark] {
                let shown = CookieCardReveal(card: card)
                shown.show(state: state)
                shown.reveal(through: shown.elements.count - 1, instant: true)
                let renderer = ImageRenderer(content: CookieCardView(reveal: shown, onClose: {}).environment(\.colorScheme, scheme))
                renderer.scale = 2
                let data = NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
                try! data.write(to: folder.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}
