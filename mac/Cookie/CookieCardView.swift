//
//  CookieCardView.swift
//  Cookie
//
//  Draws an explainer card (`CookieCard`) in Cookie's paper-card language:
//  warm paper (charcoal in Dark Mode), rounded type, and the same hand ink
//  as the marks (`CookieInk`) for its rules, rings, boxes, arrows and chart
//  lines. Each element fades up and its ink draws on when its beat comes;
//  a card with states morphs from one to the next (same id moves, the rest
//  fade). Reduce Motion shows each state whole, without the morph.
//  `CookieCardPresenter` floats it beside the notch or beside what the
//  reply's marks point at, click-through except its controls, one card at a
//  time.
//

import AppKit
import SwiftUI

/// How much of a card is showing: elements before `shown` are visible, in the state `state`.
@MainActor
final class CookieCardReveal: ObservableObject {
    let card: CookieCard
    let teachingOwner = UUID()
    @Published var collapsed = false
    @Published private(set) var activeNode: String?
    private(set) var selectedNode: String?
    /// Which of the card's states is showing (0 is the first).
    @Published private(set) var state = 0
    /// A chart's sliders where the person left them, by slider id; a state starts from its own values.
    @Published var sliderValues: [String: Double] = [:]
    var anchors: [String: CGPoint] = [:]
    var onFocus: (CGPoint) -> Void = { _ in }
    /// Told when the state changes, so the panel can fit the new picture.
    var onStateChange: (Int) -> Void = { _ in }
    /// Cookie's hand goes to the active node only while Cookie is explaining it; a node the person
    /// clicked is already under their own pointer.
    private var handFollows = false

    var content: CookieCard.Content { card.states[state] }
    var nodes: [CookieCard.Node] { CookieCard.nodes(of: content) }

    func focus(_ id: String, hand: Bool = true) {
        guard nodes.contains(where: { $0.id == id }) else { return }
        collapsed = false
        handFollows = hand
        activeNode = id
        selectedNode = id
        if let index = elements.firstIndex(of: .node(id)) { reveal(through: index, instant: true, explaining: hand) }
        pointAtActiveNode()
    }
    func advance(_ forward: Bool) {
        let nodes = nodes
        guard !nodes.isEmpty else { return }
        let current = selectedNode.flatMap { selected in nodes.firstIndex { $0.id == selected } } ?? (forward ? -1 : nodes.count)
        focus(nodes[min(nodes.count - 1, max(0, current + (forward ? 1 : -1)))].id)
    }
    func pointAtActiveNode() {
        if handFollows, let activeNode, let point = anchors[activeNode] { onFocus(point) }
    }
    func pauseTeaching() {
        handFollows = false
        activeNode = nil
        CookieHand.shared.stopTeaching(owner: teachingOwner)
    }
    @Published private(set) var elements: [CookieCard.Element]
    @Published private(set) var shown = 0
    private var target = 0
    private var stagger: Task<Void, Never>?

    init(card: CookieCard) {
        self.card = card
        self.elements = card.elements
    }

    func isShown(_ element: CookieCard.Element) -> Bool {
        guard let index = elements.firstIndex(of: element) else { return false }
        return index < shown
    }

    /// Shows elements up to and including `index`, in order, at least 0.12 s apart so two
    /// that come due together still arrive one after the other; `instant` shows them at once.
    /// `explaining`: Cookie is naming this node now (the hand may go to it); false for the person's own click.
    func reveal(through index: Int, instant: Bool, explaining: Bool = true) {
        target = max(target, min(elements.count, index + 1))
        if index >= 0, index < elements.count, case .node(let id) = elements[index] { activeNode = id; selectedNode = id; handFollows = explaining }
        if instant {
            stagger?.cancel()
            stagger = nil
            shown = target
            pointAtActiveNode()
            return
        }
        guard stagger == nil else { return }
        stagger = Task { [weak self] in
            while let self, !Task.isCancelled, self.shown < self.target {
                self.shown += 1
                self.pointAtActiveNode()
                try? await Task.sleep(for: .milliseconds(120))
            }
            self?.stagger = nil
        }
    }

    /// Moves to state `next` (0-based), the whole of it showing. False when the card has no such state.
    @discardableResult
    func show(state next: Int) -> Bool {
        guard card.states.indices.contains(next) else { return false }
        collapsed = false
        stagger?.cancel()
        stagger = nil
        guard next != state else { return true }
        state = next
        sliderValues = [:]
        elements = CookieCard.elements(of: content)
        target = elements.count
        shown = elements.count
        if let selectedNode, !nodes.contains(where: { $0.id == selectedNode }) {
            self.selectedNode = nil
            activeNode = nil
        }
        onStateChange(next)
        pointAtActiveNode()
        return true
    }

    func sliderValue(_ slider: CookieCard.Chart.Slider) -> Double { sliderValues[slider.id] ?? slider.value }

    func stop() {
        pauseTeaching()
        stagger?.cancel()
        stagger = nil
    }
}

// MARK: - Ink

/// Hand-drawn figures in the shape's own unit square (0...1 on each axis), inked on as `progress` goes 0 → 1.
struct CookieCardInk: Shape {
    enum Figure: Equatable {
        case line(CGPoint, CGPoint)
        case ring(CGRect)
        case box(CGRect)
        case arrow(CGPoint, CGPoint)
        /// A smooth line through the points, one steady pass (a chart line, an arc).
        case polyline([CGPoint])
        /// A smooth line through the points with an open head at the last one.
        case curvedArrow([CGPoint])
    }

    let figures: [Figure]
    let seed: UInt32
    var pen: CGFloat = 2
    var progress: CGFloat
    /// How far the pen misses: 0.7 for boxes and arrows, less for a line that carries numbers.
    var roughness: CGFloat = 0.7

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    /// A short stable hash, so an element's ink wobbles the same way wherever it moves.
    static func seed(_ key: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return max(1, hash)
    }

