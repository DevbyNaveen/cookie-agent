//
//  CookieMarksLayer.swift
//  Cookie
//
//  Draws Cookie's marks on one display's overlay in Cookie's amber ink: each
//  stroke roughened and inked as a pen would (`CookieInk`), drawn on from the
//  moment its mark is shown (on its word, when Cookie speaks), labels in small
//  pills, numbers in filled discs. Frames come from the overlay window's own
//  display link at the screen's top rate (120 Hz on ProMotion) and stop when
//  the ink is dry. Reduce Motion shows each mark whole, still on its word.
//  Everything is click-through.
//
//  Cookie's hand draws it: for each mark the pointer first glides to where the
//  stroke begins (`lead`), the ink starts as it lands, the pointer rides the pen
//  tip round the stroke, and rests at the end a moment (`hold`) before going
//  back to the person's cursor. `onPen` reports the hand every frame.
//

import AppKit
import QuartzCore
import SwiftUI

struct CookieMarksLayer: View {
    let marks: [CookieResolvedDrawing]
    let screenFrame: CGRect
    /// Everything at once, no strokes animating: previews.
    var instant = false
    /// Where Cookie's hand is, every frame; nil when it isn't drawing.
    var onPen: ((CookiePen?) -> Void)? = nil
    /// The hand's glide to a stroke before the ink starts.
    static let lead = 0.24
    /// How long the hand rests where a mark ends before it goes back.
    static let hold = 0.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var clock = CookieInkClock()
    @State private var cache = CookieInkCache()

    /// The orb's mid amber (the `mid` colour of CookieOrb's fluid).
    static let ink = Color(red: 0.93, green: 0.56, blue: 0.24)
    /// Text on ink: the orb's eye brown, readable on the amber.
    static let onInk = Color(red: 42 / 255, green: 20 / 255, blue: 6 / 255)

    private var mine: [CookieResolvedDrawing] { marks.filter { $0.displayFrame == screenFrame } }

    var body: some View {
        let now = clock.now
        ZStack {
            Canvas { context, _ in
                // One soft shadow under all the ink, so overlapping passes don't darken each other:
                // the amber holds on white pages, the shadow lifts it off dark ones.
                context.addFilter(.shadow(color: .black.opacity(0.38), radius: 2.5, x: 0, y: 1))
                context.drawLayer { ink in
                    for mark in mine {
                        let strokes = cache.strokes(for: mark, local: local)
                        let total = strokes.reduce(0) { $0 + $1.length }
                        var reach = total * CGFloat(progress(of: mark, at: now, length: total))
                        for stroke in strokes where reach > 0 {
                            if let outline = stroke.outline(revealed: min(stroke.length, reach)) {
                                ink.fill(Path(outline), with: .color(Self.ink))
                            }
                            reach -= stroke.length
                        }
                    }
                }
            }
            ForEach(mine) { mark in
                let length = cache.strokes(for: mark, local: local).reduce(0) { $0 + $1.length }
                MarkDecoration(mark: mark, local: local, progress: progress(of: mark, at: now, length: length))
            }
            CookieInkClockDriver(clock: clock).frame(width: 1, height: 1)
        }
        .allowsHitTesting(false)
        .onAppear { run() }
        .onChange(of: marks.map(\.revealedAt)) { _, _ in
            run()
            onPen?(pen(at: CACurrentMediaTime()))
        }
        .onChange(of: clock.now) { _, now in onPen?(pen(at: now)) }
        .onDisappear { onPen?(nil) }
    }

    /// How long a mark's ink takes: about a thousand points a second, never under a third of a
    /// second or over 0.9 s (brief motion; the voice is still the main channel).
    private func duration(length: CGFloat) -> Double {
        length > 0 ? min(0.9, max(0.35, Double(length) / 1000)) : 0.3
    }

