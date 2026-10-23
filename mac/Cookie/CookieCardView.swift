//
//  CookieCardView.swift
//  Cookie
//
//  Draws an explainer card (`CookieCard`) in Cookie's paper-card language:
//  warm paper (charcoal in Dark Mode), rounded type, and the same hand ink
//  as the marks (`CookieInk`) for its rules, rings, boxes and arrows. Each
//  element fades up and its ink draws on when its beat comes; Reduce Motion
//  shows the card whole. `CookieCardPresenter` floats it beside the notch or
//  beside what the reply's marks point at, click-through except its close
//  control, one card at a time.
//

import AppKit
import SwiftUI

/// How much of a card is showing: elements before `shown` are visible.
@MainActor
final class CookieCardReveal: ObservableObject {
    let card: CookieCard
    let elements: [CookieCard.Element]
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
    func reveal(through index: Int, instant: Bool) {
        target = max(target, min(elements.count, index + 1))
        if instant {
            stagger?.cancel()
            stagger = nil
            shown = target
            return
        }
        guard stagger == nil else { return }
        stagger = Task { [weak self] in
            while let self, !Task.isCancelled, self.shown < self.target {
                self.shown += 1
                try? await Task.sleep(for: .milliseconds(120))
            }
            self?.stagger = nil
        }
    }

    func stop() {
        stagger?.cancel()
        stagger = nil
    }
}

// MARK: - Ink

/// Hand-drawn figures in the shape's own unit square (0...1 on each axis), inked on as `progress` goes 0 → 1.
struct CookieCardInk: Shape {
    enum Figure {
        case line(CGPoint, CGPoint)
        case ring(CGRect)
        case box(CGRect)
        case arrow(CGPoint, CGPoint)
    }

