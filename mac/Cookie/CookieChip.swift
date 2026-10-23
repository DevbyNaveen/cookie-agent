//
//  CookieChip.swift
//  Cookie
//
//  Cookie's pointer, and how the voice state reads as Cookie's mood.
//

import SwiftUI

extension CompanionVoiceState {
    var cookieMood: CookieOrb.Mood {
        switch self {
        case .idle: return .idle
        case .listening: return .listening
        case .processing: return .thinking
        case .responding: return .speaking
        }
    }
}

/// Cookie's pointer: an equilateral triangle in the orb's amber, every side
/// equal and every corner rounded alike, made like a macOS cursor. Light
/// comes from the top left with a glassy highlight, and a tight shadow sets it
/// apart from white pages and dark ones alike. It turns itself, so its shadow
/// always falls straight down.
struct CookiePointer: View {
    var size: CGFloat = 13
    /// Which way the tip points: 0 is straight up, negative turns it left.
    var degrees: Double = 0

    var body: some View {
        let shape = PointerShape()
        ZStack {
            shape.fill(LinearGradient(colors: [Color(red: 1, green: 0.76, blue: 0.47), Color(red: 0.93, green: 0.56, blue: 0.24),
                                               Color(red: 0.78, green: 0.37, blue: 0.1)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            // Glass: a soft highlight toward the tip, fading before the middle.
            shape.fill(RadialGradient(colors: [.white.opacity(0.3), .white.opacity(0)],
                                      center: UnitPoint(x: 0.42, y: 0.18), startRadius: 0, endRadius: size * 0.55))
        }
        .frame(width: size, height: size * 0.866)
        .rotationEffect(.degrees(degrees))
        .shadow(color: .black.opacity(0.32), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.14), radius: 4, y: 3)
    }
}

/// An equilateral triangle pointing up, its three corners rounded alike.
/// Drawn in a frame whose height is √3/2 of its width.
struct PointerShape: Shape {
    func path(in r: CGRect) -> Path {
        let corners = [CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
            .map { CGPoint(x: r.minX + $0.x * r.width, y: r.minY + $0.y * r.height) }
        let radius = r.width * 0.14
        var p = Path()
        p.move(to: CGPoint(x: (corners[2].x + corners[0].x) / 2, y: (corners[2].y + corners[0].y) / 2))
        for index in corners.indices {
            p.addArc(tangent1End: corners[index], tangent2End: corners[(index + 1) % corners.count], radius: radius)
        }
        p.closeSubpath()
        return p
    }
}
