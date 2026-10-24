import SwiftUI

/// Small, native vector creatures. A chat's UUID keeps its appearance stable across launches.
struct ChatCompanionAvatar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var size: CGFloat = 32
    var threadID: UUID?
    var mood: CookieOrb.Mood = .idle
    var animatesIdle = false
    var isEngaged = false
    /// Where the eyes look, -1 (left) to 1 (right); nil lets the idle glance decide.
    var gaze: CGFloat? = nil
    @State private var isVisible = false

    private var identity: CompanionIdentity { CompanionIdentity(threadID: threadID) }
    private var isAnimated: Bool {
        isVisible && !reduceMotion && (animatesIdle || mood == .thinking || mood == .listening || mood == .speaking || mood == .sleeping)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !isAnimated)) { timeline in
            let time = isAnimated ? timeline.date.timeIntervalSinceReferenceDate : 0
            let pose = mood == .sleeping
                ? CookieCompanionPose.asleep(at: isAnimated ? time : 0)
                : CookieCompanionPose.idle(at: time, engaged: isEngaged, enabled: isAnimated && animatesIdle && mood == .idle)
            character(time: time, pose: pose)
                .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: .bottom)
                .rotationEffect(.degrees(pose.tilt), anchor: .bottom)
                .offset(y: pose.lift * size)
                .offset(y: mood == .thinking && isAnimated ? sin(time * 2.4) * size * 0.018 : 0)
        }
        .frame(width: size, height: size)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: isEngaged)
        .accessibilityHidden(true)
    }

    private func character(time: Double, pose: CookieCompanionPose) -> some View {
        let silhouette = CompanionSilhouette(kind: identity.silhouette)
        let tint = identity.color
        return ZStack {
            silhouette
                .fill(LinearGradient(colors: [tint.light, tint.base, tint.shade],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    silhouette.strokeBorderHighlight(size: size)
                }

            Ellipse()
                .fill(Color.white.opacity(0.3))
                .frame(width: size * 0.33, height: size * 0.13)
                .rotationEffect(.degrees(-25))
                .offset(x: -size * 0.15, y: -size * 0.23)
                .blur(radius: size * 0.04)
                .frame(width: size, height: size)
                .mask(silhouette)

            face(time: time, pose: pose)
        }
        .frame(width: size, height: size)
        .compositingGroup()
    }

    private func face(time: Double, pose: CookieCompanionPose) -> some View {
        let eyeSpacing = identity.eyeSpacing
        let eyeHeight: CGFloat = mood == .listening ? 0.15 : 0.12
        // Listening: eyes on the person (centred). Pointing: eyes toward the target. Otherwise the idle glance.
        let gaze: CGFloat = mood == .listening ? 0 : mood == .thinking ? 0.018 : (self.gaze.map { max(-1, min(1, $0)) * 0.05 } ?? pose.gaze)
        let ink = Color(red: 0.16, green: 0.18, blue: 0.25)

        return ZStack {
            ForEach([-1.0, 1.0], id: \.self) { side in
                Ellipse()
                    .fill(Color(red: 0.98, green: 0.43, blue: 0.53).opacity(0.38))
                    .frame(width: size * 0.13, height: size * 0.065)
                    .position(x: size * (0.5 + side * 0.24), y: size * 0.65)

                Group {
                    if mood == .happy {
                        CompanionSmile()
                            .stroke(ink, style: StrokeStyle(lineWidth: size * 0.036, lineCap: .round))
                            .rotationEffect(.degrees(180))
                            .frame(width: size * 0.105, height: size * 0.04)
                    } else {
                        Capsule()
                            .fill(ink)
                            .frame(width: size * 0.075, height: size * eyeHeight)
                            .overlay(alignment: .topLeading) {
                                if size >= 28 {
                                    Circle().fill(Color.white.opacity(0.9))
                                        .frame(width: size * 0.025, height: size * 0.025)
                                        .offset(x: size * 0.015, y: size * 0.02)
                                }
                            }
                            .scaleEffect(x: 1, y: pose.eyeOpenness)
                    }
                }
                .position(x: size * (0.5 + side * eyeSpacing + gaze),
                          y: size * (mood == .thinking ? 0.525 : 0.55))
            }

            mouth(ink: ink, time: time)
                .position(x: size * (0.5 + gaze), y: size * 0.68)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: mood)
    }

    @ViewBuilder
    private func mouth(ink: Color, time: Double) -> some View {
        switch mood {
        case .listening, .speaking:
            Ellipse().fill(ink)
                .frame(width: size * 0.075,
                       height: size * (mood == .speaking ? 0.06 + abs(sin(time * 8)) * 0.045 : 0.09))
        case .thinking:
            Capsule().fill(ink).frame(width: size * 0.07, height: size * 0.035)
        case .sleeping:
            CompanionSmile()
                .stroke(ink, style: StrokeStyle(lineWidth: size * 0.03, lineCap: .round))
                .frame(width: size * 0.09, height: size * 0.03)
        case .idle, .happy, .sad:
            CompanionSmile()
                .stroke(ink, style: StrokeStyle(lineWidth: size * 0.032, lineCap: .round))
                .frame(width: size * 0.13, height: size * 0.045)
                .rotationEffect(.degrees(mood == .sad ? 180 : 0))
        }
    }
}