    let figures: [Figure]
    let seed: UInt32
    var pen: CGFloat = 2
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    // ponytail: roughened and outlined every animation frame (a card has a few dozen short strokes);
    // cache per size if a card ever grows past that.
    func path(in rect: CGRect) -> Path {
        guard progress > 0 else { return Path() }
        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
        }
        var rough = CookieRough(seed: seed)
        rough.roughness = 0.7
        var strokes: [CookieInkStroke] = []
        func passes(_ lines: [[CGPoint]], firstOnly: Bool = false) {
            for (index, line) in lines.enumerated() where !(firstOnly && index % 2 == 1) {
                strokes.append(CookieInkStroke(line, size: index % 2 == 0 ? pen : pen * 0.7))
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
                let angle = atan2(b.y - a.y, b.x - a.x)
                let head: CGFloat = 8
                passes(rough.line(a, b), firstOnly: true)
                for side in [CGFloat(0.5), -0.5] {
                    passes(rough.line(b, CGPoint(x: b.x - head * cos(angle + side), y: b.y - head * sin(angle + side))), firstOnly: true)
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

// MARK: - Card

struct CookieCardView: View {
    @ObservedObject var reveal: CookieCardReveal
    var onClose: () -> Void

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

    private var card: CookieCard { reveal.card }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(card.spokenSummary)
    }

    private var width: CGFloat {
        switch card.content {
        case .compare(_, let columns): return columns.count == 3 ? 460 : 380
        case .flow: return max(280, flowCanvasSize.width + 36)
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
        switch card.content {
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
        case .flow(let title, let nodes, let edges, let rank, let across):
            titleView(title)
            flowCanvas(nodes: nodes, edges: edges, rank: rank, across: across)
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

    // MARK: Flow

    private static let nodeSize = CGSize(width: 112, height: 44)
    private static let rankGap: CGFloat = 40
    private static let nodeGap: CGFloat = 14

    /// Where each node's box sits on the flow canvas: ranks are columns (across) or rows (down),
    /// and a rank's nodes are centred on the rank with the widest spread.
    private func flowLayout(nodes: [CookieCard.Node], rank: [String: Int], across: Bool) -> (size: CGSize, boxes: [String: CGRect]) {
        let ranks = (rank.values.max() ?? 0) + 1
        var members: [[CookieCard.Node]] = Array(repeating: [], count: ranks)
        for node in nodes { members[rank[node.id] ?? 0].append(node) }
        let widest = CGFloat(members.map(\.count).max() ?? 1)
        let size = Self.nodeSize
        let along = CGFloat(ranks) * (across ? size.width : size.height) + CGFloat(ranks - 1) * Self.rankGap
        let spread = widest * (across ? size.height : size.width) + (widest - 1) * Self.nodeGap
        var boxes: [String: CGRect] = [:]
        for (level, group) in members.enumerated() {
            let count = CGFloat(group.count)
            let groupSpread = count * (across ? size.height : size.width) + (count - 1) * Self.nodeGap
            for (position, node) in group.enumerated() {
                let first = CGFloat(level) * ((across ? size.width : size.height) + Self.rankGap)
                let second = (spread - groupSpread) / 2 + CGFloat(position) * ((across ? size.height : size.width) + Self.nodeGap)
                boxes[node.id] = across
                    ? CGRect(x: first, y: second, width: size.width, height: size.height)
                    : CGRect(x: second, y: first, width: size.width, height: size.height)
            }
        }
        return (across ? CGSize(width: along, height: spread) : CGSize(width: spread, height: along), boxes)
    }

    private var flowCanvasSize: CGSize {
        guard case .flow(_, let nodes, _, let rank, let across) = card.content else { return .zero }
        return flowLayout(nodes: nodes, rank: rank, across: across).size
    }

    private func flowCanvas(nodes: [CookieCard.Node], edges: [CookieCard.Edge], rank: [String: Int], across: Bool) -> some View {
        let layout = flowLayout(nodes: nodes, rank: rank, across: across)
        let canvas = layout.size
        func unit(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x / canvas.width, y: point.y / canvas.height) }
        return ZStack(alignment: .topLeading) {
            ForEach(edges.indices, id: \.self) { index in
                let edge = edges[index]
                if let from = layout.boxes[edge.from], let to = layout.boxes[edge.to] {
                    // Box edge to box edge, a few points short of the target so the head reads.
                    let start = across ? CGPoint(x: from.maxX + 3, y: from.midY) : CGPoint(x: from.midX, y: from.maxY + 3)
                    let end = across ? CGPoint(x: to.minX - 4, y: to.midY) : CGPoint(x: to.midX, y: to.minY - 4)
                    inked([.arrow(unit(start), unit(end))], .edge(index), pen: 1.8)
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
            }
            ForEach(nodes, id: \.id) { node in
                if let box = layout.boxes[node.id] {
                    Text(node.label)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(inkText)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 8)
                        .frame(width: box.width, height: box.height)
                        .background(inked([.box(CGRect(x: 0.02, y: 0.04, width: 0.96, height: 0.92))], .node(node.id), pen: 1.8))
                        .position(x: box.midX, y: box.midY)
                        .appear(reveal.isShown(.node(node.id)), reduceMotion)
                }
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }

    // MARK: Ink helper

    /// Ink for one element: drawn on when the element shows (whole, under Reduce Motion).
    private func inked(_ figures: [CookieCardInk.Figure], _ element: CookieCard.Element, pen: CGFloat) -> some View {
        let shown = reveal.isShown(element)
        let index = reveal.elements.firstIndex(of: element) ?? 0
        return CookieCardInk(figures: figures, seed: UInt32(truncatingIfNeeded: index &* 2_654_435_761 &+ 17), pen: pen,
                             progress: shown ? 1 : 0)
            .fill(ink)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: shown)
            .allowsHitTesting(false)
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
@MainActor
final class CookieCardPresenter {
    private var panel: NSPanel?
    private var reveal: CookieCardReveal?
    private var schedules: [CookieSpeechClock.Scheduled] = []
    private weak var clock: CookieSpeechClock?
    private var monitors: [Any] = []
    private var fadeTimer: Task<Void, Never>?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Puts each card on the speech clock: it appears at its tag and its elements follow the
    /// sentence after it. Call from `onPlaybackStarted`. Later cards replace earlier ones.
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
        let cardReveal = CookieCardReveal(card: card)
        let hosting = CookieCardHostingView(rootView: CookieCardView(reveal: cardReveal, onClose: { [weak self] in self?.dismiss() }))
        let size = hosting.fittingSize
        let newPanel = CookieCardPanel(contentRect: Self.frame(for: size, near: region))
        newPanel.contentView = hosting
        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            newPanel.animator().alphaValue = 1
        }
        if let old = panel { fadeOut(old) }
        reveal?.stop()
        panel = newPanel
        reveal = cardReveal
        installMonitors()
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

    /// Fades like the marks: 45 s after the last element arrived.
    private func restartFadeTimer() {
        fadeTimer?.cancel()
        fadeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// Beside the marks when there are any (right, else left, else below or above them), else
    /// beside the notch, hanging from the menu bar. Kept on the screen's visible area.
    static func frame(for panelSize: CGSize, near region: (rect: CGRect, display: CGRect)?) -> CGRect {
        let margin = CookieCardView.shadowMargin
        let size = CGSize(width: panelSize.width - margin * 2, height: panelSize.height - margin * 2)
        let gap: CGFloat = 24
        var card: CGRect
        let visible: CGRect
        if let region {
            visible = NSScreen.screens.first { $0.frame == region.display }?.visibleFrame ?? region.display
            let area = region.rect
            if area.maxX + gap + size.width <= visible.maxX - 8 {
                card = CGRect(x: area.maxX + gap, y: area.maxY - size.height, width: size.width, height: size.height)
            } else if area.minX - gap - size.width >= visible.minX + 8 {
                card = CGRect(x: area.minX - gap - size.width, y: area.maxY - size.height, width: size.width, height: size.height)
            } else {
                let below = area.minY - gap - size.height
                card = CGRect(x: area.midX - size.width / 2, y: below >= visible.minY + 8 ? below : area.maxY + gap,
                              width: size.width, height: size.height)
            }
        } else {
            let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
            visible = screen.visibleFrame
            var notchWidth: CGFloat = 190
            if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                notchWidth = screen.frame.width - left.width - right.width
            }
            card = CGRect(x: screen.frame.midX + notchWidth / 2 + 16, y: visible.maxY - 8 - size.height,
                          width: size.width, height: size.height)
        }
        card.origin.x = min(max(card.minX, visible.minX + 8), visible.maxX - 8 - card.width)
        card.origin.y = min(max(card.minY, visible.minY + 8), visible.maxY - 8 - card.height)
        return card.insetBy(dx: -margin, dy: -margin)
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
                panel.ignoresMouseEvents = !self.closeRect.contains(NSEvent.mouseLocation)
            }
        }
        if let moved = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: follow) { monitors.append(moved) }
        if let moved = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { follow($0); return $0 }) { monitors.append(moved) }
        // A click in another app, or Escape anywhere: the person has moved on.
        if let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) { monitors.append(clicks) }
        if let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel { self.dismiss() }
            }
            return event
        }) { monitors.append(clicks) }
        let escape: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { if event.keyCode == 53 { self?.dismiss() } }
        }
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: escape) { monitors.append(keys) }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { escape($0); return $0 }) { monitors.append(keys) }
    }
}

/// Borderless, never key or main, on every Space, above ordinary windows. Scenes float in one too.
final class CookieCardPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
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
