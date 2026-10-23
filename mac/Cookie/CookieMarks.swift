//
//  CookieMarks.swift
//  Cookie
//
//  Cookie draws on the screen. Pointing says "there"; a mark says "this,
//  then this, and here's why": a circle around a cell, an arrow to the
//  range it should cover, a note beside it, numbers on the controls of a
//  route. Marks ride on the same overlay as the pointer, in the same
//  screenshot-pixel space, or anchored to an element id from `look`, and
//  snap to the real control under them so they land exactly.
//

import AppKit
import ApplicationServices
import Foundation

/// One mark the model asked for, as written in its reply.
struct CookieDrawing: Equatable {
    enum Kind: String, CaseIterable { case circle, arrow, underline, bracket, note, number }
    enum Anchor: Equatable {
        /// Screenshot pixels (top-left origin), as the model sees them.
        case pixels([CGPoint])
        /// An element id from the latest `look`.
        case element(Int)
    }

    let kind: Kind
    let anchor: Anchor
    /// Circle: radius in pixels. Underline/bracket: the far coordinate. Nil otherwise.
    let extent: Double?
    /// A short label beside the mark; a note's text; a number's digits.
    let text: String
    /// 1-based screen from the image labels; nil means the cursor's screen.
    let screenNumber: Int?

    /// UTF-16 offset in the spoken text where the tag sat: the mark draws when speech reaches it.
    var offset = 0

    static let maxMarks = 6
    /// A DRAW tag's body: "kind:where[:label][:screenN]".
    private static let body = try? NSRegularExpression(pattern: #"^(circle|arrow|underline|bracket|note|number):([^:]+)(?::(.*?))?(?::screen(\d+))?$"#,
                                                       options: [.dotMatchesLineSeparators])

    /// Pulls every [DRAW:…] tag out of a reply: the text without them, and the marks in order,
    /// each with its place in that text. Any DRAW tag, known kind or not, leaves the text.
    static func parse(from text: String) -> (text: String, marks: [CookieDrawing]) {
        let (spoken, tags) = CookieReplyTags.split(text, kinds: ["DRAW"])
        return (spoken, Array(tags.compactMap(CookieDrawing.init(tag:)).prefix(maxMarks)))
    }

    init(kind: Kind, anchor: Anchor, extent: Double?, text: String, screenNumber: Int?, offset: Int = 0) {
        self.kind = kind
        self.anchor = anchor
        self.extent = extent
        self.text = text
        self.screenNumber = screenNumber
        self.offset = offset
    }

    /// One mark from a DRAW tag, or nil when the tag doesn't describe one.
    init?(tag: CookieReplyTag) {
        let text = tag.body
        guard tag.kind == "DRAW", let regex = Self.body,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let kindRange = Range(match.range(at: 1), in: text), let kind = Kind(rawValue: String(text[kindRange])),
              let whereRange = Range(match.range(at: 2), in: text) else { return nil }
        let label = Range(match.range(at: 3), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
        let screen = Range(match.range(at: 4), in: text).flatMap { Int(text[$0]) }
        let place = text[whereRange].trimmingCharacters(in: .whitespaces)
        let anchor: Anchor
        var extent: Double?
        if place.hasPrefix("#"), let id = Int(place.dropFirst()) {
            anchor = .element(id)
        } else {
            let numbers = place.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            switch kind {
            case .circle:
                guard numbers.count >= 2 else { return nil }
                anchor = .pixels([CGPoint(x: numbers[0], y: numbers[1])])
                extent = numbers.count >= 3 ? max(8, numbers[2]) : 28
            case .arrow:
                guard numbers.count >= 4 else { return nil }
                anchor = .pixels([CGPoint(x: numbers[0], y: numbers[1]), CGPoint(x: numbers[2], y: numbers[3])])
            case .underline:
                guard numbers.count >= 3 else { return nil }
                anchor = .pixels([CGPoint(x: numbers[0], y: numbers[2])])
                extent = numbers[1]
            case .bracket:
                guard numbers.count >= 3 else { return nil }
                anchor = .pixels([CGPoint(x: numbers[0], y: numbers[1])])
                extent = numbers[2]
            case .note, .number:
                guard numbers.count >= 2 else { return nil }
                anchor = .pixels([CGPoint(x: numbers[0], y: numbers[1])])
            }
        }
        if kind == .note || kind == .number { guard !label.isEmpty else { return nil } }
        self.init(kind: kind, anchor: anchor, extent: extent, text: String(label.prefix(kind == .note ? 80 : 24)),
                  screenNumber: screen, offset: tag.offset)
    }
}

/// A mark placed on a display, in AppKit global points (bottom-left origin).
struct CookieResolvedDrawing: Equatable, Identifiable {
    enum Geometry: Equatable {
        case circle(CGRect)
        case arrow(from: CGPoint, to: CGPoint)
        case underline(from: CGPoint, to: CGPoint)
        case bracket(x: CGFloat, top: CGFloat, bottom: CGFloat)
        case note(CGPoint)
        case number(CGPoint)
    }
    let id = UUID()
    let geometry: Geometry
    let text: String
    /// The display it belongs to (AppKit frame), so each overlay draws its own.
    let displayFrame: CGRect
    /// Where its tag sat in the spoken text (`CookieDrawing.offset`).
    var offset = 0
    /// When its ink starts, in `CACurrentMediaTime()` seconds; set when the mark is shown.
    var revealedAt: Double = 0