private struct CompanionIdentity {
    let seed: UInt64

    init(threadID: UUID?) {
        // Swift's hashValue changes each process; this hash intentionally does not.
        seed = (threadID?.uuidString ?? "Cookie's little companion").utf8.reduce(14_695_981_039_346_656_037) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
    }

    var silhouette: Int { Int(seed % 6) }
    var eyeSpacing: CGFloat { 0.135 + CGFloat((seed >> 16) % 3) * 0.012 }

    struct Palette { let light, base, shade: Color }

    var color: Palette {
        let colors: [(Double, Double, Double)] = [
            (0.67, 0.64, 0.96), // lavender
            (0.46, 0.79, 0.86), // sea glass
            (0.98, 0.72, 0.57), // apricot
            (0.69, 0.83, 0.56), // pistachio
            (0.95, 0.67, 0.78), // rose
            (0.96, 0.83, 0.51), // butter
            (0.56, 0.72, 0.96), // sky
            (0.49, 0.83, 0.72), // mint
        ]
        let (red, green, blue) = colors[Int((seed >> 8) % UInt64(colors.count))]
        return Palette(
            light: Color(red: red + (1 - red) * 0.55, green: green + (1 - green) * 0.55, blue: blue + (1 - blue) * 0.55),
            base: Color(red: red, green: green, blue: blue),
            shade: Color(red: red * 0.78, green: green * 0.78, blue: blue * 0.82)
        )
    }
}

private struct CompanionSilhouette: Shape {
    let kind: Int

