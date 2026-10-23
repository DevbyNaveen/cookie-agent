//
//  CookieMarksLayer.swift
//  Cookie
//
//  Draws Cookie's marks on one display's overlay: hand-drawn strokes in
//  Cookie's blue, animated on in the order they were written, labels in
//  small pills, numbers in filled discs. Everything is click-through.
//

import SwiftUI

struct CookieMarksLayer: View {
    let marks: [CookieResolvedDrawing]
    let screenFrame: CGRect
    /// Everything at once, no strokes animating: previews, and people who asked for less motion.
    var instant = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: Set<UUID> = []

    private var mine: [CookieResolvedDrawing] { marks.filter { $0.displayFrame == screenFrame } }

    var body: some View {
        ZStack {
            ForEach(Array(mine.enumerated()), id: \.element.id) { index, mark in
                MarkView(mark: mark, local: local, progress: drawn.contains(mark.id) ? 1 : 0)
            }
        }
        .allowsHitTesting(false)
        .onAppear { reveal() }
        .onChange(of: marks.map(\.id)) { _, _ in reveal() }
    }

    /// Each mark draws itself over 0.55 s, starting 0.3 s after the one before.
    private func reveal() {
        if instant || reduceMotion {
            drawn = Set(mine.map(\.id))
            return
        }
        drawn = []
        for (index, mark) in mine.enumerated() {
            withAnimation(.easeOut(duration: 0.55).delay(Double(index) * 0.3)) { _ = drawn.insert(mark.id) }
        }
    }

    /// AppKit global (bottom-left) → this overlay's SwiftUI coordinates (top-left).
    private func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - screenFrame.origin.x, y: (screenFrame.origin.y + screenFrame.height) - point.y)
    }
}

private struct MarkView: View {
    let mark: CookieResolvedDrawing
    let local: (CGPoint) -> CGPoint
    var progress: Double

    private let ink = DS.Colors.overlayCursorBlue
    private let stroke = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)

    var body: some View {
        switch mark.geometry {
        case .circle(let rect):
            let r = localRect(rect)
            HandDrawn.ring(in: r).trim(from: 0, to: progress).stroke(ink, style: stroke).glow(ink)
            label(at: CGPoint(x: r.maxX + 8, y: r.minY - 6), leading: true)
        case .arrow(let from, let to):
            let a = local(from), b = local(to)
            HandDrawn.arrow(from: a, to: b).trim(from: 0, to: progress).stroke(ink, style: stroke).glow(ink)
            label(at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 14), leading: false)
        case .underline(let from, let to):
            let a = local(from), b = local(to)
            HandDrawn.line(from: a, to: b, wave: 1.6).trim(from: 0, to: progress).stroke(ink, style: stroke).glow(ink)
            label(at: CGPoint(x: b.x + 8, y: b.y), leading: true)
        case .bracket(let x, let top, let bottom):
            let t = local(CGPoint(x: x, y: top)), b = local(CGPoint(x: x, y: bottom))
            HandDrawn.bracket(x: t.x, top: t.y, bottom: b.y).trim(from: 0, to: progress).stroke(ink, style: stroke).glow(ink)
            label(at: CGPoint(x: t.x - 10, y: (t.y + b.y) / 2), leading: false, trailing: true)
        case .note(let point):
            let p = local(point)
            notePill.position(x: p.x + 6, y: p.y).opacity(progress).scaleEffect(0.8 + 0.2 * progress, anchor: .leading)
        case .number(let point):
            let p = local(point)
            ZStack {
                Circle().fill(ink).frame(width: 24, height: 24)
                Text(mark.text).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
            .shadow(color: ink.opacity(0.55), radius: 6)
            .position(x: p.x - 2, y: p.y - 2)
            .scaleEffect(progress, anchor: .center)
            .opacity(progress)
        }
    }

    private func localRect(_ rect: CGRect) -> CGRect {
        let topLeft = local(CGPoint(x: rect.minX, y: rect.maxY))
        return CGRect(x: topLeft.x, y: topLeft.y, width: rect.width, height: rect.height)
    }

    @ViewBuilder
    private func label(at point: CGPoint, leading: Bool, trailing: Bool = false) -> some View {
        if !mark.text.isEmpty {
            Text(mark.text)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ink))
                .fixedSize()
                .modifier(Anchored(point: point, leading: leading, trailing: trailing))
                .opacity(progress)
        }
    }

    private var notePill: some View {
        HStack(spacing: 6) {
            Rectangle().fill(ink).frame(width: 14, height: 2)
            Text(mark.text)
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ink))
                .shadow(color: ink.opacity(0.5), radius: 6)
        }
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

private extension View {
    func glow(_ color: Color) -> some View {
        shadow(color: color.opacity(0.55), radius: 5)
    }
}

/// Strokes with a little life in them: a hand's wobble, never a ruler's line.
enum HandDrawn {
    /// A ring that overshoots its start a touch, like a pen circling twice.
    static func ring(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 64
        let cx = rect.midX, cy = rect.midY
        for index in 0...steps {
            let t = Double(index) / Double(steps)
            let angle = -Double.pi / 2 + t * (Double.pi * 2 + 0.35)
            let wobble = 1 + 0.028 * sin(t * 13.0 + 0.7) + 0.018 * sin(t * 29.0)
            let rx = (rect.width / 2) * wobble, ry = (rect.height / 2) * wobble
            let point = CGPoint(x: cx + rx * cos(angle), y: cy + ry * sin(angle))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// A line that bows a little and wavers along its length.
    static func line(from a: CGPoint, to b: CGPoint, wave: CGFloat = 1.2, bow: CGFloat = 0) -> Path {
        var path = Path()
        let steps = 32
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(1, hypot(dx, dy))
        let nx = -dy / length, ny = dx / length
        for index in 0...steps {
            let t = CGFloat(index) / CGFloat(steps)
            let along = CGPoint(x: a.x + dx * t, y: a.y + dy * t)
            let offset = wave * sin(t * 17) * 0.6 + bow * sin(t * .pi)
            let point = CGPoint(x: along.x + nx * offset, y: along.y + ny * offset)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// A gently curved shaft with an open head.
    static func arrow(from a: CGPoint, to b: CGPoint) -> Path {
        var path = line(from: a, to: b, wave: 1.0, bow: 10)
        let angle = atan2(b.y - a.y, b.x - a.x)
        let head: CGFloat = 13
        for side in [CGFloat(0.5), -0.5] {
            let tip = CGPoint(x: b.x - head * cos(angle + side), y: b.y - head * sin(angle + side))
            path.move(to: tip)
            path.addLine(to: b)
        }
        return path
    }

    /// A square bracket on the left of a block.
    static func bracket(x: CGFloat, top: CGFloat, bottom: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: x + 8, y: top))
        path.addLine(to: CGPoint(x: x, y: top + 1))
        path.addLine(to: CGPoint(x: x + 0.8, y: (top + bottom) / 2))
        path.addLine(to: CGPoint(x: x, y: bottom - 1))
        path.addLine(to: CGPoint(x: x + 8, y: bottom))
        return path
    }
}
