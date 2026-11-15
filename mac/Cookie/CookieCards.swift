//
//  CookieCards.swift
//  Cookie
//
//  Explainer cards: a small closed catalog of pictures Cookie can put beside
//  what it says — a timeline, steps, a flow of boxes and arrows, a list, a
//  comparison, one big number, a chart of given numbers, a stack of layers,
//  a cycle, a tree, an equation (typeset by `CookieMath`) and a simulation
//  from the vetted library (`CookieSim`). The model writes one inline as [CARD {json}] at the
//  word where it belongs, or builds it first with the `build_visual` tool and
//  shows it as [CARD:#id]. Either way the JSON is read here into exact Swift
//  types, forgivingly: what's clearly meant is repaired (text too long is
//  shortened, a row too many is left off, an unknown icon goes) and each repair
//  is written down; only what can't be guessed is refused, with the field that
//  failed. A card that can't be shown never drops the reply: the words are
//  still spoken, and Cookie says the picture didn't come through.
//
//  Each card is a short list of elements (its title, then each row, node or
//  edge) revealed one by one on the speech clock, spread over the sentence
//  that follows the tag. A card may also have `states`: the same picture at
//  two to six moments, morphing from one to the next (elements with the same
//  id move, the rest fade) as each state's `at` phrase is spoken, or at
//  [VISUAL:state:n].
//

import CoreGraphics
import Foundation

struct CookieCard: Equatable {
    struct Event: Codable, Equatable { let label: String; let when: String }
    struct Node: Codable, Equatable {
        let id: String
        let label: String
        let icon: String?
        /// A few quiet words under the label (layers, trees).
        var note: String? = nil
        /// A tree node's parent; nil for the root and for every other kind.
        var parent: String? = nil
        init(id: String, label: String, icon: String? = nil, note: String? = nil, parent: String? = nil) {
            self.id = id; self.label = label; self.icon = icon; self.note = note; self.parent = parent
        }
    }
    static let teachingIcons: Set<String> = ["sun.max", "drop", "leaf", "wind", "sparkles", "cube", "flame", "gearshape", "globe", "server.rack", "display", "arrow.triangle.branch", "bolt", "cloud", "atom"]
    struct Edge: Codable, Equatable { let from: String; let to: String; let label: String? }
    struct Column: Codable, Equatable { let heading: String; let points: [String] }

    /// A chart of numbers the conversation or a real source gave: never made up to fill a picture.
    struct Chart: Equatable {
        enum Style: String { case line, bar, scatter }
        struct Slider: Equatable {
            let id: String
            let label: String
            let minimum: Double
            let maximum: Double
            let value: Double
            let unit: String?
        }
        /// One line or set of dots (`points`, or `formula` sampled from `from` to `to`), or one bar
        /// (`value`, or `formula`).
        struct Series: Equatable {
            let id: String
            let label: String
            var points: [CGPoint] = []
            var formula: String? = nil
            var from: Double = 0
            var to: Double = 0
            var value: Double? = nil
        }
        let title: String
        let style: Style
        let xLabel: String?
        let yLabel: String
        let series: [Series]
        let sliders: [Slider]
        let source: String?
        /// Fixed when the card is read, wide enough for every slider's whole range, so the axes
        /// never jump while someone drags.
        var xRange: ClosedRange<Double> = 0...1
        var yRange: ClosedRange<Double> = 0...1

        /// Samples along a formula line.
        static let samples = 40
    }

    /// An equation typeset from TeX. Its parts (\id{name}{…}, or each side of every = and +
    /// when none are named) appear one by one and light up on beats.
    struct Equation: Equatable {
        struct Term: Equatable {
            let id: String
            /// The words the voice says it with, so it appears on them; nil spreads it over the sentence.
            let say: String?
            /// How it is read aloud from the math itself.
            let words: String
        }
        let title: String
        let tex: String
        /// Every part, left to right.
        let terms: [Term]
        let highlight: String?
        let caption: String?
        /// Nil when the TeX is outside what Cookie typesets: the source is shown as written.
        let layout: CookieMath.Layout?
        let spoken: String
    }

    /// A simulation from the vetted library: the model picks it and sets numbers, Swift runs it.
    struct Sim: Equatable {
        struct Slider: Equatable {
            let param: String
            let label: String
            let unit: String
            let minimum: Double
            let maximum: Double
            let whole: Bool
        }
        let title: String
        let model: String
        /// Every parameter, each inside the model's range.
        let values: [String: Double]
        let sliders: [Slider]
        let running: Bool
    }

    enum Content: Equatable {
        case timeline(title: String, events: [Event])
        case steps(title: String, steps: [String])
        /// Nodes in reveal order (by rank), each node's rank, and whether ranks run left→right.
        case flow(title: String, nodes: [Node], edges: [Edge], rank: [String: Int], across: Bool)
        case list(title: String, items: [String])
        case compare(title: String, columns: [Column])
        case number(value: String, label: String, caption: String?)
        case chart(Chart)
        /// A stack, top layer first.
        case layers(title: String, layers: [Node])
        /// Steps that come round again: the last leads back to the first.
        case cycle(title: String, steps: [Node])
        /// One root, breadth first; every other node names its parent.
        case tree(title: String, nodes: [Node])
        case equation(Equation)
        case sim(Sim)
    }

    /// One thing that appears on its own beat.
    enum Element: Equatable {
        case title
        case row(Int)
        case node(String)
        case edge(Int)
        /// A comparison column's heading, then each of its points.
        case heading(Int)
        case point(column: Int, index: Int)
        case value, label, caption
        /// A chart's axes and sliders, then each line, set of dots or bar.
        case axes
        case series(String)
    }

    /// The picture at each moment; a card without `states` has one.
    let states: [Content]
    /// Each state's `at` phrase: the spoken words it arrives on (nil for the first, and where none was given).
    let cues: [String?]
    /// UTF-16 offset in the spoken text where the tag sat (`CookieSpeechClock` units).
    var offset = 0

    var content: Content { states[0] }

    // MARK: Limits

    static let maxRows = 6
    static let maxListItems = 7
    static let maxNodes = 6
    static let maxTreeNodes = 10
    static let maxTreeDepth = 4
    static let maxEdges = 8
    static let maxPoints = 5
    static let maxStates = 6
    static let maxSliders = 4
    static let maxSeries = 3
    static let maxBars = 8
    static let maxChartPoints = 60
    static let titleLength = 60
    static let shortLength = 28
    static let lineLength = 90

    /// The card a CARD tag describes — inline JSON, or `#id` for one `build_visual` built — or nil
    /// when it can't be shown.
    init?(tag: CookieReplyTag) {
        guard tag.kind == "CARD" else { return nil }
        let body = tag.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = body.hasPrefix("#") ? CookieBuiltVisuals.card(String(body.dropFirst())) : Self.read(body).card
        guard let found else { return nil }
        self = found
        self.offset = tag.offset
    }

    init(content: Content, offset: Int = 0) {
        self.init(states: [content], cues: [nil], offset: offset)
    }

    init(states: [Content], cues: [String?], offset: Int = 0) {
        self.states = states
        self.cues = cues
        self.offset = offset
    }

    /// Everything the card shows at first, in the order it appears.
    var elements: [Element] { Self.elements(of: content) }

