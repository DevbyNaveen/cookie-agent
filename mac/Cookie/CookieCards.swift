//
//  CookieCards.swift
//  Cookie
//
//  Explainer cards: a small closed catalog of pictures Cookie can put beside
//  what it says — a timeline, steps, a flow of boxes and arrows, a list, a
//  comparison, one big number. The model writes one inline as
//  [CARD {json}] at the word where it belongs; the card is read here into
//  exact Swift types and strictly checked. Anything that doesn't fit (an
//  unknown kind, too many rows, text too long for a card) drops the card,
//  never the reply: the words are still spoken.
//
//  Each card is a short list of elements (its title, then each row, node or
//  edge) revealed one by one on the speech clock, spread over the sentence
//  that follows the tag.
//

import Foundation

struct CookieCard: Equatable {
    struct Event: Codable, Equatable { let label: String; let when: String }
    struct Node: Codable, Equatable { let id: String; let label: String }
    struct Edge: Codable, Equatable { let from: String; let to: String; let label: String? }
    struct Column: Codable, Equatable { let heading: String; let points: [String] }

    enum Content: Equatable {
        case timeline(title: String, events: [Event])
        case steps(title: String, steps: [String])
        /// Nodes in reveal order (by rank), each node's rank, and whether ranks run left→right.
        case flow(title: String, nodes: [Node], edges: [Edge], rank: [String: Int], across: Bool)
        case list(title: String, items: [String])
        case compare(title: String, columns: [Column])
        case number(value: String, label: String, caption: String?)
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
    }

    let content: Content
    /// UTF-16 offset in the spoken text where the tag sat (`CookieSpeechClock` units).
    var offset = 0

    // MARK: Limits

    static let maxRows = 6
    static let maxListItems = 7
    static let maxNodes = 6
    static let maxEdges = 8
    static let maxPoints = 5
    static let titleLength = 60
    static let shortLength = 28
    static let lineLength = 90

    /// The card a CARD tag describes, or nil when it isn't one exactly.
    init?(tag: CookieReplyTag) {
        guard tag.kind == "CARD", let data = tag.body.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = try? JSONDecoder().decode(Raw.self, from: data),
              let allowed = Self.fields[raw.kind], Set(object.keys).isSubset(of: allowed),
              let content = Self.content(raw) else { return nil }
        self.content = content
        self.offset = tag.offset
    }

    init(content: Content, offset: Int = 0) {
        self.content = content
        self.offset = offset
    }

