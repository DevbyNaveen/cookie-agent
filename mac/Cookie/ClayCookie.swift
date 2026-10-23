//
//  ClayCookie.swift
//  Cookie
//
//  Cookie, the character. A clay-style cookie with a bite out of it, drawn
//  in SwiftUI so it stays sharp at any size and can change its face:
//  smiles when idle, listens with an "o", glances up while thinking,
//  talks while speaking, frowns when something failed. It blinks.
//

import SwiftUI

struct ClayCookie: View {
    enum Flavor: CaseIterable {
        case chip, double, sugar, matcha

        /// Each chat gets its own cookie, the same one every time.
        static func forID(_ id: UUID) -> Flavor {
            let all = Flavor.allCases
            return all[Int(id.uuid.0) % all.count]
        }
    }

    enum Mood { case idle, listening, thinking, speaking, happy, sad, sleeping }

    var size: CGFloat = 32
    var flavor: Flavor = .chip
    var mood: Mood = .idle
    /// Below ~18pt a face is mush; the cookie shows chips only.
    var face: Bool? = nil
    var alive = true

    private var showsFace: Bool { face ?? (size >= 18) }

    var body: some View {
        TimelineView(.animation(paused: !alive)) { timeline in
            let t = alive ? timeline.date.timeIntervalSinceReferenceDate : 0
            cookie(t: t)
                .scaleEffect(1 + (alive ? 0.012 * sin(t * 2.2) : 0))
        }
        .frame(width: size, height: size)
    }

    private func cookie(t: Double) -> some View {
        let shape = CookieShape()
        let palette = flavor.palette
        return ZStack {
            // Dough: lit from the top left like a clay figure.
            shape.fill(RadialGradient(colors: [palette.light, palette.base, palette.edge],
                                      center: UnitPoint(x: 0.34, y: 0.28),
                                      startRadius: 0, endRadius: size * 0.78))
            // Inner shade along the lower right rim, so it reads as a soft solid.
            shape
                .stroke(palette.edge.opacity(0.75), lineWidth: size * 0.1)
                .blur(radius: size * 0.06)
                .offset(x: size * 0.025, y: size * 0.035)
                .mask(shape)
            // Clay sheen.
            Ellipse()
                .fill(Color.white.opacity(0.42))
                .frame(width: size * 0.44, height: size * 0.2)
                .rotationEffect(.degrees(-28))
                .offset(x: -size * 0.15, y: -size * 0.24)
                .blur(radius: size * 0.055)
                .mask(shape)

            if flavor == .sugar { icing }
            toppings
            if showsFace { faceView(t: t) }
        }
        .compositingGroup()
        .shadow(color: palette.edge.opacity(0.45), radius: size * 0.05, y: size * 0.045)
    }

    // MARK: Toppings

    private static let rimSpots: [(CGFloat, CGFloat, Double)] = [
        (0.22, 0.30, 20), (0.30, 0.80, -35), (0.70, 0.82, 50), (0.14, 0.57, 75), (0.47, 0.17, -15), (0.85, 0.58, 30),
    ]
    private static let centreSpots: [(CGFloat, CGFloat, Double)] = [(0.50, 0.53, 10), (0.62, 0.38, -40), (0.40, 0.62, 60)]

    private var spots: [(CGFloat, CGFloat, Double)] {
        showsFace ? Self.rimSpots : Self.rimSpots.prefix(4) + Self.centreSpots
    }

    @ViewBuilder
    private var toppings: some View {
        let palette = flavor.palette
        ForEach(Array(spots.enumerated()), id: \.offset) { index, spot in
            if flavor == .sugar {
                Capsule()
                    .fill(Self.sprinkles[index % Self.sprinkles.count])
                    .frame(width: size * 0.12, height: size * 0.045)
                    .rotationEffect(.degrees(spot.2))
                    .position(x: spot.0 * size, y: spot.1 * size)
            } else {
                ChipBlob(color: palette.chip, size: size * (index % 2 == 0 ? 0.13 : 0.105))
                    .rotationEffect(.degrees(spot.2))
                    .position(x: spot.0 * size, y: spot.1 * size)
            }
        }
    }

    private static let sprinkles: [Color] = [
        Color(red: 0.98, green: 0.45, blue: 0.55), Color(red: 0.36, green: 0.62, blue: 0.98),
        Color(red: 0.99, green: 0.82, blue: 0.30), Color(red: 0.45, green: 0.82, blue: 0.62),
    ]