    static func elements(of content: Content) -> [Element] {
        switch content {
        case .timeline(_, let events): return [.title] + events.indices.map(Element.row)
        case .steps(_, let steps): return [.title] + steps.indices.map(Element.row)
        case .list(_, let items): return [.title] + items.indices.map(Element.row)
        case .compare(_, let columns):
            return [.title] + columns.indices.flatMap { column in
                [Element.heading(column)] + columns[column].points.indices.map { Element.point(column: column, index: $0) }
            }
        case .number(_, _, let caption): return caption == nil ? [.value, .label] : [.value, .label, .caption]
        case .flow(_, let nodes, let edges, _, _):
            // Each node, then any arrow whose two ends are now both on the card.
            var shown = Set<String>(), drawn = Set<Int>(), order: [Element] = [.title]
            for node in nodes {
                shown.insert(node.id)
                order.append(.node(node.id))
                for (index, edge) in edges.enumerated() where !drawn.contains(index) && shown.contains(edge.from) && shown.contains(edge.to) {
                    drawn.insert(index)
                    order.append(.edge(index))
                }
            }
            return order
        case .chart(let chart):
            return [.title, .axes] + chart.series.map { Element.series($0.id) } + (chart.source == nil ? [] : [.caption])
        case .layers(_, let layers):
            return [.title] + layers.map { Element.node($0.id) }
        case .cycle(_, let steps):
            // Each step, the arrow into it, and last the arrow that closes the loop.
            var order: [Element] = [.title]
            for index in steps.indices {
                order.append(.node(steps[index].id))
                if index > 0 { order.append(.edge(index - 1)) }
            }
            return order + [.edge(steps.count - 1)]
        case .tree(_, let nodes):
            // Breadth first, each node then the line from its parent (edge n is node n's).
            return [.title] + nodes.indices.flatMap { index in
                index == 0 ? [Element.node(nodes[0].id)] : [Element.node(nodes[index].id), .edge(index)]
            }
        case .equation(let equation):
            // What belongs to no part first (an = sign, the bars), then each part left to right.
            guard let layout = equation.layout else { return [.title, .value] + (equation.caption == nil ? [] : [.caption]) }
            let loose = layout.pieces.contains { $0.term == nil }
            return [.title] + (loose ? [.value] : []) + equation.terms.map { Element.node($0.id) } + (equation.caption == nil ? [] : [.caption])
        case .sim:
            // The picture (which starts it moving), then its readouts and controls.
            return [.title, .value, .caption]
        }
    }

    /// The objects Cookie's hand can point at ([TEACH:id]) and next/previous steps through.
    static func nodes(of content: Content) -> [Node] {
        switch content {
        case .flow(_, let nodes, _, _, _), .layers(_, let nodes), .cycle(_, let nodes), .tree(_, let nodes): return nodes
        case .equation(let equation): return equation.terms.map { Node(id: $0.id, label: $0.say ?? $0.words) }
        default: return []
        }
    }

    var nodes: [Node] { Self.nodes(of: content) }

    /// What VoiceOver reads when the card appears: the card is drawn, so it is said too.
    var spokenSummary: String {
        Self.summary(content) + (states.count > 1 ? ". It changes through \(states.count) stages" : "")
    }

    static func summary(_ content: Content) -> String {
        switch content {
        case .timeline(let title, let events): return ([title] + events.map { "\($0.when), \($0.label)" }).joined(separator: ". ")
        case .steps(let title, let steps): return ([title] + steps.enumerated().map { "Step \($0.offset + 1), \($0.element)" }).joined(separator: ". ")
        case .list(let title, let items): return ([title] + items).joined(separator: ". ")
        case .compare(let title, let columns): return ([title] + columns.map { "\($0.heading): \($0.points.joined(separator: ", "))" }).joined(separator: ". ")
        case .number(let value, let label, let caption): return [value, label, caption].compactMap { $0 }.joined(separator: ". ")
        case .flow(let title, let nodes, let edges, _, _):
            let names = Dictionary(nodes.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
            return ([title] + edges.map { "\(names[$0.from] ?? $0.from) to \(names[$0.to] ?? $0.to)" }).joined(separator: ". ")
        case .layers(let title, let layers):
            return ([title + ", top to bottom"] + layers.map { [$0.label, $0.note].compactMap { $0 }.joined(separator: ", ") }).joined(separator: ". ")
        case .cycle(let title, let steps):
            return ([title] + steps.map(\.label) + ["then back to \(steps.first?.label ?? "the start")"]).joined(separator: ". ")
        case .tree(let title, let nodes):
            let names = Dictionary(nodes.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
            return ([title, nodes.first?.label ?? ""] + nodes.dropFirst().map { "\(names[$0.parent ?? ""] ?? "") has \($0.label)" }).joined(separator: ". ")
        case .chart(let chart):
            let plots = chart.plots(chart.sliders.map(\.value))
            let what: [String] = plots.map { plot in
                if chart.style == .bar { return "\(plot.label) \(Self.format(Double(plot.points.first?.y ?? 0)))" }
                guard let first = plot.points.first, let last = plot.points.last else { return plot.label }
                return "\(plot.label) from \(Self.format(Double(first.y))) to \(Self.format(Double(last.y)))"
            }
            let axes = [chart.xLabel.map { "across, \($0)" }, "up, \(chart.yLabel)"].compactMap { $0 }.joined(separator: "; ")
            return ([chart.title, "A \(chart.style.rawValue) chart, \(axes)"] + what + [chart.source.map { "Source: \($0)" }].compactMap { $0 })
                .joined(separator: ". ")
        case .equation(let equation):
            return [equation.title, equation.spoken, equation.caption].compactMap { $0 }.joined(separator: ". ")
        case .sim(let sim):
            guard let model = CookieSim.models[sim.model] else { return sim.title }
            let settings = model.params.map { "\($0.label) \(Self.format(sim.values[$0.id] ?? $0.value))\($0.unit.isEmpty ? "" : " " + $0.unit)" }
            return "\(sim.title). A simulation of \(model.noun): " + settings.joined(separator: ", ")
        }
    }

    /// A number the way a chart labels it: up to three significant decimals, no trailing zeros.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        let magnitude = abs(value)
        let digits = magnitude >= 100 ? 0 : magnitude >= 10 ? 1 : magnitude >= 1 ? 2 : 3
        return value.formatted(.number.precision(.fractionLength(0...digits)))
    }

    // MARK: Timing

    /// Where on the speech clock each element appears: the first at the tag, the rest spread
    /// evenly over the sentence after it (to that sentence's end, or the next card's tag). Named
    /// objects (nodes, layers, steps of a cycle) come on their own words.
    func revealOffsets(in spoken: String, nextCardOffset: Int?) -> [Int] {
        if case .equation(let equation) = content { return equationOffsets(equation, in: spoken, nextCardOffset: nextCardOffset) }
        let named = nodes
        guard !named.isEmpty else {
            return Self.beats(elements.count, from: offset, in: spoken, until: nextCardOffset)
        }
        let cues = Self.namedBeats(named.map(\.label), from: offset, in: spoken)
        let positions = Dictionary(zip(named.map(\.id), cues.dropFirst()), uniquingKeysWith: { first, _ in first })
        var last = offset
        return elements.map { element in
            if case .node(let id) = element { last = max(last, positions[id] ?? last) }
            return last
        }
    }

    /// An equation's parts: its frame at the tag, each named part on the first place its words are said
    /// after the tag, the rest spread over the sentence; never earlier than the part before it.
    private func equationOffsets(_ equation: Equation, in spoken: String, nextCardOffset: Int?) -> [Int] {
        let even = Self.beats(elements.count, from: offset, in: spoken, until: nextCardOffset)
        let text = spoken as NSString
        let start = min(max(0, offset), text.length)
        var last = offset
        return elements.enumerated().map { index, element in
            // The frame (the = sign, the bars) comes with the title; parts on their words or spread.
            var at = element == .value ? offset : even[index]
            if case .node(let id) = element, let say = equation.terms.first(where: { $0.id == id })?.say {
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: say) + "(?![\\p{L}\\p{N}])"
                let match = text.range(of: pattern, options: [.caseInsensitive, .regularExpression], range: NSRange(location: start, length: text.length - start))
                if match.location != NSNotFound { at = match.location }
            }
            last = max(last, at)
            return last
        }
    }