    func path(in rect: CGRect) -> Path {
        var outline = Path()
        switch kind {
        case 0: // Two floppy ears, one softly rounded body.
            outline.move(to: CGPoint(x: 0.22, y: 0.40))
            outline.addCurve(to: CGPoint(x: 0.40, y: 0.32), control1: CGPoint(x: 0.02, y: -0.08), control2: CGPoint(x: 0.43, y: -0.03))
            outline.addQuadCurve(to: CGPoint(x: 0.56, y: 0.32), control: CGPoint(x: 0.49, y: 0.29))
            outline.addCurve(to: CGPoint(x: 0.77, y: 0.40), control1: CGPoint(x: 0.62, y: -0.12), control2: CGPoint(x: 0.98, y: 0.04))
            outline.addCurve(to: CGPoint(x: 0.75, y: 0.89), control1: CGPoint(x: 1.00, y: 0.51), control2: CGPoint(x: 0.98, y: 0.85))
            outline.addCurve(to: CGPoint(x: 0.22, y: 0.89), control1: CGPoint(x: 0.59, y: 0.96), control2: CGPoint(x: 0.37, y: 0.96))
            outline.addCurve(to: CGPoint(x: 0.22, y: 0.40), control1: CGPoint(x: -0.01, y: 0.83), control2: CGPoint(x: 0.02, y: 0.51))
        case 1: // A little cloud with an asymmetric crown.
            outline.move(to: CGPoint(x: 0.17, y: 0.83))
            outline.addCurve(to: CGPoint(x: 0.20, y: 0.37), control1: CGPoint(x: -0.06, y: 0.74), control2: CGPoint(x: 0.01, y: 0.39))
            outline.addCurve(to: CGPoint(x: 0.61, y: 0.27), control1: CGPoint(x: 0.16, y: 0.02), control2: CGPoint(x: 0.53, y: -0.01))
            outline.addCurve(to: CGPoint(x: 0.85, y: 0.41), control1: CGPoint(x: 0.80, y: 0.12), control2: CGPoint(x: 0.93, y: 0.26))
            outline.addCurve(to: CGPoint(x: 0.82, y: 0.85), control1: CGPoint(x: 1.08, y: 0.53), control2: CGPoint(x: 0.98, y: 0.83))
            outline.addCurve(to: CGPoint(x: 0.17, y: 0.83), control1: CGPoint(x: 0.64, y: 0.94), control2: CGPoint(x: 0.32, y: 0.93))
        case 2: // A plump, rounded five-point star.
            let vertices = (0..<10).map { vertexIndex -> CGPoint in
                let angle = Double(vertexIndex) * .pi / 5 - .pi / 2
                let radius = vertexIndex.isMultiple(of: 2) ? 0.51 : 0.34
                return CGPoint(x: 0.5 + cos(angle) * radius, y: 0.51 + sin(angle) * radius)
            }
            outline = roundedOutline(vertices)
        case 3: // A sleepy seed with a single leaf.
            outline.move(to: CGPoint(x: 0.48, y: 0.29))
            outline.addCurve(to: CGPoint(x: 0.76, y: 0.06), control1: CGPoint(x: 0.44, y: 0.04), control2: CGPoint(x: 0.67, y: 0.03))
            outline.addQuadCurve(to: CGPoint(x: 0.58, y: 0.30), control: CGPoint(x: 0.80, y: 0.27))
            outline.addCurve(to: CGPoint(x: 0.87, y: 0.78), control1: CGPoint(x: 0.88, y: 0.29), control2: CGPoint(x: 1.00, y: 0.61))
            outline.addCurve(to: CGPoint(x: 0.15, y: 0.78), control1: CGPoint(x: 0.78, y: 0.99), control2: CGPoint(x: 0.29, y: 0.98))
            outline.addCurve(to: CGPoint(x: 0.48, y: 0.29), control1: CGPoint(x: -0.02, y: 0.57), control2: CGPoint(x: 0.18, y: 0.28))
        case 4: // A tiny jelly with three rounded feet.
            outline.move(to: CGPoint(x: 0.13, y: 0.73))
            outline.addCurve(to: CGPoint(x: 0.50, y: 0.12), control1: CGPoint(x: 0.08, y: 0.34), control2: CGPoint(x: 0.25, y: 0.12))
            outline.addCurve(to: CGPoint(x: 0.89, y: 0.75), control1: CGPoint(x: 0.78, y: 0.12), control2: CGPoint(x: 0.91, y: 0.34))
            outline.addCurve(to: CGPoint(x: 0.65, y: 0.82), control1: CGPoint(x: 0.92, y: 1.03), control2: CGPoint(x: 0.72, y: 1.02))
            outline.addCurve(to: CGPoint(x: 0.38, y: 0.82), control1: CGPoint(x: 0.61, y: 1.01), control2: CGPoint(x: 0.42, y: 1.01))
            outline.addCurve(to: CGPoint(x: 0.13, y: 0.73), control1: CGPoint(x: 0.30, y: 1.01), control2: CGPoint(x: 0.08, y: 1.01))
        default: // A soft pebble with one inquisitive tuft.
            outline.move(to: CGPoint(x: 0.17, y: 0.40))
            outline.addCurve(to: CGPoint(x: 0.48, y: 0.21), control1: CGPoint(x: 0.22, y: 0.18), control2: CGPoint(x: 0.35, y: 0.22))
            outline.addQuadCurve(to: CGPoint(x: 0.64, y: 0.09), control: CGPoint(x: 0.45, y: 0.03))
            outline.addQuadCurve(to: CGPoint(x: 0.67, y: 0.24), control: CGPoint(x: 0.73, y: 0.10))
            outline.addCurve(to: CGPoint(x: 0.86, y: 0.80), control1: CGPoint(x: 0.99, y: 0.31), control2: CGPoint(x: 0.97, y: 0.62))
            outline.addCurve(to: CGPoint(x: 0.19, y: 0.84), control1: CGPoint(x: 0.74, y: 0.99), control2: CGPoint(x: 0.31, y: 0.98))
            outline.addQuadCurve(to: CGPoint(x: 0.17, y: 0.40), control: CGPoint(x: 0.02, y: 0.66))
        }
        outline.closeSubpath()
        return outline.applying(CGAffineTransform(scaleX: rect.width, y: rect.height)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }

    private func roundedOutline(_ vertices: [CGPoint]) -> Path {
        var outline = Path()
        let firstMidpoint = CGPoint(x: (vertices[0].x + vertices.last!.x) / 2,
                                    y: (vertices[0].y + vertices.last!.y) / 2)
        outline.move(to: firstMidpoint)
        for vertexIndex in vertices.indices {
            let vertex = vertices[vertexIndex]
            let nextVertex = vertices[(vertexIndex + 1) % vertices.count]
            outline.addQuadCurve(to: CGPoint(x: (vertex.x + nextVertex.x) / 2, y: (vertex.y + nextVertex.y) / 2),
                                 control: vertex)
        }
        return outline
    }

    func strokeBorderHighlight(size: CGFloat) -> some View {
        stroke(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.04)],
                              startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: max(0.5, size * 0.015))
    }
}

private struct CompanionSmile: Shape {
    func path(in rect: CGRect) -> Path {
        var smile = Path()
        smile.move(to: CGPoint(x: rect.minX, y: rect.minY))
        smile.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY * 1.6))
        return smile
    }
}