    private var icing: some View {
        CookieShape(bite: true, inset: 0.16)
            .fill(RadialGradient(colors: [Color(red: 1, green: 0.84, blue: 0.9), Color(red: 0.97, green: 0.62, blue: 0.75)],
                                 center: UnitPoint(x: 0.36, y: 0.3), startRadius: 0, endRadius: size * 0.6))
            .overlay(
                Ellipse().fill(Color.white.opacity(0.5))
                    .frame(width: size * 0.3, height: size * 0.12)
                    .rotationEffect(.degrees(-28))
                    .offset(x: -size * 0.13, y: -size * 0.18)
                    .blur(radius: size * 0.04)
            )
    }

    // MARK: Face

    private func faceView(t: Double) -> some View {
        let ink = Color(red: 0.17, green: 0.09, blue: 0.05)
        let blinking = mood == .sleeping || (alive && mood != .happy && fmod(t, 4.3) < 0.13)
        let look: CGSize = mood == .thinking ? CGSize(width: size * 0.025, height: -size * 0.035) : .zero
        let eyeScale: CGFloat = mood == .listening ? 1.15 : 1
        return ZStack {
            // Cheeks.
            ForEach([0.29, 0.71], id: \.self) { x in
                Ellipse()
                    .fill(Color(red: 1, green: 0.5, blue: 0.55).opacity(0.38))
                    .frame(width: size * 0.13, height: size * 0.075)
                    .blur(radius: size * 0.02)
                    .position(x: x * size, y: size * 0.63)
            }
            // Eyes.
            ForEach([0.385, 0.615], id: \.self) { x in
                Group {
                    if mood == .happy {
                        HappyEye().stroke(ink, style: StrokeStyle(lineWidth: size * 0.035, lineCap: .round))
                            .frame(width: size * 0.1, height: size * 0.06)
                    } else {
                        Capsule()
                            .fill(ink)
                            .frame(width: size * 0.085 * eyeScale, height: size * 0.13 * eyeScale)
                            .overlay(alignment: .topLeading) {
                                Circle().fill(Color.white.opacity(0.9))
                                    .frame(width: size * 0.032, height: size * 0.032)
                                    .offset(x: size * 0.012, y: size * 0.016)
                            }
                            .scaleEffect(x: 1, y: blinking ? 0.12 : 1)
                    }
                }
                .position(x: x * size + look.width, y: size * 0.49 + look.height)
            }
            mouth(ink: ink, t: t)
                .position(x: size * 0.5 + (mood == .thinking ? size * 0.04 : 0), y: size * 0.65)
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.2), value: mood)
    }

    @ViewBuilder
    private func mouth(ink: Color, t: Double) -> some View {
        let line = StrokeStyle(lineWidth: size * 0.035, lineCap: .round)
        switch mood {
        case .idle, .happy:
            Smile(curve: 1).stroke(ink, style: line).frame(width: size * 0.15, height: size * 0.06)
        case .sleeping:
            Smile(curve: 0.6).stroke(ink, style: line).frame(width: size * 0.1, height: size * 0.04)
        case .sad:
            Smile(curve: -1).stroke(ink, style: line).frame(width: size * 0.13, height: size * 0.05)
        case .listening:
            Ellipse().fill(ink).frame(width: size * 0.065, height: size * 0.075)
        case .thinking:
            Capsule().fill(ink).frame(width: size * 0.08, height: size * 0.032)
        case .speaking:
            let open = 0.035 + 0.05 * abs(sin(t * 9)) * (0.6 + 0.4 * abs(sin(t * 3.7)))
            Ellipse().fill(ink)
                .frame(width: size * 0.1, height: size * open)
                .overlay(alignment: .bottom) {
                    Ellipse().fill(Color(red: 0.95, green: 0.42, blue: 0.45))
                        .frame(width: size * 0.06, height: size * open * 0.45)
                }
        }
    }
}

extension ClayCookie.Flavor {
    struct Palette { let light, base, edge, chip: Color }

    var palette: Palette {
        switch self {
        case .chip:
            return Palette(light: Color(red: 0.98, green: 0.82, blue: 0.56), base: Color(red: 0.88, green: 0.63, blue: 0.34),
                           edge: Color(red: 0.62, green: 0.38, blue: 0.16), chip: Color(red: 0.29, green: 0.16, blue: 0.09))
        case .double:
            return Palette(light: Color(red: 0.62, green: 0.42, blue: 0.30), base: Color(red: 0.42, green: 0.25, blue: 0.15),
                           edge: Color(red: 0.24, green: 0.13, blue: 0.07), chip: Color(red: 0.96, green: 0.91, blue: 0.83))
        case .sugar:
            return Palette(light: Color(red: 0.99, green: 0.88, blue: 0.68), base: Color(red: 0.93, green: 0.77, blue: 0.53),
                           edge: Color(red: 0.74, green: 0.55, blue: 0.31), chip: .clear)
        case .matcha:
            return Palette(light: Color(red: 0.84, green: 0.92, blue: 0.64), base: Color(red: 0.62, green: 0.77, blue: 0.42),
                           edge: Color(red: 0.38, green: 0.52, blue: 0.24), chip: Color(red: 1, green: 0.97, blue: 0.9))
        }
    }
}

