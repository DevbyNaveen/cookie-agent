//
//  CookiePointerMotion.swift
//  Cookie
//
//  How Cookie's hand moves when it flies to point: a spring on the display's
//  own clock. A spring set by duration and bounce (WWDC23 "Animate with
//  springs") keeps position and velocity continuous, so when the target moves
//  mid-flight — the control scrolled — the hand bends toward the new place
//  instead of restarting; and it is driven by the display link of the screen
//  it is on, so it is as smooth at 120 Hz as at 60 and never slows when a
//  frame is dropped (its time is the frame's timestamp, not a frame count).
//
//  Also here: every Cookie window level, in one ordered list.
//

import AppKit
import QuartzCore

/// A critically damped-ish spring in two dimensions. `duration` is the perceptual duration and
/// `bounce` 0 (no overshoot) to 0.15 (a brisk tail) as Apple's guidance has it; stiffness and
/// damping follow the same mapping SwiftUI's `.spring(duration:bounce:)` documents.
struct CookieSpring2D {
    var position: CGPoint
    var velocity = CGVector.zero
    var target: CGPoint
    let stiffness: Double
    let damping: Double

    init(position: CGPoint, target: CGPoint, duration: Double = 0.5, bounce: Double = 0.1) {
        self.position = position
        self.target = target
        let bounce = min(0.15, max(0, bounce))
        stiffness = pow(2 * .pi / duration, 2)
        damping = 4 * .pi * (1 - bounce) / duration
    }

    /// Solve the damped spring at elapsed time, so dropped frames do not slow the flight
    /// and 60 Hz and 120 Hz take the same path. Retargeting preserves position and velocity.
    mutating func step(seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        let decay = damping / 2
        let frequencySquared = stiffness - decay * decay
        let envelope = exp(-decay * seconds)
        func advance(_ position: CGFloat, _ velocity: CGFloat, toward target: CGFloat) -> (CGFloat, CGFloat) {
            let displacement = position - target
            if frequencySquared > 0.000001 {
                let frequency = sqrt(frequencySquared)
                let cosine = cos(frequency * seconds)
                let sine = sin(frequency * seconds)
                return (target + envelope * (displacement * cosine + (velocity + decay * displacement) / frequency * sine),
                        envelope * (velocity * cosine - (decay * velocity + stiffness * displacement) / frequency * sine))
            }
            let slope = velocity + decay * displacement
            return (target + envelope * (displacement + slope * seconds),
                    envelope * (velocity - decay * slope * seconds))
        }
        let horizontal = advance(position.x, velocity.dx, toward: target.x)
        let vertical = advance(position.y, velocity.dy, toward: target.y)
        position = CGPoint(x: horizontal.0, y: vertical.0)
        velocity = CGVector(dx: horizontal.1, dy: vertical.1)
    }

    /// Close enough, and slow enough, to stop.
    var isSettled: Bool {
        hypot(position.x - target.x, position.y - target.y) < 0.5 && hypot(velocity.dx, velocity.dy) < 8
    }
}

/// One hand's flight on one overlay: a spring driven by its screen's display link. `fly` starts it
/// or, mid-flight, only moves the target (the velocity carries on). Each frame reports where the
/// hand is and which way its tip faces (along its travel, back to resting once slow).
@MainActor
final class CookiePointerFlight: NSObject {
    private var spring: CookieSpring2D?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var arrived: (() -> Void)?
    var onFrame: ((_ position: CGPoint, _ degrees: Double) -> Void)?

    var isFlying: Bool { spring != nil }

    func fly(from start: CGPoint, to target: CGPoint, on screen: NSScreen?, arrived: @escaping () -> Void) {
        self.arrived = arrived
        if spring != nil {
            spring?.target = target
            return
        }
        spring = CookieSpring2D(position: start, target: target, duration: 0.5, bounce: 0.1)
        lastTimestamp = nil
        guard let screen = screen ?? NSScreen.main else { return land() }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        let top = Float(max(60, screen.maximumFramesPerSecond))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: top, preferred: top)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Moves the target of a flight in progress; nothing when none is.
    func retarget(_ target: CGPoint) {
        spring?.target = target
    }

    func cancel() {
        link?.invalidate()
        link = nil
        spring = nil
        arrived = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard var spring else { return cancel() }
        let now = link.targetTimestamp
        spring.step(seconds: lastTimestamp.map { now - $0 } ?? (1.0 / 120))
        lastTimestamp = now
        self.spring = spring
        let speed = hypot(spring.velocity.dx, spring.velocity.dy)
        // Tip along the travel while it moves fast, back to the resting tilt as it settles.
        let degrees = speed > 120 ? atan2(spring.velocity.dy, spring.velocity.dx) * 180 / .pi + 90 : -35
        onFrame?(spring.position, degrees)
        if spring.isSettled { land() }
    }

    private func land() {
        let arrived = self.arrived
        if let target = spring?.target { onFrame?(target, -35) }
        cancel()
        arrived?()
    }
}

/// A callback on every frame of one screen's display link, at that screen's top rate (the system
/// may still slow it for Low Power Mode or heat): for work that follows the pointer.
@MainActor
final class CookieScreenTicker: NSObject {
    private var link: CADisplayLink?
    private var onTick: (() -> Void)?

    /// `rate`: frames a second wanted (nil = the screen's top rate).
    func start(on screen: NSScreen?, rate: Int? = nil, _ onTick: @escaping () -> Void) {
        stop()
        guard let screen = screen ?? NSScreen.main else { return }
        self.onTick = onTick
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        let top = Float(min(rate ?? .max, max(60, screen.maximumFramesPerSecond)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: top, preferred: top)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        onTick = nil
    }

    @objc private func tick(_ link: CADisplayLink) { onTick?() }
}

/// Every Cookie window's level, lowest first: the order is the design, so it lives in one place.
/// The pointer overlay sits above menus and pop-ups (it points at them); circle select above it.
enum CookieWindowLevel {
    static let card = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
    static let dock = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
    static let notch = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
    /// Panels opened from the notch (board, composer, work editor).
    static let notchPanel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
    static let pointerOverlay = NSWindow.Level.screenSaver
    static let circleSelect = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
}