    // ponytail: roughened and outlined every animation frame (a card has a few dozen short strokes);
    // cache per size if a card ever grows past that.
    func path(in rect: CGRect) -> Path {
        guard progress > 0 else { return Path() }
        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
        }
        var rough = CookieRough(seed: seed)
        rough.roughness = roughness
        var strokes: [CookieInkStroke] = []
        // Each stroke its own hand (the width wobble), from the figure's seed.
        func passes(_ lines: [[CGPoint]], firstOnly: Bool = false) {
            for (index, line) in lines.enumerated() where !(firstOnly && index % 2 == 1) {
                strokes.append(CookieInkStroke(line, size: index % 2 == 0 ? pen : pen * 0.7,
                                               seed: seed &+ UInt32(truncatingIfNeeded: strokes.count) &+ 1))
            }
        }
        func head(at tip: CGPoint, angle: CGFloat) {
            let size = max(7, pen * 4)
            for side in [CGFloat(0.5), -0.5] {
                passes(rough.line(tip, CGPoint(x: tip.x - size * cos(angle + side), y: tip.y - size * sin(angle + side))), firstOnly: true)
            }
        }
        for figure in figures {
            switch figure {
            case .line(let from, let to):
                passes(rough.line(place(from), place(to)), firstOnly: true)
            case .ring(let unit):
                let topLeft = place(unit.origin), bottomRight = place(CGPoint(x: unit.maxX, y: unit.maxY))
                passes(rough.ellipse(center: CGPoint(x: (topLeft.x + bottomRight.x) / 2, y: (topLeft.y + bottomRight.y) / 2),
                                     width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y))
            case .box(let unit):
                let a = place(unit.origin), c = place(CGPoint(x: unit.maxX, y: unit.maxY))
                passes(rough.linearPath([a, CGPoint(x: c.x, y: a.y), c, CGPoint(x: a.x, y: c.y), a]), firstOnly: true)
            case .arrow(let from, let to):
                let a = place(from), b = place(to)
                passes(rough.line(a, b), firstOnly: true)
                head(at: b, angle: atan2(b.y - a.y, b.x - a.x))
            case .polyline(let points), .curvedArrow(let points):
                let placed = points.map(place)
                guard placed.count >= 2 else { continue }
                passes(rough.curve(through: placed), firstOnly: true)
                if case .curvedArrow = figure, let tip = placed.last {
                    let before = placed[placed.count - 2]
                    head(at: tip, angle: atan2(tip.y - before.y, tip.x - before.x))
                }
            }
        }
        var reach = strokes.reduce(0) { $0 + $1.length } * min(1, progress)
        var path = Path()
        for stroke in strokes where reach > 0 {
            if let outline = stroke.outline(revealed: min(stroke.length, reach)) { path.addPath(Path(outline)) }
            reach -= stroke.length
        }
        return path
    }
}

/// A list of numbers SwiftUI can animate between, so a chart line glides from one state's shape to the next.
struct CookieVector: VectorArithmetic {
    var values: [CGFloat]
    static var zero: CookieVector { CookieVector(values: []) }
    private static func combine(_ a: CookieVector, _ b: CookieVector, _ operation: (CGFloat, CGFloat) -> CGFloat) -> CookieVector {
        let count = max(a.values.count, b.values.count)
        return CookieVector(values: (0..<count).map { operation($0 < a.values.count ? a.values[$0] : 0, $0 < b.values.count ? b.values[$0] : 0) })
    }
    static func + (a: CookieVector, b: CookieVector) -> CookieVector { combine(a, b, +) }
    static func - (a: CookieVector, b: CookieVector) -> CookieVector { combine(a, b, -) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * CGFloat(rhs) } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + Double($1 * $1) } }
}

/// A chart line in ink: points in the unit square, gliding to new points between states.
struct CookieChartLine: Shape {
    var points: CookieVector
    let seed: UInt32
    var pen: CGFloat = 2.2
    var progress: CGFloat

    var animatableData: AnimatablePair<CGFloat, CookieVector> {
        get { AnimatablePair(progress, points) }
        set { progress = newValue.first; points = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let values = points.values
        let unit = stride(from: 0, to: values.count - 1, by: 2).map { CGPoint(x: values[$0], y: values[$0 + 1]) }
        return CookieCardInk(figures: [.polyline(unit)], seed: seed, pen: pen, progress: progress, roughness: 0.3).path(in: rect)
    }
}

// MARK: - Card

struct CookieCardView: View {
    @ObservedObject var reveal: CookieCardReveal
    var onClose: () -> Void
    var onCollapse: (Bool) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Measurements the presenter needs to place the close control and leave room for the shadow.
    static let shadowMargin: CGFloat = 24
    static let closeSize: CGFloat = 22
    static let closeInset: CGFloat = 10