    /// Where each state after the first arrives: on its `at` phrase, found in the words after
    /// `start` (folded the way labels are matched, so curly quotes and case don't matter). A
    /// phrase that isn't there, or a state without one, is spaced evenly between its neighbours,
    /// and the end of the words closes the last gap.
    func stateOffsets(in spoken: String, after start: Int) -> (offsets: [Int], unmatched: [Int]) {
        guard states.count > 1 else { return ([], []) }
        let folded = Folded([spoken])
        let utf16 = spoken.utf16
        func offset(ofFolded index: Int) -> Int {
            utf16.distance(from: spoken.startIndex, to: folded.origins[index].range.lowerBound)
        }
        var cursor = start
        var found: [Int?] = []
        var unmatched: [Int] = []
        for state in 1..<states.count {
            guard let cue = cues[state], !cue.isEmpty else { found.append(nil); unmatched.append(state + 1); continue }
            let needle = Folded([cue]).characters
            let match = folded.ranges(of: needle).first { range in
                let at = offset(ofFolded: range.lowerBound)
                let before = range.lowerBound == 0 || !(folded.characters[range.lowerBound - 1].isLetter || folded.characters[range.lowerBound - 1].isNumber)
                let after = range.upperBound == folded.characters.count
                    || !(folded.characters[range.upperBound].isLetter || folded.characters[range.upperBound].isNumber)
                return at >= cursor && before && after
            }
            if let match {
                cursor = offset(ofFolded: match.lowerBound)
                found.append(cursor)
            } else {
                found.append(nil)
                unmatched.append(state + 1)
            }
        }
        // Fill each run of unknowns evenly between the known places either side.
        let end = max(start, utf16.count)
        var result = found
        var index = 0
        while index < result.count {
            guard result[index] == nil else { index += 1; continue }
            var stop = index
            while stop < result.count, result[stop] == nil { stop += 1 }
            let low = index == 0 ? start : result[index - 1]!
            let high = stop < result.count ? result[stop]! : end
            let gaps = stop - index + 1
            for slot in index..<stop { result[slot] = low + (high - low) * (slot - index + 1) / gaps }
            index = stop
        }
        return (result.map { $0! }, unmatched)
    }

    /// Bind each named object to its actual words, across sentence boundaries.
    static func namedBeats(_ names: [String], from offset: Int, in spoken: String) -> [Int] {
        let text = spoken as NSString
        var cursor = min(max(0, offset), text.length)
        var result = [cursor]
        for name in names {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])"
            let match = text.range(of: pattern, options: [.caseInsensitive, .regularExpression],
                                   range: NSRange(location: cursor, length: text.length - cursor))
            if match.location != NSNotFound {
                result.append(match.location)
                cursor = NSMaxRange(match)
            } else { result.append(result.last ?? cursor) }
        }
        return result
    }

    /// `count` places on the speech clock: the first at `offset`, the rest spread evenly over the
    /// sentence after it (to that sentence's end, or `next` if sooner). Scenes keep time the same way.
    static func beats(_ count: Int, from offset: Int, in spoken: String, until next: Int?) -> [Int] {
        let units = Array(spoken.utf16)
        let start = min(offset, units.count)
        let end = min(next ?? units.count, sentenceEnd(in: units, from: start))
        guard count > 1 else { return [start] }
        let span = max(0, end - start)
        return (0..<count).map { start + span * $0 / count }
    }

    /// The end of the sentence that follows `start`. Punctuation right at the tag ("here's how [CARD …].")
    /// closes the sentence the tag ended, so the sentence after it is the one used.
    private static func sentenceEnd(in units: [UInt16], from start: Int) -> Int {
        let stops: Set<UInt16> = [46, 33, 63] // . ! ?
        var index = start
        while index < units.count {
            let isStop = stops.contains(units[index])
            let atBoundary = index + 1 == units.count || [32, 10, 9].contains(units[index + 1])
            if isStop && atBoundary && index - start >= 12 { return index + 1 }
            index += 1
        }
        return units.count
    }
}

// MARK: - Chart numbers

extension CookieCard.Chart {
    /// One drawn series: its points in data units (a bar's single point is (its index, its value)).
    struct Plot: Equatable {
        let id: String
        let label: String
        let points: [CGPoint]
    }

    /// Every series at these slider values (in slider order). A formula sample that has no value
    /// (a division by zero at one x) is left out of its line, not drawn as zero.
    func plots(_ values: [Double]) -> [Plot] {
        series.enumerated().map { index, series in
            if style == .bar {
                let value = series.formula.flatMap { Self.evaluate($0, sliders: values, x: Double(index)) } ?? series.value ?? 0
                return Plot(id: series.id, label: series.label, points: [CGPoint(x: Double(index), y: value)])
            }
            guard let formula = series.formula else { return Plot(id: series.id, label: series.label, points: series.points) }
            let points: [CGPoint] = (0..<Self.samples).compactMap { step in
                let x = series.from + (series.to - series.from) * Double(step) / Double(Self.samples - 1)
                return Self.evaluate(formula, sliders: values, x: x).map { CGPoint(x: x, y: $0) }
            }
            return Plot(id: series.id, label: series.label, points: points)
        }
    }

    /// A formula through the sheet engine diagrams' sliders use (`CookieSheet`): sliders are A1–A4
    /// in order, x is B1. Nil when it has no value there.
    static func evaluate(_ formula: String, sliders: [Double], x: Double) -> Double? {
        if case .success(let value) = value(formula, sliders: sliders, x: x) { return value }
        return nil
    }

    static func value(_ formula: String, sliders: [Double], x: Double) -> CookieSheet.Value {
        var grid = Array(repeating: [""], count: max(1, sliders.count))
        for (row, value) in sliders.enumerated() { grid[row][0] = String(value) }
        grid[0] += [String(x), formula]
        return CookieSheet(grid: grid).value(row: 0, column: 2)
    }
}

// MARK: - Reading

/// What reading a card's JSON found: the card when it can be shown, what was repaired on the way
/// in, and what couldn't be, each naming its field so the model can fix it.
struct CookieCardReading {
    var card: CookieCard?
    var repairs: [String] = []
    var errors: [String] = []
}

extension CookieCard {
    /// The fields each kind may carry. Others are ignored, and the repair says so.
    static let fields: [String: Set<String>] = {
        let shared: Set<String> = ["kind", "id", "states"]
        let own: [String: Set<String>] = [
            "timeline": ["title", "events"],
            "steps": ["title", "steps"],
            "flow": ["title", "nodes", "edges"],
            "list": ["title", "items"],
            "compare": ["title", "columns"],
            "number": ["value", "label", "caption"],
            "chart": ["title", "style", "xLabel", "yLabel", "series", "sliders", "source"],
            "layers": ["title", "layers"],
            "cycle": ["title", "steps"],
            "tree": ["title", "nodes"],
            "equation": ["title", "tex", "terms", "highlight", "caption"],
            "sim": ["title", "model", "params", "sliders", "running"],
        ]
        return own.mapValues { $0.union(shared) }
    }()