    /// 0 until the hand has reached the mark, then the pen's progress along all its strokes, eased.
    private func progress(of mark: CookieResolvedDrawing, at now: Double, length: CGFloat) -> Double {
        if instant || mark.revealedAt == 0 { return 1 }
        guard now >= mark.revealedAt else { return 0 }
        if reduceMotion { return 1 }
        let start = mark.revealedAt + Self.lead
        guard now >= start else { return 0 }
        let t = min(1, (now - start) / duration(length: length))
        return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    /// Keep frames coming until every mark shown so far is drawn and labelled.
    private func run() {
        guard !instant else { return }
        let end = mine.map { mark in
            mark.revealedAt + Self.lead + duration(length: cache.strokes(for: mark, local: local).reduce(0) { $0 + $1.length })
                + Self.hold + 0.1
        }.max() ?? 0
        clock.run(until: end)
    }

    /// The hand on the mark shown most recently: travelling to its first stroke, on the pen tip
    /// while it inks, then resting at its end; nil once that rest is over, or with Reduce Motion
    /// (the marks simply appear, and the hand stays with the person).
    private func pen(at now: Double) -> CookiePen? {
        guard !instant, !reduceMotion,
              let mark = mine.filter({ $0.revealedAt > 0 && now >= $0.revealedAt }).max(by: { $0.revealedAt < $1.revealedAt })
        else { return nil }
        let strokes = cache.strokes(for: mark, local: local)
        let total = strokes.reduce(0) { $0 + $1.length }
        let start = mark.revealedAt + Self.lead
        guard now <= start + duration(length: total) + Self.hold else { return nil }
        guard let first = strokes.first?.pen(at: 0) else {
            // A note or a number has no stroke: the hand goes to its spot and stays a moment.
            return spot(of: mark).map { CookiePen(point: $0, degrees: -35, travelling: now < start) }
        }
        if now < start { return CookiePen(point: first.point, degrees: Self.degrees(first.heading), travelling: true) }
        var reach = total * CGFloat(progress(of: mark, at: now, length: total))
        for stroke in strokes {
            if reach <= stroke.length, let tip = stroke.pen(at: reach) {
                return CookiePen(point: tip.point, degrees: Self.degrees(tip.heading), travelling: false)
            }
            reach -= stroke.length
        }
        guard let last = strokes.last, let end = last.pen(at: last.length) else { return nil }
        return CookiePen(point: end.point, degrees: Self.degrees(end.heading), travelling: false)
    }

    /// A heading (radians) as the pointer's turn: its tip leads the way the pen moves.
    private static func degrees(_ heading: CGFloat) -> Double { Double(heading) * 180 / .pi + 90 }

    private func spot(of mark: CookieResolvedDrawing) -> CGPoint? {
        switch mark.geometry {
        case .note(let point), .number(let point): return local(point)
        default: return nil
        }
    }

    /// AppKit global (bottom-left) → this overlay's SwiftUI coordinates (top-left).
    private func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - screenFrame.origin.x, y: (screenFrame.origin.y + screenFrame.height) - point.y)
    }
}

/// Where Cookie's hand is while it draws, in the overlay's own coordinates: the pen point, the
/// pointer's turn (CookiePointer degrees, 0 = tip up), and whether it is still gliding there.
struct CookiePen: Equatable {
    var point: CGPoint
    var degrees: Double
    var travelling: Bool
}

/// Each mark's pen strokes, worked out once: the same seed gives the same wobble, so a mark
/// never shimmers between frames.
final class CookieInkCache {
    private var strokes: [UUID: [CookieInkStroke]] = [:]
    private static let pen: CGFloat = 3.4

    func strokes(for mark: CookieResolvedDrawing, local: (CGPoint) -> CGPoint) -> [CookieInkStroke] {
        if let known = strokes[mark.id] { return known }
        var rough = CookieRough(seed: mark.seed)
        let pen = Self.pen
        // A pass and its echo: the echo a finer pen, as a hand going over it again.
        func passes(_ lines: [[CGPoint]]) -> [CookieInkStroke] {
            lines.enumerated().map { CookieInkStroke($0.element, size: $0.offset % 2 == 0 ? pen : pen * 0.7) }
        }
        func firstPasses(_ lines: [[CGPoint]]) -> [CookieInkStroke] {
            lines.enumerated().filter { $0.offset % 2 == 0 }.map { CookieInkStroke($0.element, size: pen) }
        }
        let made: [CookieInkStroke]
        switch mark.geometry {
        case .circle(let rect):
            let topLeft = local(CGPoint(x: rect.minX, y: rect.maxY))
            made = passes(rough.ellipse(center: CGPoint(x: topLeft.x + rect.width / 2, y: topLeft.y + rect.height / 2),
                                        width: rect.width, height: rect.height))
        case .arrow(let from, let to):
            let a = local(from), b = local(to)
            let length = max(1, hypot(b.x - a.x, b.y - a.y))
            // A gentle bow, then an open head drawn out from the tip.
            let bow = min(18, length * 0.08)
            let mid = CGPoint(x: (a.x + b.x) / 2 - (b.y - a.y) / length * bow, y: (a.y + b.y) / 2 + (b.x - a.x) / length * bow)
            let angle = atan2(b.y - mid.y, b.x - mid.x)
            let head: CGFloat = 14
            let barbs = [CGFloat(0.5), -0.5].flatMap { side in
                firstPasses(rough.line(b, CGPoint(x: b.x - head * cos(angle + side), y: b.y - head * sin(angle + side))))
            }
            made = passes(rough.curve(through: [a, mid, b])) + barbs
        case .underline(let from, let to):
            made = passes(rough.line(local(from), local(to)))
        case .bracket(let x, let top, let bottom):
            let t = local(CGPoint(x: x, y: top)), b = local(CGPoint(x: x, y: bottom))
            made = firstPasses(rough.linearPath([CGPoint(x: t.x + 8, y: t.y), t, b, CGPoint(x: b.x + 8, y: b.y)]))
        case .note, .number:
            made = []
        }
        strokes[mark.id] = made
        return made
    }
}