    /// The same wobble every frame and every redraw: seeded by where the mark is, not by chance.
    var seed: UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in "\(geometry)\(text)".utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash == 0 ? 1 : hash
    }
}

enum CookieDrawingResolver {
    /// The screenshot a mark refers to: its screen number, else the cursor's screen.
    static func capture(for mark: CookieDrawing, in captures: [CompanionScreenCapture]) -> CompanionScreenCapture? {
        if let number = mark.screenNumber, number >= 1, number <= captures.count { return captures[number - 1] }
        return captures.first { $0.isCursorScreen } ?? captures.first
    }

    /// Screenshot pixels → AppKit global points on that capture's display.
    static func global(_ point: CGPoint, in capture: CompanionScreenCapture) -> CGPoint {
        let sx = CGFloat(capture.displayWidthInPoints) / CGFloat(max(1, capture.screenshotWidthInPixels))
        let sy = CGFloat(capture.displayHeightInPoints) / CGFloat(max(1, capture.screenshotHeightInPixels))
        let x = max(0, min(point.x, CGFloat(capture.screenshotWidthInPixels))) * sx
        let y = max(0, min(point.y, CGFloat(capture.screenshotHeightInPixels))) * sy
        return CGPoint(x: x + capture.displayFrame.origin.x, y: (CGFloat(capture.displayHeightInPoints) - y) + capture.displayFrame.origin.y)
    }

    /// Pixels per point on a capture, for radii and extents.
    static func scale(of capture: CompanionScreenCapture) -> CGFloat {
        CGFloat(capture.displayWidthInPoints) / CGFloat(max(1, capture.screenshotWidthInPixels))
    }