    /// Kinds whose elements have ids, so a state can move them; the others can't morph.
    static let morphing: Set<String> = ["flow", "chart", "layers", "cycle", "tree", "equation", "sim"]

    /// Names a model reaches for that mean one of the kinds.
    static let kindAliases: [String: String] = [
        "diagram": "flow", "process": "flow", "graph": "chart", "plot": "chart", "bar": "chart", "line": "chart",
        "stack": "layers", "architecture": "layers", "loop": "cycle", "hierarchy": "tree", "bullets": "list",
        "checklist": "steps", "comparison": "compare", "stat": "number", "events": "timeline",
        "math": "equation", "formula": "equation", "latex": "equation", "tex": "equation",
        "simulation": "sim", "physics": "sim", "model": "sim",
    ]

    /// Reads card JSON forgivingly (Global rule 2): the card, every repair, and the errors that stop it.
    static func read(_ json: String) -> CookieCardReading {
        var reader = CookieCardReader()
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return CookieCardReading(card: nil, errors: ["card: not a JSON object"])
        }
        let card = reader.card(object)
        return CookieCardReading(card: card, repairs: reader.repairs, errors: card == nil ? reader.errors : [])
    }
}

/// The forgiving reader. Every change it makes to what was written is a repair; anything it
/// can't make sense of is an error naming the field (`nodes[2].label: required`).
private struct CookieCardReader {
    typealias Card = CookieCard
    var repairs: [String] = []
    var errors: [String] = []