/// Labels, notes and numbers: SwiftUI views that arrive as the ink nears its end.
private struct MarkDecoration: View {
    let mark: CookieResolvedDrawing
    let local: (CGPoint) -> CGPoint
    var progress: Double

    private let ink = CookieMarksLayer.ink
    private let onInk = CookieMarksLayer.onInk
    /// A label shows over the last half of its stroke.
    private var labelProgress: Double { max(0, min(1, (progress - 0.5) * 2)) }

    var body: some View {
        switch mark.geometry {
        case .circle(let rect):
            let topLeft = local(CGPoint(x: rect.minX, y: rect.maxY))
            label(at: CGPoint(x: topLeft.x + rect.width + 8, y: topLeft.y - 6), leading: true)
        case .arrow(let from, let to):
            let a = local(from), b = local(to)
            label(at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 16), leading: false)
        case .underline(_, let to):
            let b = local(to)
            label(at: CGPoint(x: b.x + 8, y: b.y), leading: true)
        case .bracket(let x, let top, let bottom):
            let t = local(CGPoint(x: x, y: top)), b = local(CGPoint(x: x, y: bottom))
            label(at: CGPoint(x: t.x - 10, y: (t.y + b.y) / 2), leading: false, trailing: true)
        case .note(let point):
            let p = local(point)
            notePill.position(x: p.x + 6, y: p.y).opacity(progress).scaleEffect(0.8 + 0.2 * progress, anchor: .leading)
        case .number(let point):
            let p = local(point)
            ZStack {
                Circle().fill(ink).frame(width: 24, height: 24)
                Text(mark.text).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(onInk)
            }
            .shadow(color: .black.opacity(0.38), radius: 2.5, y: 1)
            .position(x: p.x - 2, y: p.y - 2)
            .scaleEffect(progress, anchor: .center)
            .opacity(progress)
        }
    }

    @ViewBuilder
    private func label(at point: CGPoint, leading: Bool, trailing: Bool = false) -> some View {
        if !mark.text.isEmpty {
            Text(mark.text)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(onInk)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ink))
                .shadow(color: .black.opacity(0.38), radius: 2.5, y: 1)
                .fixedSize()
                .modifier(Anchored(point: point, leading: leading, trailing: trailing))
                .opacity(labelProgress)
        }
    }

    private var notePill: some View {
        HStack(spacing: 6) {
            Rectangle().fill(ink).frame(width: 14, height: 2)
            Text(mark.text)
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(onInk)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ink))
        }
        .shadow(color: .black.opacity(0.38), radius: 2.5, y: 1)
        .fixedSize()
        .modifier(Anchored(point: .zero, leading: true, trailing: false))
    }
}

/// Places a fixed-size view so its leading (or trailing, or centre) edge sits at a point.
private struct Anchored: ViewModifier {
    let point: CGPoint
    let leading: Bool
    let trailing: Bool
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geo in Color.clear.preference(key: SizePreferenceKey.self, value: geo.size) })
            .onPreferenceChange(SizePreferenceKey.self) { size = $0 }
            .position(x: point.x + (leading ? size.width / 2 : trailing ? -size.width / 2 : 0), y: point.y)
    }
}

// MARK: - Frames

/// The time the ink is drawn at, ticked by the overlay window's display link while ink is wet.
@MainActor
final class CookieInkClock: ObservableObject {
    /// `CACurrentMediaTime()` seconds: the frame being drawn.
    @Published private(set) var now = CACurrentMediaTime()
    private(set) var until: Double = 0
    fileprivate weak var view: CookieInkClockView?

    func run(until end: Double) {
        until = max(until, end)
        now = CACurrentMediaTime()
        view?.wake()
    }

    fileprivate func tick(_ time: Double) -> Bool {
        now = time
        return time <= until
    }
}

private struct CookieInkClockDriver: NSViewRepresentable {
    let clock: CookieInkClock

    func makeNSView(context: Context) -> CookieInkClockView {
        let view = CookieInkClockView()
        view.clock = clock
        clock.view = view
        return view
    }

    func updateNSView(_ view: CookieInkClockView, context: Context) {}

    static func dismantleNSView(_ view: CookieInkClockView, coordinator: ()) {
        view.stop()
    }
}

/// Owns the display link: `NSView.displayLink` follows the display the overlay is on, and asks
/// for that screen's top rate (`maximumFramesPerSecond`); the system may still slow it for Low
/// Power Mode or heat. Paused whenever no ink is wet.
fileprivate final class CookieInkClockView: NSView {
    weak var clock: CookieInkClock?
    private var link: CADisplayLink?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        let top = Float(max(60, window.screen?.maximumFramesPerSecond ?? 60))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: top, preferred: top)
        link.isPaused = (clock?.until ?? 0) < CACurrentMediaTime()
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func wake() { link?.isPaused = false }

    /// The link holds this view; invalidating it breaks that hold.
    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let clock else { return stop() }
        if !clock.tick(link.targetTimestamp) { link.isPaused = true }
    }
}
