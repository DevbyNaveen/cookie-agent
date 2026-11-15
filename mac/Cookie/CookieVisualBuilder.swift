//
//  CookieVisualBuilder.swift
//  Cookie
//
//  `build_visual`: the model hands Cookie a card's JSON before it speaks, and
//  gets back what Cookie will actually draw — the card read forgivingly
//  (`CookieCard.read`, every repair listed), any field-level errors to fix, and
//  the card rendered off screen. The reply then shows it with [CARD:#id] at the
//  word where it belongs. The helper's tool results carry text only, so the
//  rendering comes back described (its size and where each thing landed),
//  not as a picture; the render still happens, so a card that can't draw is
//  caught here and not in front of the person.
//

import AppKit
import SwiftUI

@MainActor
enum CookieVisualBuilder {
    static let tool = HarnessRequest.Tool(
        name: "build_visual",
        description: "Check a paper card before showing it. Give the card JSON (same shapes as [CARD {json}], including states, chart, layers, cycle, tree, equation and sim). Returns {ok, id, repairs, errors, snapshot, layout}: repairs Cookie made, field-level errors to fix (then call again, at most twice more this turn), and layout, a text description of the off-screen render (snapshot is null: results here are text only). When ok, show it in your reply with [CARD:#id] at the word where it should appear. Draws only; nothing leaves the Mac.",
        effect: "read",
        schema: .init(properties: [
            "card": .init(description: "The card as a JSON object written as a string, e.g. {\"kind\":\"cycle\",\"title\":\"…\",\"steps\":[…]}."),
            "id": .init(description: "Optional short id to show it by ([CARD:#id]); letters, digits and dashes."),
        ], required: ["card"]))

    static let callsPerTurn = 3
    /// How long the off-screen render may take before it's skipped (and said).
    static let renderBudget: TimeInterval = 2

    /// What the tool answers: a JSON object, and whether it is an error. The calls and the cards are
    /// the calling client's turn (`shelf`).
    static func perform(_ args: [String: Any], into shelf: CookieBuiltVisuals) async -> (String, Bool) {
        shelf.calls += 1
        guard shelf.calls <= callsPerTurn else {
            return (answer(["ok": false, "id": NSNull(), "repairs": [], "snapshot": NSNull(),
                            "errors": ["build_visual: \(callsPerTurn) tries this turn; show the last card that was ok, or explain in words"]]), true)
        }
        let json: String
        if let text = args["card"] as? String { json = text }
        else if let object = args["card"], JSONSerialization.isValidJSONObject(object),
                let data = try? JSONSerialization.data(withJSONObject: object) { json = String(decoding: data, as: UTF8.self) }
        else { return (answer(["ok": false, "id": NSNull(), "repairs": [], "snapshot": NSNull(), "errors": ["card: required, the card JSON"]]), true) }
        let result = await build(json, id: args["id"] as? String, into: shelf)
        return (answer(result.object), !result.ok)
    }

    struct Result {
        let ok: Bool
        let id: String?
        let repairs: [String]
        let errors: [String]
        let layout: String?

        var object: [String: Any] {
            ["ok": ok, "id": id ?? NSNull(), "repairs": repairs, "errors": errors, "snapshot": NSNull(),
             "snapshot_note": "Tool results are text only here, so the render is described in layout.",
             "layout": layout ?? NSNull()]
        }
    }

    /// Reads, repairs, renders and keeps the card under its id.
    static func build(_ json: String, id requested: String?, into shelf: CookieBuiltVisuals) async -> Result {
        let reading = CookieCard.read(json)
        guard let card = reading.card else {
            return Result(ok: false, id: nil, repairs: reading.repairs, errors: reading.errors, layout: nil)
        }
        var repairs = reading.repairs
        let id = Self.id(requested ?? Self.writtenID(json), repairs: &repairs)
        let renders = await render(card)
        shelf.keep(card, id: id)
        return Result(ok: true, id: id, repairs: repairs, errors: [], layout: describe(card, renders: renders))
    }

    /// The id as written (in the call, or the card's own "id"), cleaned; one is made when there's none.
    private static func id(_ written: String?, repairs: inout [String]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if let written, !written.isEmpty {
            let trimmed = written.hasPrefix("#") ? String(written.dropFirst()) : written
            let cleaned = String(String.UnicodeScalarView(trimmed.unicodeScalars.filter { allowed.contains($0) }).prefix(32))
            if !cleaned.isEmpty {
                if cleaned != trimmed { repairs.append("id: \"\(written)\" became \"\(cleaned)\"") }
                return cleaned
            }
        }
        made += 1
        return "card-\(made)"
    }
    private static var made = 0