    mutating func card(_ object: [String: Any]) -> CookieCard? {
        guard var kind = (object["kind"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !kind.isEmpty else {
            errors.append("kind: required, one of " + Card.fields.keys.sorted().joined(separator: ", "))
            return nil
        }
        if Card.fields[kind] == nil, let alias = Card.kindAliases[kind] {
            repairs.append("kind: read \"\(kind)\" as \"\(alias)\"")
            kind = alias
        }
        guard let allowed = Card.fields[kind] else {
            errors.append("kind: \"\(kind)\" isn't a card; use one of " + Card.fields.keys.sorted().joined(separator: ", "))
            return nil
        }
        for key in object.keys.sorted() where !allowed.contains(key) { repairs.append("\(key): not a \(kind) field, ignored") }
        guard let first = content(kind, object, path: "") else { return nil }
        var states = [first], cues: [String?] = [nil]
        if let raw = object["states"] {
            readStates(raw, kind: kind, base: object, allowed: allowed, into: &states, cues: &cues)
        }
        return CookieCard(states: states, cues: cues)
    }

    /// States: each one the fields that change from the state before (the first from the card's own
    /// fields), plus `at`, the words it arrives on.
    private mutating func readStates(_ raw: Any, kind: String, base: [String: Any], allowed: Set<String>,
                                     into states: inout [Card.Content], cues: inout [String?]) {
        guard Card.morphing.contains(kind) else {
            repairs.append("states: a \(kind) card can't change between states, so it shows as one")
            return
        }
        guard var list = raw as? [Any] else { repairs.append("states: not a list, ignored"); return }
        if list.count > Card.maxStates {
            repairs.append("states: kept the first \(Card.maxStates) of \(list.count)")
            list = Array(list.prefix(Card.maxStates))
        }
        guard list.count >= 2 else { repairs.append("states: needs two to six, so the card shows as one"); return }
        var merged = base
        merged.removeValue(forKey: "states")
        var parsed: [Card.Content] = [], parsedCues: [String?] = []
        for (index, entry) in list.enumerated() {
            let path = "states[\(index)]"
            guard let state = entry as? [String: Any] else { repairs.append("\(path): not an object, left out"); continue }
            for key in state.keys.sorted() where key != "at" && (!allowed.contains(key) || key == "kind" || key == "states" || key == "id") {
                repairs.append("\(path).\(key): not something a state can change, ignored")
            }
            for (key, value) in state where key != "at" && allowed.contains(key) && !["kind", "states", "id"].contains(key) {
                // A sim state's params change only the ones it names; the rest stay as they were.
                if key == "params", let old = merged[key] as? [String: Any], let new = value as? [String: Any] {
                    merged[key] = old.merging(new) { _, newer in newer }
                } else { merged[key] = value }
            }
            // A state's own trouble drops that state, not the card.
            var inner = CookieCardReader()
            guard let content = inner.content(kind, merged, path: path + ".") else {
                repairs.append("\(path): left out (" + inner.errors.joined(separator: "; ") + ")")
                continue
            }
            if index == 0, state["at"] != nil { repairs.append("\(path).at: the first state shows at the tag, its at is ignored") }
            let cue = index == 0 ? nil : inner.text(state["at"], "\(path).at", limit: Card.lineLength, required: false)
            // A repair to a field every state inherits is said once, not once per state.
            func bare(_ repair: String) -> String {
                repair.replacingOccurrences(of: #"^states\[[0-9]+\]\."#, with: "", options: .regularExpression)
            }
            let known = Set(repairs.map(bare))
            repairs += inner.repairs.filter { !known.contains(bare($0)) || $0.hasPrefix(path + ".at") }
            parsed.append(content)
            parsedCues.append(cue)
        }
        guard parsed.count >= 2 else { repairs.append("states: fewer than two could be read, so the card shows as one"); return }
        states = parsed
        cues = parsedCues
    }

    // MARK: Values

    /// Trimmed text within `limit` characters: a number becomes its text, longer text is shortened at a word.
    mutating func text(_ value: Any?, _ field: String, limit: Int, required: Bool = true) -> String? {
        var text: String
        if let string = value as? String { text = string }
        else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { text = Card.format(number.doubleValue) }
        else {
            if value != nil && !(value is NSNull) { errors.append("\(field): should be text") }
            else if required { errors.append("\(field): required") }
            return nil
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if required { errors.append("\(field): required") }
            return nil
        }
        guard text.count > limit else { return text }
        var cut = String(text.prefix(limit - 1))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 { cut = String(cut[..<space]) }
        repairs.append("\(field): shortened to \(limit) characters")
        return cut.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
    }

    func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue.isFinite ? number.doubleValue : nil }
        if let text = value as? String, let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite { return number }
        return nil
    }

    /// A list with between `range` entries: too many are cut (a repair), too few is an error.
    mutating func list(_ value: Any?, _ field: String, _ range: ClosedRange<Int>) -> [Any]? {
        guard let list = value as? [Any] else {
            errors.append("\(field): required, a list of \(range.lowerBound) to \(range.upperBound)")
            return nil
        }
        guard list.count >= range.lowerBound else {
            errors.append("\(field): needs at least \(range.lowerBound), has \(list.count)")
            return nil
        }
        if list.count > range.upperBound {
            repairs.append("\(field): kept the first \(range.upperBound) of \(list.count)")
            return Array(list.prefix(range.upperBound))
        }
        return list
    }

    /// A short id: text, or a number written bare.
    mutating func id(_ value: Any?, _ field: String) -> String? {
        text(value, field, limit: Card.shortLength)
    }

    /// An icon from the teaching set, or none (an unknown one goes, said).
    mutating func icon(_ value: Any?, _ field: String) -> String? {
        guard let icon = value as? String, !icon.isEmpty else { return nil }
        guard Card.teachingIcons.contains(icon) else {
            repairs.append("\(field): \"\(icon)\" isn't a teaching icon, left off")
            return nil
        }
        return icon
    }

    /// Labelled objects with unique ids; a repeated id is left out.
    mutating func nodes(_ value: Any?, _ field: String, _ range: ClosedRange<Int>, noted: Bool = false, parented: Bool = false) -> [Card.Node]? {
        guard let list = list(value, field, range) else { return nil }
        var nodes: [Card.Node] = []
        let before = errors.count
        for (index, entry) in list.enumerated() {
            let path = "\(field)[\(index)]"
            // A bare word is a node labelled by it.
            if let word = entry as? String, let label = text(word, path, limit: Card.shortLength) {
                let id = label.lowercased().replacingOccurrences(of: " ", with: "-")
                guard !nodes.contains(where: { $0.id == id }) else { repairs.append("\(path): repeats id \(id), left out"); continue }
                repairs.append("\(path): text, read as {id: \"\(id)\", label: \"\(label)\"}")
                nodes.append(Card.Node(id: id, label: label))
                continue
            }
            guard let object = entry as? [String: Any] else { errors.append("\(path): should be an object"); continue }
            guard let label = text(object["label"] ?? object["text"] ?? object["name"], "\(path).label", limit: Card.shortLength) else { continue }
            var id = object["id"].flatMap { self.id($0, "\(path).id") }
            if id == nil {
                id = label.lowercased().replacingOccurrences(of: " ", with: "-")
                repairs.append("\(path).id: missing, used \"\(id!)\"")
            }
            guard let id else { continue }
            guard !nodes.contains(where: { $0.id == id }) else { repairs.append("\(path): repeats id \(id), left out"); continue }
            nodes.append(Card.Node(id: id, label: label, icon: icon(object["icon"], "\(path).icon"),
                                   note: noted ? text(object["note"], "\(path).note", limit: 60, required: false) : nil,
                                   parent: parented ? text(object["parent"], "\(path).parent", limit: Card.shortLength, required: false) : nil))
        }
        guard errors.count == before, nodes.count >= range.lowerBound else {
            if errors.count == before { errors.append("\(field): needs at least \(range.lowerBound) with different ids") }
            return nil
        }
        return nodes
    }

    // MARK: Kinds

    mutating func content(_ kind: String, _ object: [String: Any], path: String) -> Card.Content? {
        let before = errors.count
        func title() -> String? { text(object["title"], path + "title", limit: Card.titleLength) }
        var result: Card.Content?
        switch kind {
        case "timeline":
            let title = title()
            guard let events = list(object["events"], path + "events", 1...Card.maxRows) else { return nil }
            let kept: [Card.Event] = events.enumerated().compactMap { index, entry in
                let field = "\(path)events[\(index)]"
                guard let event = entry as? [String: Any] else { errors.append("\(field): should be {label, when}"); return nil }
                let label = text(event["label"], field + ".label", limit: Card.lineLength)
                let when = text(event["when"], field + ".when", limit: Card.shortLength)
                guard let label, let when else { return nil }
                return Card.Event(label: label, when: when)
            }
            if let title, errors.count == before { result = .timeline(title: title, events: kept) }
        case "steps":
            let title = title()
            guard let steps = list(object["steps"], path + "steps", 1...Card.maxRows) else { return nil }
            let texts: [String] = steps.enumerated().compactMap { index, entry in
                let field = "\(path)steps[\(index)]"
                if entry is String { return text(entry, field, limit: Card.lineLength) }
                return text((entry as? [String: Any])?["text"], field + ".text", limit: Card.lineLength)
            }
            if let title, errors.count == before { result = .steps(title: title, steps: texts) }
        case "list":
            let title = title()
            guard let items = list(object["items"], path + "items", 1...Card.maxListItems) else { return nil }
            let texts = items.enumerated().compactMap { text($0.element, "\(path)items[\($0.offset)]", limit: Card.lineLength) }
            if let title, errors.count == before { result = .list(title: title, items: texts) }
        case "compare":
            let title = title()
            guard let columns = list(object["columns"], path + "columns", 2...3) else { return nil }
            let kept: [Card.Column] = columns.enumerated().compactMap { index, entry in
                let field = "\(path)columns[\(index)]"
                guard let column = entry as? [String: Any] else { errors.append("\(field): should be {heading, points}"); return nil }
                let heading = text(column["heading"], field + ".heading", limit: Card.shortLength)
                guard let points = list(column["points"], field + ".points", 1...Card.maxPoints) else { return nil }
                let texts = points.enumerated().compactMap { text($0.element, "\(field).points[\($0.offset)]", limit: Card.lineLength) }
                guard let heading else { return nil }
                return Card.Column(heading: heading, points: texts)
            }
            if let title, errors.count == before { result = .compare(title: title, columns: kept) }
        case "number":
            let value = text(object["value"], path + "value", limit: 16)
            let label = text(object["label"], path + "label", limit: Card.titleLength)
            let caption = text(object["caption"], path + "caption", limit: Card.lineLength, required: false)
            if let value, let label, errors.count == before { result = .number(value: value, label: label, caption: caption) }
        case "flow":
            result = flow(object, path: path)
        case "layers":
            let title = title()
            guard let layers = nodes(object["layers"], path + "layers", 2...Card.maxNodes, noted: true) else { return nil }
            if let title { result = .layers(title: title, layers: layers) }
        case "cycle":
            let title = title()
            guard let steps = nodes(object["steps"], path + "steps", 3...Card.maxNodes) else { return nil }
            if let title { result = .cycle(title: title, steps: steps) }
        case "tree":
            result = tree(object, path: path)
        case "chart":
            result = chart(object, path: path).map(Card.Content.chart)
        case "equation":
            result = equation(object, path: path).map(Card.Content.equation)
        case "sim":
            result = sim(object, path: path).map(Card.Content.sim)
        default:
            return nil
        }
        return errors.count == before ? result : nil
    }

    /// A flow is boxes joined by arrows with no loop back, so it can be laid out in ranks:
    /// each node one rank past the furthest node pointing at it (longest path).
    private mutating func flow(_ object: [String: Any], path: String) -> Card.Content? {
        let title = text(object["title"], path + "title", limit: Card.titleLength)
        guard let kept = nodes(object["nodes"], path + "nodes", 2...Card.maxNodes), let title else { return nil }
        let ids = Set(kept.map(\.id))
        var keptEdges: [Card.Edge] = []
        let edges = object["edges"] == nil ? [] : (list(object["edges"], path + "edges", 0...Card.maxEdges) ?? [])
        for (index, entry) in edges.enumerated() {
            let field = "\(path)edges[\(index)]"
            guard let edge = entry as? [String: Any], let from = edge["from"] as? String, let to = edge["to"] as? String else {
                errors.append("\(field): should be {from, to}")
                continue
            }
            guard ids.contains(from), ids.contains(to) else {
                repairs.append("\(field): \(ids.contains(from) ? to : from) isn't a node, arrow left out")
                continue
            }
            guard from != to else { repairs.append("\(field): points at itself, left out"); continue }
            guard !keptEdges.contains(where: { $0.from == from && $0.to == to }) else { repairs.append("\(field): repeated, left out"); continue }
            keptEdges.append(Card.Edge(from: from, to: to, label: text(edge["label"], field + ".label", limit: 20, required: false)))
        }
        // Kahn's order; a node never reached means a loop, and a loop has no left-to-right.
        var incoming = Dictionary(uniqueKeysWithValues: kept.map { ($0.id, 0) })
        keptEdges.forEach { incoming[$0.to, default: 0] += 1 }
        var ready = kept.map(\.id).filter { incoming[$0] == 0 }
        var rank = Dictionary(uniqueKeysWithValues: kept.map { ($0.id, 0) })
        var ordered: [String] = []
        while !ready.isEmpty {
            let id = ready.removeFirst()
            ordered.append(id)
            for edge in keptEdges where edge.from == id {
                rank[edge.to] = max(rank[edge.to] ?? 0, (rank[id] ?? 0) + 1)
                incoming[edge.to, default: 0] -= 1
                if incoming[edge.to] == 0 { ready.append(edge.to) }
            }
        }
        guard ordered.count == kept.count else {
            errors.append("\(path)edges: the arrows loop back; a flow runs one way (use kind \"cycle\" for a loop)")
            return nil
        }
        // Reveal by rank, keeping the written order within a rank.
        let byRank = kept.enumerated().sorted { (rank[$0.element.id] ?? 0, $0.offset) < (rank[$1.element.id] ?? 0, $1.offset) }.map(\.element)
        let ranks = (rank.values.max() ?? 0) + 1
        // Up to four ranks fit across a card; a longer chain runs top to bottom.
        return .flow(title: title, nodes: byRank, edges: keptEdges, rank: rank, across: ranks <= 4)
    }

    /// One root, every other node under a parent that exists, no loops, four levels at most.
    private mutating func tree(_ object: [String: Any], path: String) -> Card.Content? {
        let title = text(object["title"], path + "title", limit: Card.titleLength)
        guard let nodes = nodes(object["nodes"], path + "nodes", 2...Card.maxTreeNodes, parented: true), let title else { return nil }
        let ids = Set(nodes.map(\.id))
        var cleaned = nodes
        for (index, node) in nodes.enumerated() {
            if let parent = node.parent, !ids.contains(parent) || parent == node.id {
                errors.append("\(path)nodes[\(index)].parent: \(parent == node.id ? "a node can't be its own parent" : "\"\(parent)\" isn't a node")")
            }
            cleaned[index].parent = node.parent
        }
        let roots = cleaned.filter { $0.parent == nil }
        guard roots.count == 1 else {
            errors.append("\(path)nodes: a tree has one root (one node without a parent); found \(roots.isEmpty ? "none" : roots.map(\.id).joined(separator: ", "))")
            return nil
        }
        // Breadth first from the root; a node never reached sits in a loop of parents.
        var ordered = [roots[0]], depth = [roots[0].id: 0], index = 0
        while index < ordered.count {
            let current = ordered[index]
            for child in cleaned where child.parent == current.id {
                depth[child.id] = (depth[current.id] ?? 0) + 1
                ordered.append(child)
            }
            index += 1
        }
        guard ordered.count == cleaned.count else {
            errors.append("\(path)nodes: parents loop (\(cleaned.filter { depth[$0.id] == nil }.map(\.id).joined(separator: ", ")))")
            return nil
        }
        guard (depth.values.max() ?? 0) < Card.maxTreeDepth else {
            errors.append("\(path)nodes: \(Card.maxTreeDepth) levels at most")
            return nil
        }
        return .tree(title: title, nodes: ordered)
    }

    private mutating func chart(_ object: [String: Any], path: String) -> Card.Chart? {
        let before = errors.count
        let title = text(object["title"], path + "title", limit: Card.titleLength)
        let rawSeries = list(object["series"], path + "series", 1...Card.maxBars)
        var style: Card.Chart.Style
        let written = (object["style"] as? String)?.lowercased()
        switch written {
        case "line", "bar", "scatter": style = Card.Chart.Style(rawValue: written!)!
        case "column", "columns", "bars": style = .bar; repairs.append("\(path)style: read \"\(written!)\" as \"bar\"")
        case "dots", "points", "scatterplot": style = .scatter; repairs.append("\(path)style: read \"\(written!)\" as \"scatter\"")
        default:
            // Guessed from the data: bars carry a value, lines carry points.
            let firstSeries = rawSeries?.first as? [String: Any]
            style = firstSeries?["value"] != nil ? .bar : .line
            repairs.append("\(path)style: \(written.map { "\"\($0)\" isn't a style" } ?? "missing"), drew it as \(style.rawValue)")
        }
        let xLabel = text(object["xLabel"], path + "xLabel", limit: Card.shortLength, required: style != .bar)
        let yLabel = text(object["yLabel"], path + "yLabel", limit: Card.shortLength)
        let source = text(object["source"], path + "source", limit: Card.lineLength, required: false)

        // Sliders first: formulas are checked against them.
        var sliders: [Card.Chart.Slider] = []
        if object["sliders"] != nil, let raw = list(object["sliders"], path + "sliders", 0...Card.maxSliders) {
            for (index, entry) in raw.enumerated() {
                let field = "\(path)sliders[\(index)]"
                guard let slider = entry as? [String: Any] else { errors.append("\(field): should be {id, label, minimum, maximum, value}"); continue }
                let label = text(slider["label"], field + ".label", limit: 20)
                let id = slider["id"].flatMap { self.id($0, field + ".id") } ?? "s\(index + 1)"
                var low = number(slider["minimum"]), high = number(slider["maximum"])
                if low == nil, let alias = number(slider["min"]) { low = alias; repairs.append("\(field): read min as minimum") }
                if high == nil, let alias = number(slider["max"]) { high = alias; repairs.append("\(field): read max as maximum") }
                guard var low, var high else { errors.append("\(field): needs minimum and maximum numbers"); continue }
                if low > high { swap(&low, &high); repairs.append("\(field): minimum and maximum were swapped") }
                guard high > low else { errors.append("\(field): minimum and maximum are the same"); continue }
                var value = number(slider["value"]) ?? (low + high) / 2
                if slider["value"] == nil { repairs.append("\(field).value: missing, started in the middle") }
                if value < low || value > high {
                    value = min(high, max(low, value))
                    repairs.append("\(field).value: brought inside \(Card.format(low))–\(Card.format(high))")
                }
                guard let label else { continue }
                sliders.append(.init(id: id, label: label, minimum: low, maximum: high, value: value,
                                     unit: text(slider["unit"], field + ".unit", limit: 8, required: false)))
            }
        }

        var series: [Card.Chart.Series] = []
        let limit = style == .bar ? Card.maxBars : Card.maxSeries
        let entries = Array((rawSeries ?? []).prefix(limit))
        if let rawSeries, rawSeries.count > limit { repairs.append("\(path)series: kept the first \(limit) of \(rawSeries.count)") }
        for (index, entry) in entries.enumerated() {
            let field = "\(path)series[\(index)]"
            guard let item = entry as? [String: Any] else { errors.append("\(field): should be an object"); continue }
            guard let label = text(item["label"] ?? item["name"], field + ".label", limit: Card.shortLength) else { continue }
            let id = item["id"].flatMap { self.id($0, field + ".id") } ?? label.lowercased()
            guard !series.contains(where: { $0.id == id }) else { repairs.append("\(field): repeats id \(id), left out"); continue }
            var one = Card.Chart.Series(id: id, label: label)
            if let raw = item["formula"] {
                guard let formula = self.formula(raw, field + ".formula", sliders: sliders.count) else { continue }
                one.formula = formula
                if style != .bar {
                    guard var from = number(item["from"]), var to = number(item["to"]) else {
                        errors.append("\(field): a formula line needs from and to (the x range)")
                        continue
                    }
                    if from > to { swap(&from, &to); repairs.append("\(field): from and to were swapped") }
                    guard to > from else { errors.append("\(field): from and to are the same"); continue }
                    one.from = from; one.to = to
                }
            } else if style == .bar {
                guard let value = number(item["value"]) else { errors.append("\(field).value: a bar needs a number (or a formula)"); continue }
                one.value = value
            } else {
                guard let raw = item["points"] as? [Any] else { errors.append("\(field).points: needs [[x, y], …] (or a formula)"); continue }
                var points: [CGPoint] = []
                for (at, point) in raw.prefix(Card.maxChartPoints).enumerated() {
                    let pair: (Double?, Double?)
                    if let list = point as? [Any], list.count == 2 { pair = (number(list[0]), number(list[1])) }
                    else if let object = point as? [String: Any] { pair = (number(object["x"]), number(object["y"])) }
                    else { pair = (nil, nil) }
                    guard let x = pair.0, let y = pair.1 else { errors.append("\(field).points[\(at)]: should be [x, y] numbers"); continue }
                    points.append(CGPoint(x: x, y: y))
                }
                if raw.count > Card.maxChartPoints { repairs.append("\(field).points: kept the first \(Card.maxChartPoints) of \(raw.count)") }
                guard points.count >= (style == .line ? 2 : 1) else {
                    errors.append("\(field).points: a \(style.rawValue) needs at least \(style == .line ? 2 : 1)")
                    continue
                }
                if style == .line, points != points.sorted(by: { $0.x < $1.x }) {
                    points.sort { $0.x < $1.x }
                    repairs.append("\(field).points: put in order of x")
                }
                one.points = points
            }
            series.append(one)
        }
        if object["sliders"] != nil, !sliders.isEmpty, !series.contains(where: { $0.formula != nil }) {
            repairs.append("\(path)sliders: no series uses a formula, so the sliders change nothing; left off")
            sliders = []
        }
        guard errors.count == before, let title, let yLabel, !series.isEmpty else {
            if errors.count == before && series.isEmpty { errors.append("\(path)series: nothing to draw") }
            return nil
        }
        var chart = Card.Chart(title: title, style: style, xLabel: xLabel, yLabel: yLabel, series: series, sliders: sliders, source: source)
        // The ranges cover every slider at both ends (the others where they start), so dragging never rescales.
        var settings = [sliders.map(\.value)]
        for index in sliders.indices {
            for end in [sliders[index].minimum, sliders[index].maximum] {
                var values = sliders.map(\.value)
                values[index] = end
                settings.append(values)
            }
        }
        let all = settings.flatMap { chart.plots($0) }
        let empty = chart.plots(sliders.map(\.value)).filter(\.points.isEmpty).map(\.id)
        guard empty.isEmpty else {
            let reason = series.first { empty.contains($0.id) }?.formula.map { Card.Chart.value($0, sliders: sliders.map(\.value), x: 0) }
            let detail: String
            if case .failure(let message) = reason { detail = message } else { detail = "no value" }
            errors.append("\(path)series: \(empty.joined(separator: ", ")) has no point to draw (\(detail))")
            return nil
        }
        let skipped = chart.plots(sliders.map(\.value)).enumerated().filter { index, plot in
            series[index].formula != nil && style != .bar && plot.points.count < Card.Chart.samples
        }.map(\.element.id)
        if !skipped.isEmpty { repairs.append("\(path)series: \(skipped.joined(separator: ", ")) skips x values where its formula has no value") }
        let points = all.flatMap(\.points)
        let xs = style == .bar ? [-0.5, Double(series.count) - 0.5] : points.map { Double($0.x) }
        var ys = points.map { Double($0.y) }
        if style == .bar { ys.append(0) }
        chart.xRange = Self.nice(xs.min() ?? 0, xs.max() ?? 1, pad: style == .scatter ? 0.05 : 0, round: style != .bar)
        chart.yRange = Self.nice(ys.min() ?? 0, ys.max() ?? 1, pad: 0.06, round: true)
        return chart
    }

