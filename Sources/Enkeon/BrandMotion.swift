import SwiftUI

private struct BrandPulseKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var brandPulse: Int {
        get { self[BrandPulseKey.self] }
        set { self[BrandPulseKey.self] = newValue }
    }
}

struct BrandOrigin: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// A short-lived rendering surface. No timers or drawing remain after the gesture settles.
struct BrandRipple: View {
    let started: Date
    let origin: CGPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
            Canvas { context, size in
                let t = min(1, max(0, timeline.date.timeIntervalSince(started) / 0.8))
                let envelope = sin(t * .pi)
                if reduceMotion {
                    let rect = CGRect(x: origin.x - 28, y: origin.y - 28, width: 56, height: 56)
                    context.fill(Path(ellipseIn: rect), with: .radialGradient(
                        Gradient(colors: [Theme.accent.opacity(0.16 * envelope), .clear]),
                        center: origin, startRadius: 0, endRadius: 28))
                } else {
                    let radius = hypot(size.width, size.height) * (1 - pow(1 - t, 2))
                    let rect = CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2)
                    context.addFilter(.blur(radius: 12))
                    context.stroke(Path(ellipseIn: rect), with: .color(Theme.accent.opacity(0.10 * envelope)), lineWidth: 28)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct BrandLift: ViewModifier {
    let delay: Double
    @Environment(\.brandPulse) private var pulse
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: pulse) { view, lift in
            view.offset(y: reduceMotion ? 0 : lift)
        } keyframes: { _ in
            LinearKeyframe(0, duration: delay)
            CubicKeyframe(-2, duration: 0.16)
            SpringKeyframe(0, duration: 0.4, spring: .smooth)
        }
    }
}

extension View {
    func brandLift(delay: Double = 0) -> some View { modifier(BrandLift(delay: delay)) }
}