    private static func writtenID(_ json: String) -> String? {
        guard let data = json.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object["id"] as? String
    }

    // MARK: Render

    struct Render {
        let state: Int
        let size: CGSize
        /// Whether any ink or text reached the image.
        let drawn: Bool
    }

    /// Each state rendered whole, off screen, in light paper, until the time budget runs out: the
    /// budget is checked before every stage, and once it's spent the stages left aren't rendered
    /// (`describe` says so). ImageRenderer belongs to the main actor, so between stages the main
    /// actor gets a turn for whatever is waiting (the reply, the pointer, a click).
    static func render(_ card: CookieCard, budget: TimeInterval = renderBudget) async -> (renders: [Render], skipped: Bool) {
        let started = Date()
        var renders: [Render] = []
        for state in card.states.indices {
            if state > 0 { await Task.yield() }
            guard Date().timeIntervalSince(started) < budget, !Task.isCancelled else { return (renders, true) }
            let reveal = CookieCardReveal(card: card)
            reveal.show(state: state)
            reveal.reveal(through: reveal.elements.count - 1, instant: true)
            let renderer = ImageRenderer(content: CookieCardView(reveal: reveal, onClose: {})
                .environment(\.colorScheme, .light)
                .transaction { $0.disablesAnimations = true })
            renderer.scale = 1
            guard let image = renderer.cgImage else { renders.append(Render(state: state, size: .zero, drawn: false)); continue }
            renders.append(Render(state: state, size: CGSize(width: image.width, height: image.height), drawn: inked(image)))
        }
        return (renders, false)
    }

    /// True when the middle of the image isn't blank paper: something was drawn on it.
    private static func inked(_ image: CGImage) -> Bool {
        let width = 64, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Paper is near-white in light mode; ink and text are well below it.
        var dark = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 200 && pixels[index] < 200 { dark += 1 }
        return dark > 8
    }

    // MARK: Describe