    /// An AX frame (CG global, top-left origin) → AppKit global.
    static func appKit(_ frame: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Lays every mark on its display: pixel marks scaled like the pointer, element marks from
    /// their `look` frame, and pixel marks snapped to the control under them when one is close.
    @MainActor
    static func resolve(_ marks: [CookieDrawing], captures: [CompanionScreenCapture],
                        elementFrame: (Int) -> CGRect?, snap: (CGPoint) -> CGRect? = CookieDrawingResolver.controlFrame) -> [CookieResolvedDrawing] {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        func place(_ mark: CookieDrawing) -> CookieResolvedDrawing? {
            switch mark.anchor {
            case .element(let id):
                guard let frame = elementFrame(id) else { return nil }
                let rect = appKit(frame, mainHeight: mainHeight)
                let display = NSScreen.screens.first { $0.frame.intersects(rect) }?.frame ?? NSScreen.main?.frame ?? .zero
                return CookieResolvedDrawing(geometry: geometry(mark.kind, around: rect, from: nil, to: nil), text: mark.text, displayFrame: display)
            case .pixels(let points):
                guard let capture = capture(for: mark, in: captures), let first = points.first else { return nil }
                let scale = scale(of: capture)
                let anchor = global(first, in: capture)
                let display = capture.displayFrame
                switch mark.kind {
                case .arrow:
                    guard points.count >= 2 else { return nil }
                    var to = global(points[1], in: capture)
                    // The head lands on the control it was aimed at.
                    if let control = snap(to), control.width < 700, control.height < 400 {
                        let rect = appKit(control, mainHeight: mainHeight)
                        to = CGPoint(x: rect.midX, y: rect.midY)
                    }
                    return CookieResolvedDrawing(geometry: .arrow(from: anchor, to: to), text: mark.text, displayFrame: display)
                case .circle:
                    let radius = CGFloat(mark.extent ?? 28) * scale
                    var rect = CGRect(x: anchor.x - radius, y: anchor.y - radius, width: radius * 2, height: radius * 2)
                    if let control = snap(anchor), control.width < 700, control.height < 400 { rect = appKit(control, mainHeight: mainHeight) }
                    return CookieResolvedDrawing(geometry: geometry(.circle, around: rect, from: nil, to: nil), text: mark.text, displayFrame: display)
                case .underline:
                    let far = global(CGPoint(x: CGFloat(mark.extent ?? first.x + 120), y: first.y), in: capture)
                    if let control = snap(anchor), control.width < 700, control.height < 400 {
                        let rect = appKit(control, mainHeight: mainHeight)
                        return CookieResolvedDrawing(geometry: geometry(.underline, around: rect, from: nil, to: nil), text: mark.text, displayFrame: display)
                    }
                    return CookieResolvedDrawing(geometry: .underline(from: anchor, to: far), text: mark.text, displayFrame: display)
                case .bracket:
                    let far = global(CGPoint(x: first.x, y: CGFloat(mark.extent ?? first.y + 120)), in: capture)
                    return CookieResolvedDrawing(geometry: .bracket(x: anchor.x, top: max(anchor.y, far.y), bottom: min(anchor.y, far.y)), text: mark.text, displayFrame: display)
                case .note:
                    return CookieResolvedDrawing(geometry: .note(anchor), text: mark.text, displayFrame: display)
                case .number:
                    var point = anchor
                    if let control = snap(anchor), control.width < 700, control.height < 400 {
                        let rect = appKit(control, mainHeight: mainHeight)
                        point = CGPoint(x: rect.minX, y: rect.maxY)
                    }
                    return CookieResolvedDrawing(geometry: .number(point), text: mark.text, displayFrame: display)
                }
            }
        }
        return marks.compactMap { mark -> CookieResolvedDrawing? in
            var placed = place(mark)
            placed?.offset = mark.offset
            return placed
        }
    }

    /// A mark's shape around a known control frame (AppKit global).
    static func geometry(_ kind: CookieDrawing.Kind, around rect: CGRect, from: CGPoint?, to: CGPoint?) -> CookieResolvedDrawing.Geometry {
        switch kind {
        case .circle: return .circle(rect.insetBy(dx: -7, dy: -6))
        case .underline: return .underline(from: CGPoint(x: rect.minX, y: rect.minY - 3), to: CGPoint(x: rect.maxX, y: rect.minY - 3))
        case .bracket: return .bracket(x: rect.minX - 8, top: rect.maxY + 2, bottom: rect.minY - 2)
        case .note: return .note(CGPoint(x: rect.maxX + 6, y: rect.midY))
        case .number: return .number(CGPoint(x: rect.minX, y: rect.maxY))
        case .arrow: return .arrow(from: CGPoint(x: rect.minX - 60, y: rect.midY + 40), to: CGPoint(x: rect.midX, y: rect.midY))
        }
    }

    /// The control under an AppKit global point, as an AX frame (CG global), when there is one
    /// and it isn't the whole window. Nil without Accessibility access.
    @MainActor
    static func controlFrame(at appKitPoint: CGPoint) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(appKitPoint.x), Float(mainHeight - appKitPoint.y), &element) == .success,
              let element, let frame = MacOperator.frame(element), frame.width > 2, frame.height > 2 else { return nil }
        let role = MacOperator.string(element, kAXRoleAttribute) ?? ""
        guard !["AXWindow", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXWebArea", "AXApplication", "AXLayoutArea"].contains(role) else { return nil }
        return frame
    }
}
