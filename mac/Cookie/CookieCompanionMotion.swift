import Foundation

/// Small, bounded movements for the one companion in the open peek.
struct CookieCompanionPose: Equatable {
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var lift: CGFloat = 0
    var tilt: Double = 0
    var eyeOpenness: CGFloat = 1
    var gaze: CGFloat = 0

    /// Asleep: eyes shut, a slow deep breath, a little lean. Nothing else moves.
    static func asleep(at time: TimeInterval) -> Self {
        let breath = sin(time * .pi * 2 / 11)
        return Self(scaleX: 1 - breath * 0.004, scaleY: 1 + breath * 0.012, lift: breath * 0.004, tilt: 3,
                    eyeOpenness: 0.12, gaze: 0)
    }

    static func idle(at time: TimeInterval, engaged: Bool, enabled: Bool) -> Self {
        guard enabled else { return Self() }
        let breath = sin(time * .pi * 2 / 7.6)
        let glance = sin(time * .pi * 2 / 13)
        let blinkPhase = time.truncatingRemainder(dividingBy: 6.8)
        let blink = blinkPhase < 0.24 ? sin(blinkPhase / 0.24 * .pi) : 0
        return Self(scaleX: 1 - breath * 0.006, scaleY: 1 + breath * 0.009,
                    lift: -breath * 0.006, tilt: engaged ? -4 : glance * 0.8,
                    eyeOpenness: max(0.12, 1 - blink), gaze: engaged ? 0.018 : glance * 0.008)
    }
}
