//
//  CookieSpotlight.swift
//  Cookie
//
//  While Cookie explains one part of a busy screen, the rest dims softly. A
//  [FOCUS:x,y,w,h] tag (screenshot pixels) or [FOCUS:#id] (an element from the
//  latest `look`) sits at the word where the explaining starts; the overlay
//  then shades every display except a soft-edged rounded cut-out around that
//  region. It fades in on its word, glides to the next FOCUS, and lifts when
//  Cookie stops speaking, on Escape or a click, or with the reply's marks.
//  It never shows while the person is typing, and it never takes a click.
//

import AppKit
import SwiftUI

/// One FOCUS tag, as written.
struct CookieFocus: Equatable {
    /// Pixels: the region's top-left and bottom-right corners.
    let anchor: CookieDrawing.Anchor
    let screenNumber: Int?
    /// UTF-16 offset in the spoken text where the tag sat.
    var offset = 0

    /// A FOCUS tag's body: "x,y,w,h" or "#id", either with an optional ":screenN".
    init?(tag: CookieReplyTag) {
        guard tag.kind == "FOCUS" else { return nil }
        let parts = tag.body.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let place = parts.first, parts.count <= 2 else { return nil }
        if parts.count == 2 {
            guard parts[1].hasPrefix("screen"), let number = Int(parts[1].dropFirst(6)) else { return nil }
            screenNumber = number
        } else {
            screenNumber = nil
        }
        if place.hasPrefix("#") {
            guard let id = Int(place.dropFirst()) else { return nil }
            anchor = .element(id)
        } else {
            let numbers = place.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
            anchor = .pixels([CGPoint(x: numbers[0], y: numbers[1]), CGPoint(x: numbers[0] + numbers[2], y: numbers[1] + numbers[3])])
        }
        offset = tag.offset
    }
}

/// The region to keep lit, in AppKit global points, and the display it is on.
struct CookieSpotlight: Equatable {
    let rect: CGRect
    let displayFrame: CGRect
    var pointerLocation: CGPoint { CGPoint(x: rect.minX + min(12, rect.width / 2), y: rect.maxY - min(12, rect.height / 2)) }
}

extension CookieDrawingResolver {
    /// A FOCUS tag on its display: pixel corners scaled like marks, an element by its `look` frame.
    @MainActor
    static func spotlight(_ focus: CookieFocus, captures: [CompanionScreenCapture], elementFrame: (Int) -> CGRect?) -> CookieSpotlight? {
        switch focus.anchor {
        case .element(let id):
            guard let frame = elementFrame(id) else { return nil }
            let rect = appKit(frame, mainHeight: NSScreen.screens.first?.frame.height ?? 0)
            guard let display = NSScreen.screens.first(where: { $0.frame.intersects(rect) })?.frame else { return nil }
            return CookieSpotlight(rect: rect, displayFrame: display)
        case .pixels(let corners):
            guard corners.count == 2, let capture = capture(screen: focus.screenNumber, in: captures) else { return nil }
            let topLeft = global(corners[0], in: capture), bottomRight = global(corners[1], in: capture)
            let rect = CGRect(x: topLeft.x, y: bottomRight.y, width: bottomRight.x - topLeft.x, height: topLeft.y - bottomRight.y)
            guard rect.width > 4, rect.height > 4 else { return nil }
            return CookieSpotlight(rect: rect, displayFrame: capture.displayFrame)
        }
    }
}

/// A local outline keeps the user's screen fully readable. Focus never paints a
/// full-display scrim, including while waiting on a guided step.
struct CookieSpotlightLayer: View {
    let spotlight: CookieSpotlight?
    let screenFrame: CGRect
    let typing: Bool
    static let padding: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var target: CGRect? {
        guard !typing, let spotlight, spotlight.displayFrame == screenFrame else { return nil }
        let rect = spotlight.rect.insetBy(dx: -Self.padding, dy: -Self.padding).intersection(screenFrame)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
        return CGRect(x: rect.minX - screenFrame.minX, y: screenFrame.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    var body: some View {
        ZStack {
            if let target {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.9), lineWidth: 2)
                    .frame(width: target.width, height: target.height)
                    .position(x: target.midX, y: target.midY)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: target)
        .allowsHitTesting(false)
    }
}