    /// An equation: the TeX typeset here, so what can't be drawn is known now (and shown as written,
    /// a repair, not an error); terms name the words each part is said with.
    private mutating func equation(_ object: [String: Any], path: String) -> Card.Equation? {
        let title = text(object["title"], path + "title", limit: Card.titleLength)
        var raw = object["tex"]
        if raw == nil {
            for alias in ["latex", "math", "formula", "equation"] where object[alias] != nil {
                raw = object[alias]
                repairs.append("\(path)tex: read \(alias) as tex")
                break
            }
        }
        guard let tex = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !tex.isEmpty else {
            errors.append("\(path)tex: required, the equation in TeX, e.g. \"F = \\\\id{m}{m}\\\\id{a}{a}\"")
            return nil
        }
        let caption = text(object["caption"], path + "caption", limit: Card.lineLength, required: false)
        guard let title else { return nil }
        let typeset = CookieMath.typeset(tex)
        repairs += typeset.repairs.map { path + $0 }
        if let failure = typeset.failure { repairs.append("\(path)tex: \(failure), so it is shown as written") }
        // Words for each part, from `terms`: [{id, say}] or {id: say}.
        var said: [String: String] = [:]
        if let list = object["terms"] as? [Any] {
            for (index, entry) in list.enumerated() {
                let field = "\(path)terms[\(index)]"
                guard let item = entry as? [String: Any], let id = item["id"].flatMap({ self.id($0, field + ".id") }) else {
                    repairs.append("\(field): should be {id, say}, left out")
                    continue
                }
                if let say = text(item["say"] ?? item["label"] ?? item["words"], field + ".say", limit: Card.shortLength, required: false) { said[id] = say }
            }
        } else if let map = object["terms"] as? [String: Any] {
            for key in map.keys.sorted() {
                if let say = text(map[key], "\(path)terms.\(key)", limit: Card.shortLength, required: false) { said[key] = say }
            }
        } else if object["terms"] != nil { repairs.append("\(path)terms: should be a list of {id, say}, ignored") }
        let order = typeset.layout?.order ?? []
        for id in said.keys.sorted() where !order.contains(id) {
            repairs.append("\(path)terms: \(id) isn't a part of the equation (mark one with \\id{\(id)}{…}), ignored")
        }
        var highlight = text(object["highlight"], path + "highlight", limit: Card.shortLength, required: false)
        if let wanted = highlight, !order.contains(wanted) {
            repairs.append("\(path)highlight: \(wanted) isn't a part of the equation, ignored")
            highlight = nil
        }
        let terms = order.map { Card.Equation.Term(id: $0, say: said[$0], words: typeset.termWords[$0] ?? $0) }
        return Card.Equation(title: title, tex: tex, terms: terms, highlight: highlight, caption: caption,
                             layout: typeset.layout, spoken: typeset.failure == nil ? typeset.spoken : tex)
    }