    /// What the render shows, in a line or two per state: size, then where each thing is.
    static func describe(_ card: CookieCard, renders: (renders: [Render], skipped: Bool)) -> String {
        var lines: [String] = []
        for (index, content) in card.states.enumerated() {
            let render = renders.renders.first { $0.state == index }
            let prefix = card.states.count > 1 ? "Stage \(index + 1)\(index > 0 ? card.cues[index].map { " (at \"\($0)\")" } ?? " (no at phrase: spaced evenly)" : ""): " : ""
            let size = render.map { $0.drawn ? "\(Int($0.size.width - 2 * CookieCardView.shadowMargin))×\(Int($0.size.height - 2 * CookieCardView.shadowMargin)) pt card" : "rendered blank" }
                ?? "not rendered (over the \(Int(renderBudget)) s budget)"
            lines.append(prefix + size + ". " + placement(content, card: card, state: index))
            if let render, render.size.height - 2 * CookieCardView.shadowMargin > 640 {
                lines.append("Warning: stage \(index + 1) is taller than 640 pt; on a laptop screen it may not fit beside the work. Trim rows or text.")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func placement(_ content: CookieCard.Content, card: CookieCard, state: Int) -> String {
        func at(_ box: CGRect) -> String { "\(Int(box.midX)),\(Int(box.midY))" }
        func squeezed(_ nodes: [CookieCard.Node], width: CGFloat) -> String {
            let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            let tight = nodes.filter { ($0.label as NSString).size(withAttributes: [.font: font]).width > (width - 12) * 2 }
            return tight.isEmpty ? "" : " Labels shrunk to fit: " + tight.map { "\"\($0.label)\"" }.joined(separator: ", ") + "."
        }
        switch content {
        case .flow(_, let nodes, let edges, _, let across):
            let layout = CookieCardView.flowCanvasLayout(card, state: state)
            let placed = nodes.compactMap { node in layout.boxes[node.id].map { "\(node.id) \"\(node.label)\" at \(at($0))" } }
            return "Flow \(across ? "left to right" : "top to bottom"), centres in canvas points: " + placed.joined(separator: "; ")
                + ". Arrows: " + (edges.isEmpty ? "none" : edges.map { "\($0.from)→\($0.to)" }.joined(separator: ", ")) + "."
                + squeezed(nodes, width: 112)
        case .layers(_, let layers):
            return "Layers, top to bottom: " + layers.map { $0.label + ($0.note.map { " (\($0))" } ?? "") }.joined(separator: " / ") + "."
        case .cycle(_, let steps):
            let centres = CookieCardView.cycleCentres(count: steps.count)
            return "Cycle clockwise from the top: " + zip(steps, centres).map { "\($0.0.id) \"\($0.0.label)\" at \(Int($0.1.x)),\(Int($0.1.y))" }.joined(separator: "; ")
                + ", then back to \(steps.first?.label ?? "the first")." + squeezed(steps, width: 104)
        case .tree(_, let nodes):
            let layout = CookieCardView.treeLayout(nodes)
            let byLevel = Dictionary(grouping: nodes) { Int((layout.boxes[$0.id]?.minY ?? 0).rounded()) }
            return "Tree, level by level: " + byLevel.keys.sorted().map { level in byLevel[level]!.map(\.label).joined(separator: ", ") }.joined(separator: " | ")
                + "." + squeezed(nodes, width: 96)
        case .chart(let chart):
            let plots = chart.plots(chart.sliders.map(\.value))
            let series: [String] = plots.map { plot in
                if chart.style == .bar { return "bar \(plot.id) \"\(plot.label)\" = \(CookieCard.format(Double(plot.points.first?.y ?? 0)))" }
                let ys = plot.points.map { Double($0.y) }
                return "\(plot.id) \"\(plot.label)\" \(plot.points.count) points, y \(CookieCard.format(ys.min() ?? 0))–\(CookieCard.format(ys.max() ?? 0))"
            }
            let sliders = chart.sliders.map { "\($0.id) \"\($0.label)\" \(CookieCard.format($0.minimum))–\(CookieCard.format($0.maximum)) at \(CookieCard.format($0.value))" }
            return "\(chart.style.rawValue.capitalized) chart, x \(CookieCard.format(chart.xRange.lowerBound))–\(CookieCard.format(chart.xRange.upperBound))"
                + (chart.xLabel.map { " (\($0))" } ?? "") + ", y \(CookieCard.format(chart.yRange.lowerBound))–\(CookieCard.format(chart.yRange.upperBound)) (\(chart.yLabel)). "
                + series.joined(separator: "; ") + "."
                + (sliders.isEmpty ? "" : " Sliders: " + sliders.joined(separator: "; ") + ".")
                + (chart.source.map { " Source shown: \($0)." } ?? " No source shown.")
        case .equation(let equation):
            guard let layout = equation.layout else {
                return "Equation shown as its source text (outside the typeset subset; see repairs)."
            }
            let parts = equation.terms.compactMap { term in
                layout.terms[term.id].map { "\(term.id) \"\(term.words)\"\(term.say.map { " on \"\($0)\"" } ?? " spread over the sentence") at x \(Int($0.minX))–\(Int($0.maxX))" }
            }
            return "Equation typeset \(Int(layout.width.rounded()))×\(Int(layout.size.height.rounded())) pt, read as \"\(equation.spoken)\". Parts left to right: "
                + (parts.isEmpty ? "none (it shows whole)" : parts.joined(separator: "; ")) + "."
                + (equation.highlight.map { " Lit: \($0)." } ?? "")
        case .sim(let sim):
            guard let model = CookieSim.models[sim.model] else { return "" }
            // The values at the representative moment the render shows (the run starts from the beginning).
            let runner = CookieSimRunner(sim)
            let settings = model.params.map { "\($0.id) \(CookieCard.format(sim.values[$0.id] ?? $0.value))\($0.unit.isEmpty ? "" : " " + $0.unit)" }
            let sliders = sim.sliders.map { "\($0.param) \(CookieCard.format($0.minimum))–\(CookieCard.format($0.maximum))" }
            return "Simulation of \(model.noun) (\(model.id)), \(sim.running ? "runs as it appears" : "waits for [VISUAL:run]"). Parameters: " + settings.joined(separator: ", ") + ". "
                + "Values to quote: " + runner.readouts.map(\.line).joined(separator: "; ") + "."
                + (sliders.isEmpty ? " No sliders." : " Sliders: " + sliders.joined(separator: ", ") + ".")
        default:
            return "\(CookieCard.elements(of: content).count) elements: " + CookieCard.summary(content) + "."
        }
    }

    private static func answer(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