    /// Warm paper (charcoal in Dark Mode) and the text on it; scenes use the same.
    static func paper(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.17, green: 0.15, blue: 0.13) : Color(red: 0.985, green: 0.965, blue: 0.93)
    }
    static func inkText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.95, green: 0.92, blue: 0.86) : Color(red: 0.20, green: 0.13, blue: 0.08)
    }
    private var paper: Color { Self.paper(colorScheme) }
    private var inkText: Color { Self.inkText(colorScheme) }
    private var quietText: Color { inkText.opacity(0.58) }
    private let ink = CookieMarksLayer.ink
    /// A chart's second and third series: a fountain-pen blue and the paper's own graphite.
    private var seriesInks: [Color] {
        [ink, colorScheme == .dark ? Color(red: 0.55, green: 0.70, blue: 0.92) : Color(red: 0.20, green: 0.38, blue: 0.62), inkText.opacity(0.75)]
    }

    private var card: CookieCard { reveal.card }
    private var morph: Animation? { reduceMotion ? nil : CK.spring }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                reveal.collapsed.toggle()
                reveal.pauseTeaching()
            } label: {
                Label(reveal.collapsed ? String(card.spokenSummary.prefix(48)) : "Collapse", systemImage: reveal.collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(quietText)
                    .lineLimit(1).padding(.trailing, 24)
            }.buttonStyle(.plain)
            if !reveal.collapsed {
                content
                    .animation(morph, value: reveal.state)
                HStack(spacing: 18) {
                    if !reveal.nodes.isEmpty {
                        Button("Previous") { reveal.advance(false) }
                        Button("Next step") { reveal.advance(true) }
                    }
                    if card.states.count > 1 {
                        if !reveal.nodes.isEmpty { Spacer(minLength: 0) }
                        stages
                    }
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(quietText)
                    .buttonStyle(.plain).pointerCursor()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(paper)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(inkText.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.16), radius: 14, y: 6)
        )
        .overlay(alignment: .topTrailing) { closeButton }
        .padding(Self.shadowMargin)
        .coordinateSpace(name: "teachingPaper")
        .onPreferenceChange(CookieDiagramAnchors.self) { anchors in
            reveal.anchors = anchors
            reveal.pointAtActiveNode()
        }
        .onChange(of: reveal.collapsed) { _, value in onCollapse(value) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CookieCard.summary(reveal.content))
    }

    /// The stage control of a card with states: back, a dot per stage, forward.
    private var stages: some View {
        let count = card.states.count, current = reveal.state
        return HStack(spacing: 8) {
            Button { reveal.show(state: current - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(current == 0).accessibilityLabel("Previous stage")
            HStack(spacing: 5) {
                ForEach(0..<count, id: \.self) { index in
                    Circle().fill(ink.opacity(index == current ? 1 : 0.28)).frame(width: 6, height: 6)
                        .contentShape(Rectangle().inset(by: -4))
                        .onTapGesture { reveal.show(state: index) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Stage \(current + 1) of \(count)")
            .accessibilityAdjustableAction { direction in
                reveal.show(state: direction == .increment ? current + 1 : current - 1)
            }
            Button { reveal.show(state: current + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(current == count - 1).accessibilityLabel("Next stage")
        }
    }

    private var width: CGFloat {
        switch card.content {
        case .compare(_, let columns): return columns.count == 3 ? 460 : 380
        case .flow: return max(280, Self.flowCanvasLayout(card).size.width + 36)
        case .tree: return max(280, Self.treeCanvasSize(card).width + 36)
        case .cycle: return Self.cycleSize.width + 36
        case .chart: return Self.chartSize.width + 36
        case .layers: return 340
        default: return 320
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(quietText)
                .frame(width: Self.closeSize, height: Self.closeSize)
                .background(Circle().fill(inkText.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("Close card")
        .padding(Self.closeInset)
    }

    @ViewBuilder
    private var content: some View {
        switch reveal.content {
        case .timeline(let title, let events):
            titleView(title)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(events.indices, id: \.self) { index in
                    timelineRow(events[index], index: index, last: index == events.count - 1)
                }
            }
        case .steps(let title, let steps):
            titleView(title)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(steps.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(inkText)
                            .frame(width: 24, height: 24)
                            .background(inked([.ring(CGRect(x: 0.04, y: 0.04, width: 0.92, height: 0.92))], .row(index), pen: 1.8))
                        bodyText(steps[index])
                    }
                    .appear(reveal.isShown(.row(index)), reduceMotion)
                }
            }
        case .list(let title, let items):
            titleView(title)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Color.clear.frame(width: 10, height: 8)
                            .overlay(inked([.line(CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))], .row(index), pen: 2.2))
                        bodyText(items[index])
                    }
                    .appear(reveal.isShown(.row(index)), reduceMotion)
                }
            }
        case .compare(let title, let columns):
            titleView(title)
            HStack(alignment: .top, spacing: 0) {
                ForEach(columns.indices, id: \.self) { column in
                    compareColumn(columns[column], column: column)
                        .padding(.leading, column == 0 ? 0 : 14)
                        .padding(.trailing, column == columns.count - 1 ? 0 : 14)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .overlay(alignment: .leading) {
                            if column > 0 {
                                // The rule between columns draws with the column's heading.
                                inked([.line(CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1))], .heading(column), pen: 1.6).frame(width: 4)
                            }
                        }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        case .number(let value, let label, let caption):
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(inkText)
                    .padding(.bottom, 6)
                    .overlay(alignment: .bottomLeading) {
                        inked([.line(CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))], .value, pen: 2.6).frame(height: 6)
                    }
                    .appear(reveal.isShown(.value), reduceMotion)
                Text(label)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(inkText)
                    .padding(.top, 6)
                    .appear(reveal.isShown(.label), reduceMotion)
                if let caption {
                    Text(caption)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(quietText)
                        .fixedSize(horizontal: false, vertical: true)
                        .appear(reveal.isShown(.caption), reduceMotion)
                }
            }
            .padding(.trailing, 24)
        case .flow(let title, _, _, _, _):
            titleView(title)
            flowCanvas
        case .layers(let title, let layers):
            titleView(title)
            layersStack(layers)
        case .cycle(let title, let steps):
            titleView(title)
            cycleCanvas(steps)
        case .tree(let title, _):
            titleView(title)
            treeCanvas
        case .chart(let chart):
            titleView(chart.title)
            chartView(chart)
        }
    }

    // MARK: Pieces

    private func titleView(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(inkText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.trailing, 26) // clear of the close control
            .padding(.bottom, 5)
            .overlay(alignment: .bottomLeading) {
                // A short hand-drawn rule under the title, Cookie's signature on every card.
                inked([.line(CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))], .title, pen: 2.2).frame(width: 56, height: 4)
            }
            .appear(reveal.isShown(.title), reduceMotion)
            .accessibilityAddTraits(.isHeader)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, design: .rounded))
            .foregroundStyle(inkText)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func timelineRow(_ event: CookieCard.Event, index: Int, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(event.when)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(quietText)
                .frame(width: 64, alignment: .trailing)
                .padding(.top, 1)
            Color.clear.frame(width: 14)
            bodyText(event.label)
                .padding(.bottom, last ? 0 : 14)
        }
        .overlay(alignment: .topLeading) {
            // The dot, and the rule down to the next one, sit in the 14-point gap.
            let figures: [CookieCardInk.Figure] = last
                ? [.ring(CGRect(x: 0.1, y: 0.02, width: 0.8, height: 0.12))]
                : [.ring(CGRect(x: 0.1, y: 0.02, width: 0.8, height: 0.12)), .line(CGPoint(x: 0.5, y: 0.2), CGPoint(x: 0.5, y: 1))]
            inked(figures, .row(index), pen: 1.8)
                .frame(width: 14)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.leading, 72)
        }
        .fixedSize(horizontal: false, vertical: true)
        .appear(reveal.isShown(.row(index)), reduceMotion)
    }

    private func compareColumn(_ column: CookieCard.Column, column index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(column.heading)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(inkText)
                .appear(reveal.isShown(.heading(index)), reduceMotion)
            ForEach(column.points.indices, id: \.self) { point in
                Text(column.points[point])
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(inkText.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                    .appear(reveal.isShown(.point(column: index, index: point)), reduceMotion)
            }
        }
    }

    /// One labelled box Cookie can point at: highlighted while it's the one being explained,
    /// clickable to focus it, and where the hand goes.
    private func nodeBox(_ node: CookieCard.Node, size: CGSize, compact: Bool = false) -> some View {
        let active = reveal.activeNode == node.id
        return VStack(spacing: compact ? 2 : 8) {
            if let icon = node.icon {
                Image(systemName: icon)
                    .font(.system(size: compact ? 16 : 28, weight: .light))
                    .foregroundStyle(ink)
            }
            Text(node.label)
                .font(.system(size: compact ? 11.5 : 12, weight: .semibold, design: .rounded))
            if let note = node.note, compact {
                Text(note).font(.system(size: 9.5, design: .rounded)).foregroundStyle(quietText).lineLimit(1)
            }
        }
        .foregroundStyle(inkText)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.85)
        .padding(.horizontal, 6)
        .frame(width: size.width, height: size.height)
        .background(RoundedRectangle(cornerRadius: compact ? 11 : 16).fill(ink.opacity(active ? 0.17 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: compact ? 11 : 16).strokeBorder(ink.opacity(active ? 1 : 0.25), lineWidth: active ? 2 : 1))
        .background(anchor(node.id))
        .onTapGesture { reveal.focus(node.id, hand: false) }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Focus on \(node.label)")
    }

    /// Where the hand points for a node: just inside its left edge, in the card's coordinates.
    private func anchor(_ id: String) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named("teachingPaper"))
            Color.clear.preference(key: CookieDiagramAnchors.self, value: [id: CGPoint(x: frame.minX + 6, y: frame.midY)])
        }
    }

    // MARK: Flow

    private static let nodeSize = CGSize(width: 112, height: 86)
    private static let rankGap: CGFloat = 58
    private static let nodeGap: CGFloat = 14

    /// Where each node's box sits on the flow canvas: ranks are columns (across) or rows (down),
    /// and a rank's nodes are centred on the rank with the widest spread.
    static func flowLayout(nodes: [CookieCard.Node], rank: [String: Int], across: Bool) -> (size: CGSize, boxes: [String: CGRect]) {
        let ranks = (rank.values.max() ?? 0) + 1
        var members: [[CookieCard.Node]] = Array(repeating: [], count: ranks)
        for node in nodes { members[rank[node.id] ?? 0].append(node) }
        let widest = CGFloat(members.map(\.count).max() ?? 1)
        let size = nodeSize
        let along = CGFloat(ranks) * (across ? size.width : size.height) + CGFloat(ranks - 1) * rankGap
        let spread = widest * (across ? size.height : size.width) + (widest - 1) * nodeGap
        var boxes: [String: CGRect] = [:]
        for (level, group) in members.enumerated() {
            let count = CGFloat(group.count)
            let groupSpread = count * (across ? size.height : size.width) + (count - 1) * nodeGap
            for (position, node) in group.enumerated() {
                let first = CGFloat(level) * ((across ? size.width : size.height) + rankGap)
                let second = (spread - groupSpread) / 2 + CGFloat(position) * ((across ? size.height : size.width) + nodeGap)
                boxes[node.id] = across
                    ? CGRect(x: first, y: second, width: size.width, height: size.height)
                    : CGRect(x: second, y: first, width: size.width, height: size.height)
            }
        }
        return (across ? CGSize(width: along, height: spread) : CGSize(width: spread, height: along), boxes)
    }

    /// A canvas big enough for every state, each state's layout centred on it.
    static func flowCanvasLayout(_ card: CookieCard, state: Int? = nil) -> (size: CGSize, boxes: [String: CGRect]) {
        let layouts: [(size: CGSize, boxes: [String: CGRect])] = card.states.map { content in
            guard case .flow(_, let nodes, _, let rank, let across) = content else { return (.zero, [:]) }
            return flowLayout(nodes: nodes, rank: rank, across: across)
        }
        let size = CGSize(width: layouts.map(\.size.width).max() ?? 0, height: layouts.map(\.size.height).max() ?? 0)
        let layout = layouts[min(state ?? 0, layouts.count - 1)]
        let dx = (size.width - layout.size.width) / 2, dy = (size.height - layout.size.height) / 2
        return (size, layout.boxes.mapValues { $0.offsetBy(dx: dx, dy: dy) })
    }

    @ViewBuilder
    private var flowCanvas: some View {
        if case .flow(_, let nodes, let edges, _, let across) = reveal.content {
            let layout = Self.flowCanvasLayout(card, state: reveal.state)
            let canvas = layout.size
            ZStack(alignment: .topLeading) {
                ForEach(Array(edges.enumerated()), id: \.offset) { index, edge in
                    if let from = layout.boxes[edge.from], let to = layout.boxes[edge.to] {
                        // Box edge to box edge, a few points short of the target so the head reads.
                        let start = across ? CGPoint(x: from.maxX + 3, y: from.midY) : CGPoint(x: from.midX, y: from.maxY + 3)
                        let end = across ? CGPoint(x: to.minX - 4, y: to.midY) : CGPoint(x: to.midX, y: to.minY - 4)
                        flowEdge(edge, index: index, start: start, end: end, canvas: canvas, across: across)
                            // A moved arrow is drawn again where it now goes; one that stays stays.
                            .id("\(edge.from)>\(edge.to)@\(Int(start.x)),\(Int(start.y)),\(Int(end.x)),\(Int(end.y))")
                            .transition(.opacity)
                    }
                }
                ForEach(nodes, id: \.id) { node in
                    if let box = layout.boxes[node.id] {
                        nodeBox(node, size: box.size)
                            .position(x: box.midX, y: box.midY)
                            .appear(reveal.isShown(.node(node.id)), reduceMotion)
                            .transition(.opacity)
                    }
                }
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        }
    }

    private func flowEdge(_ edge: CookieCard.Edge, index: Int, start: CGPoint, end: CGPoint, canvas: CGSize, across: Bool) -> some View {
        func unit(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x / canvas.width, y: point.y / canvas.height) }
        return ZStack(alignment: .topLeading) {
            inked([.arrow(unit(start), unit(end))], .edge(index), pen: 1.8, key: "edge \(edge.from)>\(edge.to)")
            if let label = edge.label {
                Text(label)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(quietText)
                    .padding(.horizontal, 4)
                    .background(paper)
                    .fixedSize()
                    .position(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - (across ? 9 : 0))
                    .appear(reveal.isShown(.edge(index)), reduceMotion)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }

    // MARK: Layers

    /// The stack, top layer first, each layer an inked slab; a layer that moves between states slides.
    private func layersStack(_ layers: [CookieCard.Node]) -> some View {
        VStack(spacing: 6) {
            ForEach(layers, id: \.id) { layer in
                let active = reveal.activeNode == layer.id
                HStack(spacing: 10) {
                    if let icon = layer.icon {
                        Image(systemName: icon).font(.system(size: 16, weight: .light)).foregroundStyle(ink).frame(width: 22)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(layer.label).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundStyle(inkText)
                        if let note = layer.note {
                            Text(note).font(.system(size: 11, design: .rounded)).foregroundStyle(quietText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(ink.opacity(active ? 0.17 : 0.05)))
                .background(inked([.box(CGRect(x: 0.003, y: 0.03, width: 0.994, height: 0.94))], .node(layer.id),
                                  pen: active ? 2.2 : 1.6, key: "layer \(layer.id)"))
                .background(anchor(layer.id))
                .contentShape(Rectangle())
                .onTapGesture { reveal.focus(layer.id, hand: false) }
                .appear(reveal.isShown(.node(layer.id)), reduceMotion)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(.trailing, 4)
    }

    // MARK: Cycle

    private static let cycleSize = CGSize(width: 320, height: 236)
    private static let cycleNode = CGSize(width: 104, height: 44)

    /// Where each step sits: round an ellipse, the first at the top, clockwise.
    static func cycleCentres(count: Int) -> [CGPoint] {
        let size = cycleSize, node = cycleNode
        let rx = (size.width - node.width) / 2, ry = (size.height - node.height) / 2
        return (0..<count).map { index in
            let angle = -CGFloat.pi / 2 + 2 * .pi * CGFloat(index) / CGFloat(count)
            return CGPoint(x: size.width / 2 + rx * cos(angle), y: size.height / 2 + ry * sin(angle))
        }
    }

    /// The arc from step `index` to the next, along the same ellipse, clear of both boxes.
    static func cycleArc(from index: Int, count: Int) -> [CGPoint] {
        let size = cycleSize, node = cycleNode
        let rx = (size.width - node.width) / 2, ry = (size.height - node.height) / 2
        let step = 2 * CGFloat.pi / CGFloat(count)
        let start = -CGFloat.pi / 2 + step * CGFloat(index)
        // Clear of the boxes: more of the arc goes to the box on a short ring.
        let gap = min(step * 0.42, 0.62)
        return (0...10).map { sample in
            let angle = start + gap + (step - 2 * gap) * CGFloat(sample) / 10
            return CGPoint(x: (size.width / 2 + rx * cos(angle)) / size.width, y: (size.height / 2 + ry * sin(angle)) / size.height)
        }
    }

    private func cycleCanvas(_ steps: [CookieCard.Node]) -> some View {
        let centres = Self.cycleCentres(count: steps.count)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                inked([.curvedArrow(Self.cycleArc(from: index, count: steps.count))], .edge(index), pen: 1.8,
                      key: "cycle \(step.id)>\(steps[(index + 1) % steps.count].id)")
                    .id("arc \(index) of \(steps.count)")
                    .transition(.opacity)
            }
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                nodeBox(step, size: Self.cycleNode, compact: true)
                    .position(centres[index])
                    .appear(reveal.isShown(.node(step.id)), reduceMotion)
                    .transition(.opacity)
            }
        }
        .frame(width: Self.cycleSize.width, height: Self.cycleSize.height, alignment: .topLeading)
    }

    // MARK: Tree

    private static let treeNode = CGSize(width: 96, height: 38)
    private static let treeGap: CGFloat = 10
    private static let treeLevelGap: CGFloat = 30

    /// A tidy tree: leaves side by side in order, each parent centred over its children.
    static func treeLayout(_ nodes: [CookieCard.Node]) -> (size: CGSize, boxes: [String: CGRect]) {
        guard let root = nodes.first else { return (.zero, [:]) }
        var children: [String: [CookieCard.Node]] = [:]
        for node in nodes.dropFirst() { children[node.parent ?? root.id, default: []].append(node) }
        var boxes: [String: CGRect] = [:]
        var nextLeaf: CGFloat = 0, deepest = 0
        func place(_ node: CookieCard.Node, depth: Int) -> CGFloat {
            deepest = max(deepest, depth)
            let kids = children[node.id] ?? []
            let x: CGFloat
            if kids.isEmpty {
                x = nextLeaf * (treeNode.width + treeGap) + treeNode.width / 2
                nextLeaf += 1
            } else {
                let xs = kids.map { place($0, depth: depth + 1) }
                x = (xs.first! + xs.last!) / 2
            }
            boxes[node.id] = CGRect(x: x - treeNode.width / 2, y: CGFloat(depth) * (treeNode.height + treeLevelGap),
                                    width: treeNode.width, height: treeNode.height)
            return x
        }
        _ = place(root, depth: 0)
        let width = nextLeaf * (treeNode.width + treeGap) - treeGap
        let height = CGFloat(deepest + 1) * (treeNode.height + treeLevelGap) - treeLevelGap
        return (CGSize(width: width, height: height), boxes)
    }

    static func treeCanvasSize(_ card: CookieCard) -> CGSize {
        card.states.reduce(CGSize.zero) { size, content in
            guard case .tree(_, let nodes) = content else { return size }
            let layout = treeLayout(nodes).size
            return CGSize(width: max(size.width, layout.width), height: max(size.height, layout.height))
        }
    }

    @ViewBuilder
    private var treeCanvas: some View {
        if case .tree(_, let nodes) = reveal.content {
            let layout = Self.treeLayout(nodes)
            let canvas = Self.treeCanvasSize(card)
            let dx = (canvas.width - layout.size.width) / 2
            let boxes = layout.boxes.mapValues { $0.offsetBy(dx: dx, dy: 0) }
            ZStack(alignment: .topLeading) {
                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                    if index > 0, let parent = node.parent, let from = boxes[parent], let to = boxes[node.id] {
                        let start = CGPoint(x: from.midX / canvas.width, y: (from.maxY + 2) / canvas.height)
                        let end = CGPoint(x: to.midX / canvas.width, y: (to.minY - 2) / canvas.height)
                        inked([.line(start, end)], .edge(index), pen: 1.6, key: "branch \(node.id)")
                            .id("\(parent)>\(node.id)@\(Int(from.midX)),\(Int(to.midX)),\(Int(to.minY))")
                            .transition(.opacity)
                    }
                }
                ForEach(nodes, id: \.id) { node in
                    if let box = boxes[node.id] {
                        nodeBox(node, size: box.size, compact: true)
                            .position(x: box.midX, y: box.midY)
                            .appear(reveal.isShown(.node(node.id)), reduceMotion)
                            .transition(.opacity)
                    }
                }
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        }
    }

    // MARK: Chart

    static let chartSize = CGSize(width: 324, height: 176)
    /// The plot inside the chart canvas: room on the left for the y numbers, below for the x ones.
    static let plotArea = CGRect(x: 38, y: 22, width: 278, height: 128)

    /// A data point on the plot, in the chart canvas's points.
    static func place(_ point: CGPoint, in chart: CookieCard.Chart) -> CGPoint {
        let x = chart.xRange, y = chart.yRange
        let ux = (Double(point.x) - x.lowerBound) / max(1e-9, x.upperBound - x.lowerBound)
        let uy = (Double(point.y) - y.lowerBound) / max(1e-9, y.upperBound - y.lowerBound)
        return CGPoint(x: plotArea.minX + plotArea.width * ux, y: plotArea.maxY - plotArea.height * uy)
    }

    /// A line's points evenly spaced along x, always `Chart.samples` of them, so any two states'
    /// lines morph point for point; in the plot's unit square.
    static func unitLine(_ points: [CGPoint], in chart: CookieCard.Chart) -> CookieVector {
        let count = CookieCard.Chart.samples
        guard let first = points.first, let last = points.last else { return CookieVector(values: []) }
        var values: [CGFloat] = []
        var segment = 0
        for step in 0..<count {
            let x = points.count == 1 ? first.x : first.x + (last.x - first.x) * CGFloat(step) / CGFloat(count - 1)
            while segment < points.count - 2, points[segment + 1].x < x { segment += 1 }
            let a = points[segment], b = points[min(points.count - 1, segment + 1)]
            let t = b.x == a.x ? 0 : (x - a.x) / (b.x - a.x)
            let placed = place(CGPoint(x: x, y: a.y + (b.y - a.y) * min(1, max(0, t))), in: chart)
            values += [(placed.x - plotArea.minX) / plotArea.width, (placed.y - plotArea.minY) / plotArea.height]
        }
        return CookieVector(values: values)
    }

    private func chartView(_ chart: CookieCard.Chart) -> some View {
        let plots = chart.plots(chart.sliders.map(reveal.sliderValue))
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                chartAxes(chart)
                ForEach(Array(plots.enumerated()), id: \.element.id) { index, plot in
                    chartSeries(plot, index: index, chart: chart)
                }
            }
            .frame(width: Self.chartSize.width, height: Self.chartSize.height, alignment: .topLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(CookieCard.summary(.chart(chart)))
            if plots.count > 1, chart.style != .bar {
                HStack(spacing: 12) {
                    ForEach(Array(plots.enumerated()), id: \.element.id) { index, plot in
                        HStack(spacing: 5) {
                            Capsule().fill(seriesInks[index % seriesInks.count]).frame(width: 14, height: 3)
                            Text(plot.label).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(quietText)
                        }
                        .appear(reveal.isShown(.series(plot.id)), reduceMotion)
                    }
                }
                .padding(.leading, Self.plotArea.minX)
            }
            ForEach(chart.sliders, id: \.id) { slider in
                chartSlider(slider)
            }
            if let source = chart.source {
                Text("Source: " + source)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(quietText)
                    .fixedSize(horizontal: false, vertical: true)
                    .appear(reveal.isShown(.caption), reduceMotion)
            }
        }
    }

    private func chartAxes(_ chart: CookieCard.Chart) -> some View {
        let area = Self.plotArea, size = Self.chartSize
        func unit(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x / size.width, y: y / size.height) }
        var figures: [CookieCardInk.Figure] = [
            .line(unit(area.minX, area.minY - 4), unit(area.minX, area.maxY)),
            .line(unit(area.minX, area.maxY), unit(area.maxX + 4, area.maxY)),
        ]
        // Zero, when the numbers cross it.
        if chart.yRange.lowerBound < 0, chart.yRange.upperBound > 0 {
            let zero = Self.place(CGPoint(x: chart.xRange.lowerBound, y: 0), in: chart).y
            figures.append(.line(unit(area.minX, zero), unit(area.maxX, zero)))
        }
        let ticks = [chart.yRange.lowerBound, (chart.yRange.lowerBound + chart.yRange.upperBound) / 2, chart.yRange.upperBound]
        let shown = reveal.isShown(.axes)
        return ZStack(alignment: .topLeading) {
            inked(figures, .axes, pen: 1.5, key: "axes")
            ForEach(ticks.indices, id: \.self) { index in
                Text(CookieCard.format(ticks[index]))
                    .font(.system(size: 9.5, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(quietText)
                    .frame(width: area.minX - 6, alignment: .trailing)
                    .position(x: (area.minX - 6) / 2, y: Self.place(CGPoint(x: chart.xRange.lowerBound, y: ticks[index]), in: chart).y)
            }
            if chart.style == .bar {
                ForEach(Array(chart.series.enumerated()), id: \.element.id) { index, bar in
                    Text(bar.label)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(quietText).lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: area.width / CGFloat(chart.series.count) - 2)
                        .position(x: Self.place(CGPoint(x: Double(index), y: 0), in: chart).x, y: area.maxY + 10)
                }
            } else {
                ForEach([chart.xRange.lowerBound, chart.xRange.upperBound], id: \.self) { x in
                    Text(CookieCard.format(x))
                        .font(.system(size: 9.5, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(quietText)
                        .position(x: Self.place(CGPoint(x: x, y: chart.yRange.lowerBound), in: chart).x, y: area.maxY + 10)
                }
            }
            if let xLabel = chart.xLabel {
                Text(xLabel)
                    .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(quietText)
                    .frame(width: area.width, alignment: .trailing)
                    .position(x: area.midX, y: size.height - 6)
            }
        }
        .overlay(alignment: .topLeading) {
            // The y axis's name sits above its top, clear of the numbers.
            Text(chart.yLabel)
                .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(quietText)
                .padding(.leading, area.minX - 4)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .opacity(shown ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: shown)
    }

    @ViewBuilder
    private func chartSeries(_ plot: CookieCard.Chart.Plot, index: Int, chart: CookieCard.Chart) -> some View {
        let color = seriesInks[index % seriesInks.count]
        let shown = reveal.isShown(.series(plot.id))
        let area = Self.plotArea
        switch chart.style {
        case .line:
            CookieChartLine(points: Self.unitLine(plot.points, in: chart), seed: CookieCardInk.seed("line \(plot.id)"),
                            progress: shown ? 1 : 0)
                .fill(color)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: shown)
                .frame(width: area.width, height: area.height)
                .offset(x: area.minX, y: area.minY)
                .allowsHitTesting(false)
        case .scatter:
            ForEach(Array(plot.points.enumerated()), id: \.offset) { at, point in
                let placed = Self.place(point, in: chart)
                CookieCardInk(figures: [.ring(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))],
                              seed: CookieCardInk.seed("dot \(plot.id) \(at)"), pen: 1.6, progress: shown ? 1 : 0)
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .position(placed)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3).delay(Double(at) * 0.012), value: shown)
                    .allowsHitTesting(false)
            }
        case .bar:
            let value = plot.points.first ?? .zero
            let top = Self.place(value, in: chart), base = Self.place(CGPoint(x: value.x, y: max(chart.yRange.lowerBound, min(0, chart.yRange.upperBound))), in: chart)
            let barWidth = area.width / CGFloat(max(1, chart.series.count)) * 0.56
            let height = max(1, abs(base.y - top.y))
            ZStack {
                RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.16))
                CookieCardInk(figures: [.box(CGRect(x: 0.02, y: 0.004, width: 0.96, height: 0.992))],
                              seed: CookieCardInk.seed("bar \(plot.id)"), pen: 1.7, progress: shown ? 1 : 0, roughness: 0.4)
                    .fill(color)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: shown)
            }
            .frame(width: barWidth, height: shown || reduceMotion ? height : 1)
            .position(x: top.x, y: shown || reduceMotion ? (top.y + base.y) / 2 : base.y)
            .animation(reduceMotion ? nil : CK.spring, value: shown)
            .allowsHitTesting(false)
            .accessibilityLabel("\(plot.label), \(CookieCard.format(Double(value.y)))")
        }
    }

    /// One live control: the chart recomputes from its formula as it moves (on the Mac, nothing sent).
    private func chartSlider(_ slider: CookieCard.Chart.Slider) -> some View {
        let value = reveal.sliderValue(slider)
        return HStack(spacing: 8) {
            Text(slider.label)
                .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(inkText)
                .lineLimit(1).frame(width: 78, alignment: .leading)
            Slider(value: Binding(get: { reveal.sliderValue(slider) }, set: { reveal.sliderValues[slider.id] = $0 }),
                   in: slider.minimum...slider.maximum)
                .controlSize(.small)
                .tint(ink)
                .accessibilityLabel(slider.label)
                .accessibilityValue(CookieCard.format(value) + (slider.unit.map { " " + $0 } ?? ""))
            Text(CookieCard.format(value) + (slider.unit.map { " " + $0 } ?? ""))
                .font(.system(size: 10.5, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(quietText).frame(width: 58, alignment: .trailing)
        }
        .appear(reveal.isShown(.axes), reduceMotion)
    }

    // MARK: Ink helper

    /// Ink for one element: drawn on when the element shows (whole, under Reduce Motion). `key`
    /// names the element for its seed, so its wobble is the same in every state it appears in.
    private func inked(_ figures: [CookieCardInk.Figure], _ element: CookieCard.Element, pen: CGFloat, key: String? = nil) -> some View {
        let shown = reveal.isShown(element)
        return CookieCardInk(figures: figures, seed: CookieCardInk.seed(key ?? "\(element)"), pen: pen,
                             progress: shown ? 1 : 0)
            .fill(ink)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: shown)
            .allowsHitTesting(false)
    }
}