    /// A simulation: one of the library's models, its numbers kept in the model's range, up to four
    /// sliders on its parameters.
    private mutating func sim(_ object: [String: Any], path: String) -> Card.Sim? {
        let title = text(object["title"], path + "title", limit: Card.titleLength)
        let names = CookieSim.models.keys.sorted().joined(separator: ", ")
        guard var name = (object["model"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else {
            errors.append("\(path)model: required, one of \(names)")
            return nil
        }
        if CookieSim.models[name] == nil, let alias = CookieSim.aliases[name] {
            repairs.append("\(path)model: read \"\(name)\" as \"\(alias)\"")
            name = alias
        }
        guard let model = CookieSim.models[name] else {
            errors.append("\(path)model: \"\(name)\" isn't in the library; use one of \(names)")
            return nil
        }
        var values = model.defaults
        if let params = object["params"] as? [String: Any] {
            for key in params.keys.sorted() {
                let field = "\(path)params.\(key)"
                guard let param = model.param(key) else {
                    repairs.append("\(field): \(model.id) has no such parameter (it has \(model.params.map(\.id).joined(separator: ", "))), ignored")
                    continue
                }
                if param.id != key.lowercased() { repairs.append("\(field): read as \(param.id)") }
                var given = number(params[key])
                if given == nil, param.id == "compounding", (params[key] as? String)?.lowercased() == "continuous" { given = 0 }
                guard let given else { repairs.append("\(field): not a number, kept \(Card.format(param.value))"); continue }
                let kept = param.clamp(given)
                if kept != given { repairs.append("\(field): brought inside \(Card.format(param.range.lowerBound))–\(Card.format(param.range.upperBound)) \(param.unit)".trimmingCharacters(in: .whitespaces)) }
                values[param.id] = kept
            }
        } else if object["params"] != nil { repairs.append("\(path)params: should be an object of numbers, ignored") }
        var sliders: [Card.Sim.Slider] = []
        if let raw = object["sliders"] {
            let list = (raw as? [Any]) ?? []
            if !(raw is [Any]) { repairs.append("\(path)sliders: should be a list, ignored") }
            if list.count > Card.maxSliders { repairs.append("\(path)sliders: kept the first \(Card.maxSliders) of \(list.count)") }
            for (index, entry) in list.prefix(Card.maxSliders).enumerated() {
                let field = "\(path)sliders[\(index)]"
                let item = entry as? [String: Any]
                let written = (entry as? String) ?? (item?["param"] ?? item?["id"]) as? String
                guard let written, let param = model.param(written) else {
                    repairs.append("\(field): \(model.id) has no parameter \"\((entry as? String) ?? (item?["param"] as? String) ?? "?")\", left off")
                    continue
                }
                guard !sliders.contains(where: { $0.param == param.id }) else { repairs.append("\(field): repeats \(param.id), left off"); continue }
                var low = number(item?["minimum"] ?? item?["min"]) ?? param.range.lowerBound
                var high = number(item?["maximum"] ?? item?["max"]) ?? param.range.upperBound
                if low > high { swap(&low, &high); repairs.append("\(field): minimum and maximum were swapped") }
                let clampedLow = max(param.range.lowerBound, low), clampedHigh = min(param.range.upperBound, high)
                if clampedLow != low || clampedHigh != high { repairs.append("\(field): kept inside \(param.id)'s safe range \(Card.format(param.range.lowerBound))–\(Card.format(param.range.upperBound))") }
                guard clampedHigh > clampedLow else { repairs.append("\(field): no range left to slide over, left off"); continue }
                let label = text(item?["label"], field + ".label", limit: 20, required: false) ?? param.label
                if let value = values[param.id], value < clampedLow || value > clampedHigh {
                    values[param.id] = min(clampedHigh, max(clampedLow, value))
                    repairs.append("\(field): \(param.id) brought inside the slider's range")
                }
                sliders.append(.init(param: param.id, label: label, unit: param.unit, minimum: clampedLow, maximum: clampedHigh, whole: param.whole))
            }
        }
        var running = true
        if let flag = object["running"] {
            if let bool = flag as? Bool { running = bool }
            else if let word = (flag as? String)?.lowercased(), ["true", "false", "run", "pause", "paused"].contains(word) {
                running = word == "true" || word == "run"
                repairs.append("\(path)running: read \"\(word)\" as \(running)")
            } else { repairs.append("\(path)running: should be true or false, kept true") }
        }
        guard let title else { return nil }
        return Card.Sim(title: title, model: model.id, values: values, sliders: sliders, running: running)
    }

    /// A formula the sheet engine can read, starting with "=": a bare `x` is B1, and only the
    /// sliders there are (A1…An) may be named.
    private mutating func formula(_ raw: Any, _ field: String, sliders: Int) -> String? {
        guard var formula = (raw as? String)?.trimmingCharacters(in: .whitespaces), !formula.isEmpty else {
            errors.append("\(field): should be text like \"=A1*B1\"")
            return nil
        }
        if !formula.hasPrefix("=") { formula = "=" + formula; repairs.append("\(field): added the leading =") }
        let bareX = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9$])[xX](?![A-Za-z0-9(])")
        let range = NSRange(location: 0, length: formula.utf16.count)
        if bareX.firstMatch(in: formula, range: range) != nil {
            formula = bareX.stringByReplacingMatches(in: formula, range: range, withTemplate: "B1")
            repairs.append("\(field): read x as B1")
        }
        let reference = try! NSRegularExpression(pattern: "(?<![A-Za-z])\\$?([A-Za-z]{1,3})\\$?([0-9]+)")
        for match in reference.matches(in: formula, range: NSRange(location: 0, length: formula.utf16.count)) {
            let column = (formula as NSString).substring(with: match.range(at: 1)).uppercased()
            let row = Int((formula as NSString).substring(with: match.range(at: 2))) ?? 0
            if column == "B" && row == 1 { continue }
            guard column == "A", (1...max(1, sliders)).contains(row), sliders > 0 else {
                errors.append("\(field): \(column)\(row) isn't an input; use A1–A\(max(1, sliders)) for the \(sliders) slider\(sliders == 1 ? "" : "s") and B1 (or x) for x")
                return nil
            }
        }
        if case .failure(let message) = Card.Chart.value(formula, sliders: Array(repeating: 1, count: sliders), x: 1), message != "#DIV/0!" {
            errors.append("\(field): \(message) (formulas use + - * / ( ) and SUM, AVERAGE, MIN, MAX, COUNT)")
            return nil
        }
        return formula
    }

    /// A range a little wider than the data, its ends on round steps (1, 2 or 5 of a power of ten,
    /// about four to a range); a range of numbers that are never negative starts at zero, not below.
    static func nice(_ low: Double, _ high: Double, pad: Double, round: Bool) -> ClosedRange<Double> {
        var low = low, high = high
        let positive = low >= 0
        if high - low < 1e-9 { low -= 1; high += 1 }
        let span = high - low
        low -= span * pad; high += span * pad
        if positive { low = max(0, low) }
        guard round else { return low...high }
        let rough = (high - low) / 4
        let magnitude = pow(10, floor(log10(rough)))
        let residual = rough / magnitude
        let step = (residual > 5 ? 10 : residual > 2 ? 5 : residual > 1 ? 2 : 1) * magnitude
        return (floor(low / step) * step)...(ceil(high / step) * step)
    }
}

// MARK: - Built visuals

/// Cards `build_visual` made this session, by id, for the reply's [CARD:#id]. A few dozen at most,
/// oldest out first; reachable from the card reader on any thread.
enum CookieBuiltVisuals {
    private static let lock = NSLock()
    private static var cards: [(id: String, card: CookieCard)] = []
    static let capacity = 24

    static func card(_ id: String) -> CookieCard? {
        lock.lock(); defer { lock.unlock() }
        return cards.last { $0.id == id }?.card
    }

    static func keep(_ card: CookieCard, id: String) {
        lock.lock(); defer { lock.unlock() }
        cards.removeAll { $0.id == id }
        cards.append((id, card))
        if cards.count > capacity { cards.removeFirst(cards.count - capacity) }
    }
}