/// A slightly lumpy disc with a bite out of the top right.
struct CookieShape: Shape {
    var bite = true
    /// Shrinks the disc (for icing on top).
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2 * (0.96 - inset)
        var disc = Path()
        let steps = 72
        for i in 0...steps {
            let a = Double(i) / Double(steps) * 2 * .pi
            let wobble = 1 + 0.028 * sin(a * 5 + 0.7) + 0.016 * sin(a * 9 + 2.1)
            let point = CGPoint(x: c.x + cos(a) * r * wobble, y: c.y + sin(a) * r * wobble)
            i == 0 ? disc.move(to: point) : disc.addLine(to: point)
        }
        disc.closeSubpath()
        guard bite else { return disc }
        let full = min(rect.width, rect.height) / 2
        var bites = Path()
        for (dx, dy, br) in [(0.80, -0.60, 0.25), (0.97, -0.28, 0.19), (0.55, -0.88, 0.19)] as [(CGFloat, CGFloat, CGFloat)] {
            bites.addEllipse(in: CGRect(x: c.x + dx * full - br * full, y: c.y + dy * full - br * full,
                                        width: 2 * br * full, height: 2 * br * full))
        }
        return disc.subtracting(bites)
    }
}

private struct ChipBlob: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.42, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size * 0.82)
            .overlay(alignment: .topLeading) {
                Circle().fill(Color.white.opacity(0.35))
                    .frame(width: size * 0.3, height: size * 0.3)
                    .offset(x: size * 0.15, y: size * 0.1)
            }
    }
}

private struct Smile: Shape {
    var curve: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let top = curve > 0 ? rect.minY : rect.maxY
        let bottom = curve > 0 ? rect.maxY : rect.minY
        p.move(to: CGPoint(x: rect.minX, y: top))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: top), control: CGPoint(x: rect.midX, y: bottom + (bottom - top) * 0.6))
        return p
    }
}

/// "^" — eyes closed with joy.
private struct HappyEye: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.6))
        return p
    }
}

extension CompanionVoiceState {
    var cookieMood: ClayCookie.Mood {
        switch self {
        case .idle: return .idle
        case .listening: return .listening
        case .processing: return .thinking
        case .responding: return .speaking
        }
    }
}

/// Cookie's pointer: one chocolate chip. Small, glossy, with a cream rim so
/// it reads on dark and light screens. Its tip points the way a cursor does.
struct ChocoChip: View {
    var size: CGFloat = 13

    var body: some View {
        let shape = ChipShape()
        ZStack {
            shape.fill(LinearGradient(colors: [Color(red: 0.55, green: 0.34, blue: 0.21), Color(red: 0.24, green: 0.12, blue: 0.06)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.stroke(Color(red: 1, green: 0.95, blue: 0.86).opacity(0.95), lineWidth: max(1, size * 0.085))
            Ellipse()
                .fill(Color.white.opacity(0.7))
                .frame(width: size * 0.2, height: size * 0.34)
                .rotationEffect(.degrees(-20))
                .offset(x: -size * 0.12, y: size * 0.08)
                .blur(radius: size * 0.03)
        }
        .frame(width: size * 0.84, height: size)
        .shadow(color: Color(red: 1, green: 0.72, blue: 0.45).opacity(0.55), radius: size * 0.3)
        .shadow(color: .black.opacity(0.35), radius: size * 0.08, y: size * 0.06)
    }
}

/// A chocolate chip seen from the side: round base, soft peak.
struct ChipShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, x = r.minX, y = r.minY
        var p = Path()
        p.move(to: CGPoint(x: x + 0.5 * w, y: y))
        p.addCurve(to: CGPoint(x: x + w, y: y + 0.72 * h),
                   control1: CGPoint(x: x + 0.64 * w, y: y + 0.3 * h), control2: CGPoint(x: x + w, y: y + 0.44 * h))
        p.addCurve(to: CGPoint(x: x, y: y + 0.72 * h),
                   control1: CGPoint(x: x + w, y: y + 1.07 * h), control2: CGPoint(x: x, y: y + 1.07 * h))
        p.addCurve(to: CGPoint(x: x + 0.5 * w, y: y),
                   control1: CGPoint(x: x, y: y + 0.44 * h), control2: CGPoint(x: x + 0.36 * w, y: y + 0.3 * h))
        p.closeSubpath()
        return p
    }
}