struct CookieDiagramAnchors: PreferenceKey {
    static var defaultValue: [String: CGPoint] = [:]
    static func reduce(value: inout [String: CGPoint], nextValue: () -> [String: CGPoint]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    /// An element's arrival: a short fade and lift (a fade alone under Reduce Motion).
    func appear(_ shown: Bool, _ reduceMotion: Bool) -> some View {
        self.opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: shown)
    }
}


// MARK: - Presenter

/// Floats one card at a time. The card never takes focus and lets clicks through, except on its
/// close control; Escape, a click anywhere else, the next question, or 45 s after its last element
/// dismisses it. A new card cross-fades over the old one. The panel is an ordinary Cookie window,
/// so Cookie's own screenshots leave it out (`CompanionScreenCaptureUtility` excludes the app) and
/// "Hide from screen sharing" covers it (`CookieCaptureShield` applies to every window).
/// A lesson stays for follow-up questions, but not over the person's work: with nothing new and the
/// pointer elsewhere it folds to its title bar after 45 s, and closes after 10 minutes.
enum CookieLessonIdle {
    static let collapseAfter: TimeInterval = 45
    static let closeAfter: TimeInterval = 600
    enum Step: Equatable { case stay, collapse, close }
    /// Open and used within the last 45 s: only then are "faster", "turn it" or "spin" the visual's.
    /// Folded or left alone, the words go through the usual routing.
    static func inUse(collapsed: Bool, idle: TimeInterval) -> Bool { !collapsed && idle < collapseAfter }