    /// Everything the card shows, in the order it appears.
    var elements: [Element] {
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
        }
    }

    /// What VoiceOver reads when the card appears: the card is drawn, so it is said too.
    var spokenSummary: String {
        switch content {
        case .timeline(let title, let events): return ([title] + events.map { "\($0.when), \($0.label)" }).joined(separator: ". ")
        case .steps(let title, let steps): return ([title] + steps.enumerated().map { "Step \($0.offset + 1), \($0.element)" }).joined(separator: ". ")
        case .list(let title, let items): return ([title] + items).joined(separator: ". ")
        case .compare(let title, let columns): return ([title] + columns.map { "\($0.heading): \($0.points.joined(separator: ", "))" }).joined(separator: ". ")
        case .number(let value, let label, let caption): return [value, label, caption].compactMap { $0 }.joined(separator: ". ")
        case .flow(let title, let nodes, let edges, _, _):
            let names = Dictionary(nodes.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
            return ([title] + edges.map { "\(names[$0.from] ?? $0.from) to \(names[$0.to] ?? $0.to)" }).joined(separator: ". ")
        }
    }

    // MARK: Reading

    /// The JSON as written; which fields count depends on `kind`.
    private struct Raw: Decodable {
        let kind: String
        let title: String?
        let events: [Event]?
        let steps: [Step]?
        let nodes: [Node]?
        let edges: [Edge]?
        let items: [String]?
        let columns: [Column]?
        let value: NumberValue?
        let label: String?
        let caption: String?

        struct Step: Codable { let text: String }
    }

    /// A number card's value: written as text ("42%") or as a bare JSON number.
    private struct NumberValue: Decodable {
        let text: String
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self.text = text
            } else {
                let number = try container.decode(Double.self)
                self.text = number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
            }
        }
    }

    /// The fields each kind may carry; any other field drops the card.
    private static let fields: [String: Set<String>] = [
        "timeline": ["kind", "title", "events"],
        "steps": ["kind", "title", "steps"],
        "flow": ["kind", "title", "nodes", "edges"],
        "list": ["kind", "title", "items"],
        "compare": ["kind", "title", "columns"],
        "number": ["kind", "value", "label", "caption"],
    ]

    private static func content(_ raw: Raw) -> Content? {
        func fits(_ text: String?, _ limit: Int) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= limit else { return nil }
            return text
        }
        func all(_ texts: [String], _ limit: Int) -> [String]? {
            let kept = texts.compactMap { fits($0, limit) }
            return kept.count == texts.count ? kept : nil
        }
        switch raw.kind {
        case "timeline":
            guard let title = fits(raw.title, titleLength), let events = raw.events, (1...maxRows).contains(events.count) else { return nil }
            let kept = events.compactMap { event in
                fits(event.label, lineLength).flatMap { label in fits(event.when, shortLength).map { Event(label: label, when: $0) } }
            }
            return kept.count == events.count ? .timeline(title: title, events: kept) : nil
        case "steps":
            guard let title = fits(raw.title, titleLength), let steps = raw.steps, (1...maxRows).contains(steps.count),
                  let texts = all(steps.map(\.text), lineLength) else { return nil }
            return .steps(title: title, steps: texts)
        case "list":
            guard let title = fits(raw.title, titleLength), let items = raw.items, (1...maxListItems).contains(items.count),
                  let texts = all(items, lineLength) else { return nil }
            return .list(title: title, items: texts)
        case "compare":
            guard let title = fits(raw.title, titleLength), let columns = raw.columns, (2...3).contains(columns.count) else { return nil }
            let kept = columns.compactMap { column -> Column? in
                guard let heading = fits(column.heading, shortLength), (1...maxPoints).contains(column.points.count),
                      let points = all(column.points, lineLength) else { return nil }
                return Column(heading: heading, points: points)
            }
            return kept.count == columns.count ? .compare(title: title, columns: kept) : nil
        case "number":
            guard raw.value != nil, let value = fits(raw.value?.text, 16), let label = fits(raw.label, titleLength) else { return nil }
            if let caption = raw.caption, caption.trimmingCharacters(in: .whitespacesAndNewlines).count > lineLength { return nil }
            return .number(value: value, label: label, caption: fits(raw.caption, lineLength))
        case "flow":
            return flow(raw, fits: fits)
        default:
            return nil
        }
    }

    /// A flow is boxes joined by arrows with no loop back, so it can be laid out in ranks:
    /// each node one rank past the furthest node pointing at it (longest path).
    private static func flow(_ raw: Raw, fits: (String?, Int) -> String?) -> Content? {
        guard let title = fits(raw.title, titleLength), let nodes = raw.nodes, (2...maxNodes).contains(nodes.count) else { return nil }
        let edges = raw.edges ?? []
        guard edges.count <= maxEdges else { return nil }
        var kept: [Node] = []
        for node in nodes {
            guard let id = fits(node.id, shortLength), let label = fits(node.label, shortLength),
                  !kept.contains(where: { $0.id == id }) else { return nil }
            kept.append(Node(id: id, label: label))
        }
        let ids = Set(kept.map(\.id))
        var keptEdges: [Edge] = []
        for edge in edges {
            guard ids.contains(edge.from), ids.contains(edge.to), edge.from != edge.to,
                  !keptEdges.contains(where: { $0.from == edge.from && $0.to == edge.to }) else { return nil }
            if edge.label != nil && fits(edge.label, 20) == nil { return nil }
            keptEdges.append(Edge(from: edge.from, to: edge.to, label: fits(edge.label, 20)))
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
        guard ordered.count == kept.count else { return nil }
        // Reveal by rank, keeping the written order within a rank.
        let byRank = kept.enumerated().sorted { (rank[$0.element.id] ?? 0, $0.offset) < (rank[$1.element.id] ?? 0, $1.offset) }.map(\.element)
        let ranks = (rank.values.max() ?? 0) + 1
        // Up to four ranks fit across a card; a longer chain runs top to bottom.
        return .flow(title: title, nodes: byRank, edges: keptEdges, rank: rank, across: ranks <= 4)
    }

    // MARK: Timing

    /// Where on the speech clock each element appears: the first at the tag, the rest spread
    /// evenly over the sentence after it (to that sentence's end, or the next card's tag).
    func revealOffsets(in spoken: String, nextCardOffset: Int?) -> [Int] {
        Self.beats(elements.count, from: offset, in: spoken, until: nextCardOffset)
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