    static func step(idle: TimeInterval, collapsed: Bool) -> Step {
        if idle >= closeAfter { return .close }
        return idle >= collapseAfter && !collapsed ? .collapse : .stay
    }
}

@MainActor
final class CookieCardPresenter {
    private var panel: NSPanel?
    private var reveal: CookieCardReveal?
    private var schedules: [CookieSpeechClock.Scheduled] = []
    private weak var clock: CookieSpeechClock?
    private var monitors: [Any] = []
    private var fadeTimer: Task<Void, Never>?
    private var lastActive = Date()

    var teachingContext: String? {
        guard let reveal else { return nil }
        let states = reveal.card.states.count
        let stage = states > 1 ? " Stage \(reveal.state + 1) of \(states) ([VISUAL:state:n] moves to stage n)." : ""
        let nodes = reveal.nodes
        if !nodes.isEmpty {
            return "Visible teaching diagram: \(CookieCard.summary(reveal.content)).\(stage) Selected: \(reveal.selectedNode ?? "none"). Objects: "
                + nodes.map { "\($0.id)=\($0.label)" }.joined(separator: "; ")
        }
        if case .chart(let chart) = reveal.content, !chart.sliders.isEmpty {
            let values = chart.sliders.map { "\($0.label) = \(CookieCard.format(reveal.sliderValue($0)))\($0.unit.map { " " + $0 } ?? "")" }
            return "Visible card: " + CookieCard.summary(reveal.content) + stage + " Sliders now: " + values.joined(separator: ", ")
        }
        return "Visible card: " + CookieCard.summary(reveal.content) + stage
    }
    var inUse: Bool { reveal.map { CookieLessonIdle.inUse(collapsed: $0.collapsed, idle: Date().timeIntervalSince(lastActive)) } ?? false }
    /// Called when a card appears, so whatever stood in for it ("Building your model…") can go.
    var onShow: (() -> Void)?
    /// A lesson the person asked for from their screen closes on Esc wherever the pointer is
    /// (when it's the newest Cookie surface: `CookieEscape`).
    var escapeAnywhere = false {
        didSet { escapeAnywhere ? CookieEscape.shared.push(.card) : CookieEscape.shared.pop(.card) }
    }
    func pauseTeaching() { cancelSchedules(); reveal?.pauseTeaching() }
    @discardableResult func apply(_ command: CookieVisualCommand) -> Bool {
        guard let reveal else { return false }
        if case .state(let number) = command {
            lastActive = Date()
            return reveal.show(state: number - 1)
        }
        guard command == .next || command == .previous, !reveal.nodes.isEmpty else { return false }
        reveal.advance(command == .next)
        return true
    }
    @discardableResult func focus(_ id: String) -> Bool {
        guard let reveal, reveal.nodes.contains(where: { $0.id == id }) else { return false }
        reveal.focus(id)
        return true
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Puts each card on the speech clock: it appears at its tag and its elements follow the
    /// sentence after it. Call once the speech has begun (`beginReply`); a place already passed
    /// shows at once. Later cards replace earlier ones.
    func prepare(_ card: CookieCard, clock: CookieSpeechClock) {
        cancelSchedules()
        self.clock = clock
        schedules.append(clock.schedule(atOffset: card.offset) { [weak self] in
            self?.show(card, near: nil).reveal(through: 0, instant: true)
        })
    }

    func schedule(_ cards: [CookieCard], spoken: String, near region: (rect: CGRect, display: CGRect)?, clock: CookieSpeechClock) {
        cancelSchedules()
        self.clock = clock
        for (position, card) in cards.enumerated() {
            let nextOffset = position + 1 < cards.count ? cards[position + 1].offset : nil
            let offsets = card.revealOffsets(in: spoken, nextCardOffset: nextOffset)
            var cardReveal: CookieCardReveal?
            for (index, offset) in offsets.enumerated() {
                schedules.append(clock.schedule(atOffset: offset) { [weak self] in
                    guard let self else { return }
                    if index == 0 { cardReveal = self.show(card, near: region) }
                    guard let cardReveal, cardReveal === self.reveal else { return }
                    let instant = self.reduceMotion
                    cardReveal.reveal(through: instant ? offsets.count - 1 : index, instant: instant)
                    self.restartFadeTimer()
                })
            }
            // Then each later state, on its own words; this card's, while it is still the one up.
            let after = max(card.offset, offsets.last ?? card.offset)
            let cues = card.stateOffsets(in: spoken, after: after)
            if !cues.unmatched.isEmpty {
                print("🃏 card states \(cues.unmatched.map(String.init).joined(separator: ", ")): no at phrase in the words, spaced evenly")
            }
            for (index, offset) in cues.offsets.enumerated() {
                schedules.append(clock.schedule(atOffset: max(offset, after)) { [weak self] in
                    guard let self, let cardReveal, cardReveal === self.reveal else { return }
                    cardReveal.show(state: index + 1)
                    self.restartFadeTimer()
                })
            }
        }
    }

    /// A card that isn't spoken (a typed answer): all of it now, in a short stagger.
    func showNow(_ card: CookieCard, near region: (rect: CGRect, display: CGRect)?) {
        cancelSchedules()
        let cardReveal = show(card, near: region)
        cardReveal.reveal(through: cardReveal.elements.count - 1, instant: reduceMotion)
        restartFadeTimer()
    }

    func dismiss() {
        cancelSchedules()
        fadeTimer?.cancel()
        fadeTimer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        reveal?.stop()
        reveal = nil
        if let panel { fadeOut(panel) }
        panel = nil
        escapeAnywhere = false
    }

    /// Where the reply's marks are, as one rectangle on the first mark's display (AppKit global).
    static func region(of marks: [CookieResolvedDrawing]) -> (rect: CGRect, display: CGRect)? {
        guard let display = marks.first?.displayFrame else { return nil }
        let rects: [CGRect] = marks.filter { $0.displayFrame == display }.map { mark in
            switch mark.geometry {
            case .circle(let rect): return rect
            case .arrow(let from, let to), .underline(let from, let to):
                return CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
            case .bracket(let x, let top, let bottom):
                return CGRect(x: x - 8, y: min(top, bottom), width: 16, height: abs(top - bottom))
            case .note(let point), .number(let point):
                return CGRect(x: point.x - 20, y: point.y - 12, width: 40, height: 24)
            }
        }
        guard let first = rects.first else { return nil }
        return (rects.dropFirst().reduce(first) { $0.union($1) }, display)
    }

    // MARK: Showing

    private func cancelSchedules() {
        if let clock { schedules.forEach(clock.cancel) }
        schedules = []
    }

    @discardableResult
    private func show(_ card: CookieCard, near region: (rect: CGRect, display: CGRect)?) -> CookieCardReveal {
        onShow?()
        if let reveal, reveal.card == card { return reveal }
        let cardReveal = CookieCardReveal(card: card)
        let hosting = CookieCardHostingView(rootView: CookieCardView(reveal: cardReveal, onClose: { [weak self] in self?.dismiss() }))
        let size = hosting.fittingSize
        let newPanel = CookieCardPanel(contentRect: Self.frame(for: size, near: region))
        newPanel.contentView = hosting
        newPanel.isMovableByWindowBackground = true
        hosting.rootView.onCollapse = { [weak newPanel, weak cardReveal, weak hosting] collapsed in
            guard let panel = newPanel else { return }
            if collapsed { cardReveal?.pauseTeaching() }
            // Opened again, it fits the state it is in now (which may not be the one it opened with).
            let open = cardReveal?.state == 0 ? size : (hosting?.fittingSize ?? size)
            let height = collapsed ? 112.0 : open.height
            panel.setFrame(CGRect(x: panel.frame.minX, y: panel.frame.maxY - height, width: open.width, height: height), display: true)
        }
        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()
        // A new state may be bigger or smaller: the panel grows at once (top edge kept) and
        // shrinks once the morph has settled, so nothing is clipped on the way.
        cardReveal.onStateChange = { [weak newPanel, weak hosting, weak cardReveal] _ in
            guard let panel = newPanel, let hosting, let reveal = cardReveal else { return }
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: CookieCard.summary(reveal.content), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            guard !reveal.collapsed else { return }
            func fit(_ size: CGSize) {
                panel.setFrame(CGRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height), display: true)
            }
            let next = hosting.fittingSize
            if next.height >= panel.frame.height || next.width >= panel.frame.width {
                fit(CGSize(width: max(next.width, panel.frame.width), height: max(next.height, panel.frame.height)))
            }
            Task { @MainActor [weak panel, weak hosting] in
                try? await Task.sleep(for: .milliseconds(650))
                guard let panel, let hosting, !reveal.collapsed else { return }
                let settled = hosting.fittingSize
                panel.setFrame(CGRect(x: panel.frame.minX, y: panel.frame.maxY - settled.height, width: settled.width, height: settled.height), display: true)
            }
        }
        cardReveal.onFocus = { [weak newPanel, weak cardReveal] local in
            guard let panel = newPanel, let reveal = cardReveal else { return }
            CookieHand.shared.teach(owner: reveal.teachingOwner,
                at: CGPoint(x: panel.frame.minX + local.x, y: panel.frame.maxY - local.y))
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            newPanel.animator().alphaValue = 1
        }
        if let old = panel { fadeOut(old) }
        reveal?.stop()
        panel = newPanel
        reveal = cardReveal
        installMonitors()
        restartFadeTimer()
        // The card is drawn, so VoiceOver hears what it holds.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: card.spokenSummary, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        return cardReveal
    }

    private func fadeOut(_ panel: NSPanel) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.close()
        })
    }

    /// Something happened on the card (a beat, the pointer over it): the idle clock starts again.
    private func restartFadeTimer() {
        lastActive = Date()
        guard fadeTimer == nil else { return }
        fadeTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, let reveal = self.reveal else { return }
                switch CookieLessonIdle.step(idle: Date().timeIntervalSince(self.lastActive), collapsed: reveal.collapsed) {
                case .close: self.dismiss(); return
                case .collapse: reveal.collapsed = true
                case .stay: break
                }
            }
        }
    }

    /// Beside the marks when there are any (right, else left, else below or above them), else
    /// beside the notch, hanging from the menu bar. Kept 12 pt inside the screen's visible area.
    static func frame(for panelSize: CGSize, near region: (rect: CGRect, display: CGRect)?) -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = region.flatMap { target in NSScreen.screens.first { $0.frame == target.display }?.visibleFrame } ?? screen.visibleFrame
        var avoided = region.map { [$0.rect] } ?? []
        if let element = MacOperator.focusedElement(), let rect = MacOperator.frame(element),
           let mainHeight = NSScreen.screens.first?.frame.height {
            let focused = CookieDrawingResolver.appKit(rect, mainHeight: mainHeight)
            // Full-window accessibility containers provide no useful pane information.
            if focused.width * focused.height < visible.width * visible.height * 0.8 {
                avoided.append(focused.insetBy(dx: -24, dy: -24))
            }
        }
        avoided.append(CGRect(x: mouse.x - 130, y: mouse.y - 100, width: 260, height: 200))
        return teachingFrame(size: panelSize, visible: visible, avoiding: avoided)
    }

    /// Prefer the left and centre, then choose the candidate covering least active content.
    static func teachingFrame(size: CGSize, visible: CGRect, avoiding areas: [CGRect]) -> CGRect {
        let bounds = visible.insetBy(dx: 16, dy: 16)
        let size = CGSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
        let columns: [CGFloat] = [0, 0.5, 1]
        let rows: [CGFloat] = [0.5, 0.2, 0.8]
        let candidates = rows.flatMap { row in columns.map { column in
            CGRect(x: bounds.minX + (bounds.width - size.width) * column,
                   y: bounds.minY + (bounds.height - size.height) * row,
                   width: size.width, height: size.height)
        }}
        func overlap(_ candidate: CGRect) -> CGFloat {
            areas.reduce(0) { total, area in
                let intersection = candidate.intersection(area)
                return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
            }
        }
        return candidates.enumerated().min { left, right in
            let lhs = overlap(left.element), rhs = overlap(right.element)
            return abs(lhs - rhs) < 1 ? left.offset < right.offset : lhs < rhs
        }!.element
    }

    // MARK: Pointer and keys

    /// The close control in screen coordinates (with a little slack): the one place the card takes clicks.
    private var closeRect: CGRect {
        guard let panel else { return .null }
        let side = CookieCardView.closeSize, inset = CookieCardView.shadowMargin + CookieCardView.closeInset
        return CGRect(x: panel.frame.maxX - inset - side, y: panel.frame.maxY - inset - side, width: side, height: side).insetBy(dx: -4, dy: -4)
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let follow: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                let over = panel.frame.insetBy(dx: CookieCardView.shadowMargin, dy: CookieCardView.shadowMargin).contains(NSEvent.mouseLocation)
                panel.ignoresMouseEvents = !over
                if over { self.lastActive = Date() }
            }
        }
        if let moved = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: follow) { monitors.append(moved) }
        if let moved = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { follow($0); return $0 }) { monitors.append(moved) }
        // Escape in another app belongs to that app (a dialog, a search): it closes the card only with
        // the pointer over it, or when Cookie is the app in front.
        let escape: (NSEvent, Bool) -> Void = { [weak self] event, local in
            MainActor.assumeIsolated {
                guard event.keyCode == 53, let self, let panel = self.panel else { return }
                let anywhere = self.escapeAnywhere ? CookieEscape.shared.claims(.card, at: event.timestamp, local: local) : local
                if anywhere || panel.frame.contains(NSEvent.mouseLocation) { self.dismiss() }
            }
        }
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { escape($0, false) }) { monitors.append(keys) }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { escape($0, true); return $0 }) { monitors.append(keys) }
    }
}

/// Borderless, never key or main, on every Space, above ordinary windows. Scenes float in one too.
final class CookieCardPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = CookieWindowLevel.card
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The close control answers the first click even though Cookie isn't the active app.
private final class CookieCardHostingView: NSHostingView<CookieCardView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
