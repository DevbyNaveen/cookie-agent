//
//  CookieSim.swift
//  Cookie
//
//  The simulation library behind `sim` cards: nine vetted models the model
//  can only pick and parameterise — an orbit, a spring, a pendulum, a
//  projectile, waves (one source, or two interfering), a queue, flow through a
//  narrowing pipe, radioactive decay and compound growth. Each keeps its
//  parameters inside a range it is stable over, steps with a fixed step (RK4
//  for the forces, velocity Verlet for the orbit so it keeps its energy,
//  events for the queue, exact closed forms where the physics has one), and
//  says its current values — period, range, wait — so the voice and the card
//  can name them. `CookieSimRunner` drives one on the display link while it is
//  on screen and open, and holds a representative frame (with its trail) for
//  Reduce Motion and off-screen renders.
//

import AppKit
import CoreGraphics
import Foundation

protocol CookieSimulation {
    /// Model time since the start (seconds, years or minutes: the model's own unit).
    var time: Double { get }
    /// Nothing more will change (landed, decayed, at the horizon): the display link can stop.
    var settled: Bool { get }
    /// Model time per real second when it plays.
    var playback: Double { get }
    mutating func advance(by dt: Double)
    /// Moves to a moment that shows what the model does, with its trail: the frame for Reduce
    /// Motion and for off-screen renders.
    mutating func representative()
    func readouts() -> [CookieSim.Readout]
    func draw(in size: CGSize) -> CookieSim.Drawing
}

enum CookieSim {
    struct Param: Equatable {
        let id: String
        let label: String
        let unit: String
        let range: ClosedRange<Double>
        let value: Double
        var aliases: [String] = []
        /// Whole numbers only (atoms, sources, times a year).
        var whole = false

        func clamp(_ value: Double) -> Double {
            let inside = min(range.upperBound, max(range.lowerBound, value))
            return whole ? inside.rounded() : inside
        }
    }

    struct Model {
        let id: String
        /// What it is, for summaries: "a pendulum".
        let noun: String
        let params: [Param]
        let make: ([String: Double], [String: ClosedRange<Double>]) -> any CookieSimulation

        func param(_ name: String) -> Param? {
            let key = name.lowercased()
            return params.first { $0.id == key || $0.aliases.contains(key) }
        }
        var defaults: [String: Double] { Dictionary(uniqueKeysWithValues: params.map { ($0.id, $0.value) }) }
    }

    /// One current value: what the card shows under the picture and the voice may quote.
    struct Readout: Equatable {
        let id: String
        let label: String
        let value: Double?
        let text: String
        var line: String { "\(label) \(text)" }
    }

    /// One frame in canvas points (y down).
    struct Drawing {
        enum Tone { case ink, text, quiet, second }
        struct Stroke {
            var points: [CGPoint]
            var tone: Tone = .text
            var pen: CGFloat = 1.6
            var smooth = false
            /// A thin even line without the hand's wobble, for fields of many lines.
            var plain = false
            var key: String
        }
        struct Dot {
            var center: CGPoint
            var radius: CGFloat
            var tone: Tone = .ink
        }
        struct Label {
            var text: String
            var at: CGPoint
            var tone: Tone = .quiet
            /// Which point of the text sits at `at`, as fractions of its width and height.
            var anchor = CGPoint(x: 0.5, y: 0.5)
        }
        var strokes: [Stroke] = []
        var dots: [Dot] = []
        var labels: [Label] = []

        var isFinite: Bool {
            strokes.allSatisfy { $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite } }
                && dots.allSatisfy { $0.center.x.isFinite && $0.center.y.isFinite && $0.radius.isFinite }
                && labels.allSatisfy { $0.at.x.isFinite && $0.at.y.isFinite }
        }
    }

    static let canvas = CGSize(width: 324, height: 176)

    static func readout(_ id: String, _ label: String, _ value: Double, _ unit: String) -> Readout {
        Readout(id: id, label: label, value: value, text: CookieCard.format(value) + (unit.isEmpty ? "" : " " + unit))
    }

    static let models: [String: Model] = Dictionary(uniqueKeysWithValues: [
        Model(id: "orbit", noun: "an orbit", params: [
            Param(id: "gravity", label: "sun's pull", unit: "AU³/yr²", range: 10...80, value: 39.48, aliases: ["gm", "g", "pull", "mass"]),
            Param(id: "speed", label: "start speed", unit: "AU/yr", range: 1...12, value: 6.28, aliases: ["v", "velocity", "initial_speed", "initialspeed"]),
        ], make: { Orbit($0, $1) }),
        Model(id: "spring", noun: "a mass on a spring", params: [
            Param(id: "mass", label: "mass", unit: "kg", range: 0.1...5, value: 1, aliases: ["m"]),
            Param(id: "stiffness", label: "stiffness", unit: "N/m", range: 1...100, value: 20, aliases: ["k", "spring_constant"]),
            Param(id: "damping", label: "damping", unit: "N·s/m", range: 0...5, value: 0.4, aliases: ["c", "b", "friction"]),
            Param(id: "pull", label: "pulled out", unit: "m", range: 0.05...0.3, value: 0.2, aliases: ["amplitude", "x0", "displacement"]),
        ], make: { Spring($0, $1) }),
        Model(id: "pendulum", noun: "a pendulum", params: [
            Param(id: "length", label: "length", unit: "m", range: 0.2...3, value: 1, aliases: ["l"]),
            Param(id: "gravity", label: "gravity", unit: "m/s²", range: 1...25, value: 9.81, aliases: ["g"]),
            Param(id: "angle", label: "start angle", unit: "°", range: 1...170, value: 20, aliases: ["theta", "theta0", "amplitude"]),
        ], make: { Pendulum($0, $1) }),
        Model(id: "projectile", noun: "a launched ball", params: [
            Param(id: "speed", label: "launch speed", unit: "m/s", range: 1...60, value: 20, aliases: ["v", "v0", "velocity"]),
            Param(id: "angle", label: "angle", unit: "°", range: 5...85, value: 45, aliases: ["theta"]),
            Param(id: "gravity", label: "gravity", unit: "m/s²", range: 1...25, value: 9.81, aliases: ["g"]),
            Param(id: "drag", label: "drag", unit: "1/m", range: 0...0.1, value: 0, aliases: ["k", "air", "air_resistance"]),
        ], make: { Projectile($0, $1) }),
        Model(id: "wave", noun: "waves", params: [
            Param(id: "frequency", label: "frequency", unit: "Hz", range: 0.2...3, value: 1, aliases: ["f"]),
            Param(id: "amplitude", label: "amplitude", unit: "cm", range: 0.5...5, value: 3, aliases: ["a"]),
            Param(id: "speed", label: "wave speed", unit: "m/s", range: 0.5...5, value: 2, aliases: ["v"]),
            Param(id: "sources", label: "sources", unit: "", range: 1...2, value: 1, aliases: ["source"], whole: true),
            Param(id: "separation", label: "source gap", unit: "m", range: 0.5...4, value: 1.5, aliases: ["d", "gap", "distance"]),
        ], make: { Wave($0, $1) }),
        Model(id: "queue", noun: "a queue at one counter", params: [
            Param(id: "arrivals", label: "arrivals", unit: "/min", range: 0.2...10, value: 2, aliases: ["lambda", "arrival", "arrival_rate"]),
            Param(id: "service", label: "served", unit: "/min", range: 0.5...12, value: 3, aliases: ["mu", "service_rate", "served"]),
        ], make: { Queue($0, $1) }),
        Model(id: "flow", noun: "water through a narrowing pipe", params: [
            Param(id: "speed", label: "inlet speed", unit: "m/s", range: 0.1...5, value: 1, aliases: ["v", "v1", "velocity"]),
            Param(id: "wide", label: "wide part", unit: "cm", range: 2...20, value: 10, aliases: ["d1", "inlet", "diameter"]),
            Param(id: "narrow", label: "narrow part", unit: "cm", range: 1...20, value: 5, aliases: ["d2", "throat"]),
        ], make: { Flow($0, $1) }),
        Model(id: "decay", noun: "radioactive decay", params: [
            Param(id: "halflife", label: "half-life", unit: "s", range: 0.5...20, value: 3, aliases: ["half_life", "half-life", "t"]),
            Param(id: "atoms", label: "atoms", unit: "", range: 20...400, value: 100, aliases: ["n", "n0", "count"], whole: true),
        ], make: { Decay($0, $1) }),
        Model(id: "growth", noun: "compound growth", params: [
            Param(id: "rate", label: "rate", unit: "%/yr", range: 0.5...30, value: 7, aliases: ["r", "interest"]),
            Param(id: "compounding", label: "compounded", unit: "/yr", range: 0...365, value: 12, aliases: ["n", "times"], whole: true),
            Param(id: "start", label: "start", unit: "", range: 1...10000, value: 100, aliases: ["p", "principal"]),
            Param(id: "years", label: "years", unit: "yr", range: 1...50, value: 20, aliases: ["t", "time"]),
        ], make: { Growth($0, $1) }),
    ].map { ($0.id, $0) })

    /// Names a model reaches for that mean one of the models.
    static let aliases: [String: String] = [
        "gravity": "orbit", "planet": "orbit", "kepler": "orbit", "oscillator": "spring", "mass-spring": "spring", "harmonic": "spring",
        "swing": "pendulum", "ball": "projectile", "cannon": "projectile", "throw": "projectile", "launch": "projectile",
        "interference": "wave", "waves": "wave", "ripple": "wave", "line": "queue", "mm1": "queue", "m/m/1": "queue", "waiting": "queue",
        "pipe": "flow", "bernoulli": "flow", "continuity": "flow", "half-life": "decay", "radioactive": "decay", "radioactivity": "decay",
        "interest": "growth", "compound": "growth", "compounding": "growth", "exponential": "growth",
    ]

    // MARK: Shared

    /// A fixed step: whatever time a frame brings is spent in whole steps of `h`, the rest carried
    /// over. At most `cap` steps a call, so a long stall can't freeze the frame (the lost time is lost).
    struct Clock {
        let h: Double
        var pending = 0.0
        mutating func steps(for dt: Double, cap: Int = 40_000) -> Int {
            pending += max(0, dt)
            let count = min(cap, Int(pending / h))
            pending = count == cap ? 0 : pending - Double(count) * h
            return count
        }
    }

    static func rk4(_ y: SIMD4<Double>, _ h: Double, _ f: (SIMD4<Double>) -> SIMD4<Double>) -> SIMD4<Double> {
        let k1 = f(y), k2 = f(y + k1 * (h / 2)), k3 = f(y + k2 * (h / 2)), k4 = f(y + k3 * h)
        return y + (k1 + k2 * 2 + k3 * 2 + k4) * (h / 6)
    }

    /// SplitMix64: a small seeded generator, so a queue or a decay plays the same way each time.
    struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return (Double(z >> 11) + 0.5) / 9_007_199_254_740_992
        }
        /// A wait with this rate (an exponential draw).
        mutating func exponential(_ rate: Double) -> Double { -log(next()) / rate }
    }

    /// The arithmetic–geometric mean, for the pendulum's exact period.
    static func agm(_ a: Double, _ b: Double) -> Double {
        var a = a, b = b
        for _ in 0..<40 where abs(a - b) > 1e-15 * a { (a, b) = ((a + b) / 2, (a * b).squareRoot()) }
        return a
    }

    /// The largest value a parameter can reach: where it is, or the top of its slider.
    static func top(_ id: String, _ values: [String: Double], _ extent: [String: ClosedRange<Double>]) -> Double {
        max(values[id] ?? 0, extent[id]?.upperBound ?? -.infinity)
    }

    /// 0 up to a round number at or above `high` (1, 2 or 5 of a power of ten, about four steps).
    static func roundUp(_ high: Double) -> ClosedRange<Double> {
        let rough = max(1e-9, high) / 4
        let magnitude = pow(10, floor(log10(rough)))
        let residual = rough / magnitude
        let step = (residual > 5 ? 10 : residual > 2 ? 5 : residual > 1 ? 2 : 1) * magnitude
        return 0...(ceil(high / step) * step)
    }

    static func speedNote(_ playback: Double) -> String? {
        if playback > 1.05 { return "shown \(CookieCard.format(playback))× faster" }
        if playback < 0.95 { return "slowed to \(CookieCard.format(playback))×" }
        return nil
    }
}

// MARK: - Orbit

/// A planet round a sun (GM in AU³/yr², so the Earth's is 4π²), starting 1 AU out, moving
/// sideways. Velocity Verlet: symplectic, so a closed orbit stays closed.
struct Orbit: CookieSimulation {
    enum Fate { case flying, escaped, crashed }
    let gm: Double, speed: Double
    var p = SIMD2<Double>(1, 0)
    var v: SIMD2<Double>
    private(set) var time = 0.0
    var trail: [SIMD2<Double>] = []
    private var nextTrail = 0.0
    private(set) var fate = Fate.flying
    private var clock = CookieSim.Clock(h: 1e-4)
    let playback = 0.3
    /// Kepler's period from the energy; nil when it escapes.
    let period: Double?
    let reach: Double
    let trailEvery: Double
    static let sunRadius = 0.06

    init(_ values: [String: Double], _ extent: [String: ClosedRange<Double>]) {
        gm = values["gravity"] ?? 39.48
        speed = values["speed"] ?? 6.28
        v = SIMD2(0, speed)
        let energy = speed * speed / 2 - gm
        if energy < 0 {
            let a = -gm / (2 * energy)
            period = 2 * .pi * (a * a * a / gm).squareRoot()
            reach = min(4.5, max(1, 2 * a - 1)) * 1.08
        } else {
            period = nil
            reach = 4.5
        }
        trailEvery = min(0.05, max(0.002, (period ?? 2) / 300))
    }

    var settled: Bool { fate != .flying }

    func acceleration(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let r = (p * p).sum().squareRoot()
        return p * (-gm / (r * r * r))
    }

    mutating func advance(by dt: Double) {
        let h = clock.h
        for _ in 0..<clock.steps(for: dt) {
            v += acceleration(p) * (h / 2)
            p += v * h
            v += acceleration(p) * (h / 2)
            time += h
            if time >= nextTrail {
                trail.append(p)
                if trail.count > 320 { trail.removeFirst(trail.count - 320) }
                nextTrail = time + trailEvery
            }
            let r = (p * p).sum().squareRoot()
            if r < Self.sunRadius { fate = .crashed; return }
            if r > 6 { fate = .escaped; return }
        }
    }

    mutating func representative() {
        let target = min(period ?? 3, 3)
        while time < target, !settled { advance(by: 0.25) }
    }

    func readouts() -> [CookieSim.Readout] {
        let r = (p * p).sum().squareRoot(), now = (v * v).sum().squareRoot()
        var list: [CookieSim.Readout] = []
        if let period { list.append(CookieSim.readout("period", "period", period, "yr")) }
        else { list.append(CookieSim.Readout(id: "period", label: "period", value: nil, text: "none, it escapes")) }
        switch fate {
        case .crashed: list.append(CookieSim.Readout(id: "fate", label: "now", value: nil, text: "fell into the sun"))
        case .escaped: list.append(CookieSim.Readout(id: "fate", label: "now", value: nil, text: "gone, escaped"))
        case .flying:
            list.append(CookieSim.readout("distance", "distance", r, "AU"))
            list.append(CookieSim.readout("speed", "speed", now, "AU/yr"))
        }
        return list
    }

    func draw(in size: CGSize) -> CookieSim.Drawing {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let scale = (size.height / 2 - 8) / reach
        func at(_ q: SIMD2<Double>) -> CGPoint { CGPoint(x: centre.x + CGFloat(q.x) * scale, y: centre.y - CGFloat(q.y) * scale) }
        var drawing = CookieSim.Drawing()
        if trail.count > 1 { drawing.strokes.append(.init(points: (trail + [p]).map(at), tone: .ink, pen: 1.5, smooth: true, key: "trail")) }
        drawing.dots.append(.init(center: centre, radius: max(5, CGFloat(Self.sunRadius) * scale), tone: .ink))
        drawing.labels.append(.init(text: "sun", at: CGPoint(x: centre.x, y: centre.y + 14)))
        drawing.dots.append(.init(center: at(SIMD2(1, 0)), radius: 1.6, tone: .quiet))
        if fate != .crashed { drawing.dots.append(.init(center: at(p), radius: 4.2, tone: .second)) }
        return drawing
    }
}

// MARK: - Spring

/// A mass on a spring with damping, pulled out and let go: m x'' = −k x − c x', RK4.
struct Spring: CookieSimulation {
    let m: Double, k: Double, c: Double, x0: Double
    var y: SIMD4<Double>
    private(set) var time = 0.0
    var trace: [(t: Double, x: Double)] = []
    private var nextTrace = 0.0
    private var clock = CookieSim.Clock(h: 1.0 / 2000)
    let playback = 1.0
    let settled = false
    static let traceSpan = 6.0

    init(_ values: [String: Double], _ extent: [String: ClosedRange<Double>]) {
        m = values["mass"] ?? 1; k = values["stiffness"] ?? 20; c = values["damping"] ?? 0.4; x0 = values["pull"] ?? 0.2
        y = SIMD4(x0, 0, 0, 0)
        trace = [(0, x0)]
    }

    var energy: Double { 0.5 * k * y[0] * y[0] + 0.5 * m * y[1] * y[1] }
    /// The swing's period with damping; nil when it is overdamped and only creeps back.
    var period: Double? {
        let gamma = c / (2 * m), w0 = k / m
        return gamma * gamma < w0 ? 2 * .pi / (w0 - gamma * gamma).squareRoot() : nil
    }

    mutating func advance(by dt: Double) {
        let (m, k, c, h) = (self.m, self.k, self.c, clock.h)
        for _ in 0..<clock.steps(for: dt) {
            y = CookieSim.rk4(y, h) { s in SIMD4(s[1], (-k * s[0] - c * s[1]) / m, 0, 0) }
            time += h
            if time >= nextTrace {
                trace.append((time, y[0]))
                nextTrace = time + 1.0 / 60
            }
        }
        if let first = trace.firstIndex(where: { $0.t >= time - Self.traceSpan }), first > 0 { trace.removeFirst(first) }
    }

    mutating func representative() { advance(by: Self.traceSpan) }

    func readouts() -> [CookieSim.Readout] {
        [period.map { CookieSim.readout("period", "period", $0, "s") } ?? CookieSim.Readout(id: "period", label: "period", value: nil, text: "none, too damped to swing"),
         CookieSim.readout("energy", "energy", energy, "J"),
         CookieSim.readout("position", "position", y[0] * 100, "cm")]
    }

    func draw(in size: CGSize) -> CookieSim.Drawing {
        var drawing = CookieSim.Drawing()
        let wall: CGFloat = 22, rest: CGFloat = 168, scale: CGFloat = 300, top: CGFloat = 33, block: CGFloat = 34
        let left = rest + CGFloat(y[0]) * scale
        drawing.strokes.append(.init(points: [CGPoint(x: wall, y: 16), CGPoint(x: wall, y: 70)], pen: 2, key: "wall"))
        drawing.strokes.append(.init(points: [CGPoint(x: wall, y: 64), CGPoint(x: size.width - 10, y: 64)], tone: .quiet, pen: 1.2, key: "floor"))
        // The coils: ten zigs between two short straight ends.
        var coil = [CGPoint(x: wall, y: top + 15), CGPoint(x: wall + 6, y: top + 15)]
        let run = left - 6 - (wall + 6)
        for zig in 1...10 { coil.append(CGPoint(x: wall + 6 + run * (CGFloat(zig) - 0.5) / 10, y: top + 15 + (zig % 2 == 0 ? 8 : -8))) }
        coil += [CGPoint(x: left - 6, y: top + 15), CGPoint(x: left, y: top + 15)]
        drawing.strokes.append(.init(points: coil, pen: 1.4, key: "coil"))
        drawing.strokes.append(.init(points: [CGPoint(x: left, y: top), CGPoint(x: left + block, y: top), CGPoint(x: left + block, y: top + 30),
                                              CGPoint(x: left, y: top + 30), CGPoint(x: left, y: top)], tone: .ink, pen: 1.9, key: "block"))
        drawing.labels.append(.init(text: CookieCard.format(m) + " kg", at: CGPoint(x: left + block / 2, y: top + 15), tone: .text))
        drawing.strokes.append(.init(points: [CGPoint(x: rest + block / 2, y: 67), CGPoint(x: rest + block / 2, y: 73)], tone: .quiet, pen: 1.2, key: "rest"))
        // Below: where it has been over the last six seconds, the newest on the right.
        let mid: CGFloat = 128, span = CGFloat(Self.traceSpan), from = wall, to = size.width - 12
        drawing.strokes.append(.init(points: [CGPoint(x: from, y: mid), CGPoint(x: to, y: mid)], tone: .quiet, pen: 1, plain: true, key: "trace axis"))
        let points = trace.map { CGPoint(x: to - (to - from) * CGFloat(time - $0.t) / span, y: mid - CGFloat($0.x) * 113) }
        if points.count > 1 { drawing.strokes.append(.init(points: points, tone: .ink, pen: 1.4, plain: true, key: "trace")) }
        drawing.labels.append(.init(text: "position, last 6 s", at: CGPoint(x: from, y: 92), anchor: CGPoint(x: 0, y: 0.5)))
        return drawing
    }
}

// MARK: - Pendulum

/// A simple pendulum without the small-angle shortcut: θ'' = −(g/L) sin θ, RK4. Its exact period
/// is 2π√(L/g) / AGM(1, cos(θ₀/2)).
struct Pendulum: CookieSimulation {
    let length: Double, g: Double, theta0: Double
    var y: SIMD4<Double>
    private(set) var time = 0.0
    var trail: [SIMD2<Double>] = []
    private var nextTrail = 0.0
    private var clock = CookieSim.Clock(h: 1.0 / 2000)
    let playback = 1.0
    let settled = false
    let longest: Double, widest: Double
    let trailEvery: Double

    init(_ values: [String: Double], _ extent: [String: ClosedRange<Double>]) {
        length = values["length"] ?? 1; g = values["gravity"] ?? 9.81; theta0 = (values["angle"] ?? 20) * .pi / 180
        y = SIMD4(theta0, 0, 0, 0)
        longest = CookieSim.top("length", values, extent)
        widest = CookieSim.top("angle", values, extent)
        trailEvery = max(1.0 / 60, 2 * .pi * (length / g).squareRoot() / CookieSim.agm(1, cos(theta0 / 2)) / 300)
    }

    var smallAnglePeriod: Double { 2 * .pi * (length / g).squareRoot() }
    var period: Double { smallAnglePeriod / CookieSim.agm(1, cos(theta0 / 2)) }

    mutating func advance(by dt: Double) {
        let (w, h) = (g / length, clock.h)
        for _ in 0..<clock.steps(for: dt) {
            y = CookieSim.rk4(y, h) { s in SIMD4(s[1], -w * sin(s[0]), 0, 0) }
            time += h
            if time >= nextTrail {
                trail.append(SIMD2(sin(y[0]), -cos(y[0])) * length)
                if trail.count > 300 { trail.removeFirst(trail.count - 300) }
                nextTrail = time + trailEvery
            }
        }
    }

    mutating func representative() {
        var left = period
        while left > 0 { advance(by: min(5, left)); left -= 5 }
    }

    func readouts() -> [CookieSim.Readout] {
        [CookieSim.readout("period", "period", period, "s"),
         CookieSim.readout("small_angle_period", "small-angle rule", smallAnglePeriod, "s"),
         CookieSim.readout("angle", "angle", y[0] * 180 / .pi, "°")]
    }

    func draw(in size: CGSize) -> CookieSim.Drawing {
        let high = widest > 75
        let pivot = CGPoint(x: size.width / 2, y: high ? size.height / 2 : 14)
        let scale = (high ? size.height / 2 - 12 : size.height - 28) / CGFloat(longest)
        func at(_ q: SIMD2<Double>) -> CGPoint { CGPoint(x: pivot.x + CGFloat(q.x) * scale, y: pivot.y - CGFloat(q.y) * scale) }
        let bob = at(SIMD2(sin(y[0]), -cos(y[0])) * length)
        var drawing = CookieSim.Drawing()
        drawing.strokes.append(.init(points: [CGPoint(x: pivot.x - 30, y: pivot.y), CGPoint(x: pivot.x + 30, y: pivot.y)], pen: 2, key: "ceiling"))
        drawing.strokes.append(.init(points: [pivot, at(SIMD2(0, -length))], tone: .quiet, pen: 0.8, plain: true, key: "rest"))
        if trail.count > 1 { drawing.strokes.append(.init(points: trail.map(at), tone: .quiet, pen: 1.3, smooth: true, key: "trail")) }
        drawing.strokes.append(.init(points: [pivot, bob], pen: 1.4, key: "rod"))
        drawing.dots.append(.init(center: pivot, radius: 2.5, tone: .text))
        drawing.dots.append(.init(center: bob, radius: 8, tone: .ink))
        return drawing
    }
}

// MARK: - Projectile

/// A ball launched over flat ground, with optional air drag a = −g ŷ − k|v|v, flown once with RK4
/// when it is set up (a fixed step of a four-thousandth of the drag-free flight) and played back.
struct Projectile: CookieSimulation {
    let v0: Double, angle: Double, g: Double, k: Double
    /// (t, x, y) at every step, ending exactly on the ground.
    private(set) var path: [SIMD3<Double>] = []
    let flight: Double, range: Double, height: Double
    private(set) var time = 0.0
    let playback: Double
    let bounds: (range: Double, height: Double)

    init(_ values: [String: Double], _ extent: [String: ClosedRange<Double>]) {
        v0 = values["speed"] ?? 20; angle = (values["angle"] ?? 45) * .pi / 180; g = values["gravity"] ?? 9.81; k = values["drag"] ?? 0
        let (v0, g, k) = (self.v0, self.g, self.k)
        let h = 2 * v0 * sin(angle) / g / 4000
        var s = SIMD4(0, 0, v0 * cos(angle), v0 * sin(angle)), t = 0.0, top = 0.0
        path = [SIMD3(0, 0, 0)]
        while path.count < 20_000 {
            let next = CookieSim.rk4(s, h) { s in
                let speed = (s[2] * s[2] + s[3] * s[3]).squareRoot()
                return SIMD4(s[2], s[3], -k * speed * s[2], -g - k * speed * s[3])
            }
            if next[1] < 0 {
                // Land between the two steps, where the height crosses zero.
                let f = s[1] / (s[1] - next[1])
                path.append(SIMD3(t + h * f, s[0] + (next[0] - s[0]) * f, 0))
                break
            }
            s = next
            t += h
            top = max(top, s[1])
            path.append(SIMD3(t, s[0], s[1]))
        }
        flight = path.last!.x
        range = path.last!.y
        height = top
        playback = max(1, flight / 3.5)
        // The axes cover every slider at either end, drag-free (drag only shortens), so they never jump.
        var settings: [[String: Double]] = [values]
        for (id, span) in extent {
            settings = settings.flatMap { setting in
                (id == "angle" && span.contains(45) ? [span.lowerBound, 45, span.upperBound] : [span.lowerBound, span.upperBound]).map { value in
                    var next = setting; next[id] = value; return next
                }
            }
        }
        var far = range, high = height
        for setting in settings {
            let v = setting["speed"] ?? v0, a = (setting["angle"] ?? 45) * .pi / 180, gg = setting["gravity"] ?? g
            far = max(far, v * v * sin(2 * a) / gg)
            high = max(high, v * v * sin(a) * sin(a) / (2 * gg))
        }
        bounds = (max(far, 1e-3), max(high, 1e-3))
    }

    var settled: Bool { time >= flight }
    var dragFreeRange: Double { v0 * v0 * sin(2 * angle) / g }

    mutating func advance(by dt: Double) { time = min(flight, time + dt) }
    mutating func representative() { time = flight }

    /// Where the ball is at `t`, between the two steps either side.
    func position(at t: Double) -> SIMD2<Double> {
        guard let after = path.firstIndex(where: { $0.x >= t }), after > 0 else { return SIMD2(path[0].y, path[0].z) }
        let a = path[after - 1], b = path[after]
        let f = b.x == a.x ? 0 : (t - a.x) / (b.x - a.x)
        return SIMD2(a.y + (b.y - a.y) * f, a.z + (b.z - a.z) * f)
    }

    func readouts() -> [CookieSim.Readout] {
        var list = [CookieSim.readout("range", "range", range, "m"), CookieSim.readout("max_height", "max height", height, "m"),
                    CookieSim.readout("flight_time", "flight time", flight, "s")]
        if k > 0 { list.append(CookieSim.readout("drag_free_range", "without drag", dragFreeRange, "m")) }
        return list
    }

    func draw(in size: CGSize) -> CookieSim.Drawing {
        let ground = size.height - 20, origin = CGPoint(x: 18, y: ground)
        let scale = min((size.width - 34) / CGFloat(bounds.range), (ground - 18) / CGFloat(bounds.height))
        func at(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: origin.x + CGFloat(x) * scale, y: origin.y - CGFloat(y) * scale) }
        var drawing = CookieSim.Drawing()
        drawing.strokes.append(.init(points: [CGPoint(x: 10, y: ground), CGPoint(x: size.width - 8, y: ground)], tone: .quiet, pen: 1.3, key: "ground"))
        drawing.strokes.append(.init(points: [origin, CGPoint(x: origin.x + 18 * cos(angle), y: origin.y - 18 * sin(angle))], pen: 2.2, key: "launcher"))
        let flown = path.filter { $0.x <= time }
        let stride = max(1, flown.count / 240)
        var points = Swift.stride(from: 0, to: flown.count, by: stride).map { at(flown[$0].y, flown[$0].z) }
        let now = position(at: time)
        points.append(at(now.x, now.y))
        if points.count > 1 { drawing.strokes.append(.init(points: points, tone: .ink, pen: 1.6, smooth: true, key: "path")) }
        if let peak = path.max(by: { $0.z < $1.z }), time >= peak.x {
            drawing.strokes.append(.init(points: [at(peak.y, peak.z), at(peak.y, 0)], tone: .quiet, pen: 0.8, plain: true, key: "peak"))
            drawing.labels.append(.init(text: "max " + CookieCard.format(height) + " m", at: at(peak.y, peak.z).applying(.init(translationX: 0, y: -9))))
        }
        if settled {
            drawing.labels.append(.init(text: CookieCard.format(range) + " m", at: CGPoint(x: at(range, 0).x, y: ground + 10), tone: .text))
        }
        drawing.dots.append(.init(center: at(now.x, now.y), radius: 4.5, tone: .second))
        if let note = CookieSim.speedNote(playback) {
            drawing.labels.append(.init(text: note, at: CGPoint(x: size.width - 8, y: 8), anchor: CGPoint(x: 1, y: 0.5)))
        }
        return drawing
    }
}

// MARK: - Wave

/// A wave from one source, y = A sin 2π(f t − x/λ) behind its front, seen from the side; or two
/// sources in step, seen from above: their crests, and the loud lines where the paths differ by a
/// whole number of wavelengths (|r₁ − r₂| = nλ, hyperbolas). Exact in time: no integrator needed.
struct Wave: CookieSimulation {
    let f: Double, amplitude: Double, speed: Double, sources: Int, gap: Double
    private(set) var time = 0.0
    let playback = 1.0
    let settled = false
    var wavelength: Double { speed / f }
    static let span = 8.0
    static let field = 6.0

    init(_ values: [String: Double], _ extent: [String: ClosedRange<Double>]) {
        f = values["frequency"] ?? 1; amplitude = values["amplitude"] ?? 3; speed = values["speed"] ?? 2
        sources = Int((values["sources"] ?? 1).rounded()) >= 2 ? 2 : 1; gap = values["separation"] ?? 1.5
    }

    /// The height at x along a one-source wave, zero where the front hasn't reached yet.
    func height(at x: Double) -> Double {
        x <= speed * time ? amplitude * sin(2 * .pi * (f * time - x / wavelength)) : 0
    }

    /// Two sources' sum at a point d₁ and d₂ away (in step, equal amplitude).
    func sum(_ d1: Double, _ d2: Double) -> Double {
        let one = d1 <= speed * time ? sin(2 * .pi * (f * time - d1 / wavelength)) : 0
        let two = d2 <= speed * time ? sin(2 * .pi * (f * time - d2 / wavelength)) : 0
        return amplitude * (one + two)
    }

    /// The loud lines: every whole n with |n|λ less than the gap.
    var loudLines: Int { 2 * Int((gap / wavelength - 1e-9).rounded(.down)) + 1 }

    mutating func advance(by dt: Double) { time += dt }
    mutating func representative() { time = (sources == 1 ? Self.span : Self.field) / speed + 0.25 / f }

    func readouts() -> [CookieSim.Readout] {
        var list = [CookieSim.readout("wavelength", "wavelength", wavelength, "m"), CookieSim.readout("period", "period", 1 / f, "s")]
        if sources == 2 { list.append(CookieSim.Readout(id: "loud_lines", label: "loud lines", value: Double(loudLines), text: "\(loudLines)")) }
        return list
    }

    func draw(in size: CGSize) -> CookieSim.Drawing {
        var drawing = CookieSim.Drawing()
        if sources == 1 {
            let left: CGFloat = 18, scale = (size.width - 36) / CGFloat(Self.span), mid = size.height / 2
            let rise = CGFloat(amplitude) * 11
            drawing.strokes.append(.init(points: [CGPoint(x: left, y: mid), CGPoint(x: size.width - 12, y: mid)], tone: .quiet, pen: 1, plain: true, key: "axis"))
            let front = min(Self.span, speed * time)
            let samples = 160
            let points = (0...samples).map { step -> CGPoint in
                let x = front * Double(step) / Double(samples)
                return CGPoint(x: left + CGFloat(x) * scale, y: mid - CGFloat(height(at: x)) / CGFloat(amplitude) * rise)
            }
            if front > 0 { drawing.strokes.append(.init(points: points, tone: .ink, pen: 1.8, smooth: true, key: "wave")) }
            drawing.dots.append(.init(center: CGPoint(x: left, y: mid - CGFloat(height(at: 0)) / CGFloat(amplitude) * rise), radius: 3, tone: .text))
            // One wavelength measured between two crests, when one fits.
            let lambda = wavelength
            let newest = lambda * (f * time - 0.25 - (f * time - 0.25).rounded(.down))
            if lambda < front - newest, newest + lambda <= Self.span {
                let y = mid - rise - 12
                let a = CGPoint(x: left + CGFloat(newest) * scale, y: y), b = CGPoint(x: left + CGFloat(newest + lambda) * scale, y: y)
                drawing.strokes.append(.init(points: [a, b], tone: .quiet, pen: 1, plain: true, key: "lambda"))
                drawing.labels.append(.init(text: "λ " + CookieCard.format(lambda) + " m", at: CGPoint(x: (a.x + b.x) / 2, y: y - 8)))
            }
            return drawing
        }
        // From above: sources on the bottom edge, the field 6 m deep.
        let scale = (size.height - 22) / CGFloat(Self.field), base = size.height - 12, centre = size.width / 2
        let s1 = CGPoint(x: centre - CGFloat(gap / 2) * scale, y: base), s2 = CGPoint(x: centre + CGFloat(gap / 2) * scale, y: base)
        let reach = speed * time, lambda = wavelength
        let maxRadius = hypot(Double(size.width) / Double(scale), Self.field)
        for (index, source) in [s1, s2].enumerated() {
            var n = 0
            while n < 80 {
                let r = lambda * (f * time - 0.25 - Double(n))
                n += 1
                guard r > 0 else { break }
                guard r <= min(reach, maxRadius) else { continue }
                let radius = CGFloat(r) * scale
                let arc = (0...48).map { step -> CGPoint in
                    let a = CGFloat.pi * CGFloat(step) / 48
                    return CGPoint(x: source.x + radius * cos(a), y: source.y - radius * sin(a))
                }
                drawing.strokes.append(.init(points: arc, tone: index == 0 ? .ink : .second, pen: 0.9, smooth: true, plain: true, key: "crest \(index) \(n)"))
            }
        }
        // Loud lines, where both waves have arrived.
        let c = gap / 2
        for n in 0..<max(1, (loudLines + 1) / 2) {
            let a = Double(n) * lambda / 2
            let b = (c * c - a * a).squareRoot()
            for sign in n == 0 ? [1.0] : [1.0, -1.0] {
                var line: [CGPoint] = []
                for step in 0...60 {
                    let u = 3.2 * Double(step) / 60
                    let x = sign * a * cosh(u), y = b * sinh(u)
                    guard y <= Self.field, abs(x) * Double(scale) <= Double(size.width / 2) else { break }
                    let d1 = hypot(x + c, y), d2 = hypot(x - c, y)
                    guard d1 <= reach, d2 <= reach else { continue }
                    line.append(CGPoint(x: centre + CGFloat(x) * scale, y: base - CGFloat(y) * scale))
                }
                if line.count > 1 { drawing.strokes.append(.init(points: line, tone: .quiet, pen: 2.6, smooth: true, plain: true, key: "loud \(n) \(sign)")) }
            }
        }
        drawing.dots.append(.init(center: s1, radius: 3.5, tone: .ink))
        drawing.dots.append(.init(center: s2, radius: 3.5, tone: .second))
        return drawing
    }
}

// MARK: - Queue

/// One counter, people arriving at random (Poisson, rate λ a minute) and served in random times
/// (exponential, rate μ): an M/M/1 queue, run event by event with a seeded generator. Its mean
/// wait in line settles on λ / (μ(μ − λ)) when μ > λ.
struct Queue: CookieSimulation {
    let lambda: Double, mu: Double
    private(set) var time = 0.0
    let playback = 1.0
    private var random = CookieSim.Random(state: 0xC00C1E)
    private var nextArrival: Double
    private var serviceEnd: Double?
    /// When each person still waiting arrived.
    private(set) var line: [Double] = []
    private(set) var served = 0
    private(set) var waited = 0.0
    private var departures: [Double] = []
    private(set) var overflowed = false
    static let longest = 2000

    init(_ values: [String: Double], _ extent: [String: ClosedRange<Double>]) {
        lambda = values["arrivals"] ?? 2; mu = values["service"] ?? 3
        nextArrival = 0
        nextArrival = random.exponential(lambda)
    }

    var settled: Bool { overflowed }
    var expectedWait: Double? { lambda < mu ? lambda / (mu * (mu - lambda)) : nil }
    var meanWait: Double? { served > 0 ? waited / Double(served) : nil }

    mutating func advance(by dt: Double) {
        let end = time + max(0, dt)
        var events = 0
        while events < 200_000 {
            let next = min(nextArrival, serviceEnd ?? .infinity)
            guard next <= end else { break }
            events += 1
            time = next
            if next == nextArrival {
                if serviceEnd == nil {
                    served += 1
                    serviceEnd = time + random.exponential(mu)
                } else {
                    line.append(time)
                    if line.count > Self.longest { overflowed = true; return }
                }
                nextArrival = time + random.exponential(lambda)
            } else {
                departures.append(time)
                if line.isEmpty { serviceEnd = nil }
                else {
                    waited += time - line.removeFirst()
                    served += 1
                    serviceEnd = time + random.exponential(mu)
                }
            }
        }
        time = end
        departures.removeAll { $0 < time - 0.6 }
    }

    mutating func representative() { advance(by: 30) }

    func readouts() -> [CookieSim.Readout] {
        var list = [CookieSim.Readout(id: "waiting", label: "in line", value: Double(line.count), text: "\(line.count)"),
                    meanWait.map { CookieSim.readout("mean_wait", "average wait", $0, "min") }
                        ?? CookieSim.Readout(id: "mean_wait", label: "average wait", value: nil, text: "nobody served yet")]
        if let expectedWait { list.append(CookieSim.readout("expected_wait", "expected wait", expectedWait, "min")) }
        else { list.append(CookieSim.Readout(id: "expected_wait", label: "expected wait", value: nil, text: "grows without limit")) }
        list.append(CookieSim.readout("busy", "counter busy", min(1, lambda / mu) * 100, "%"))
        if overflowed { list.append(CookieSim.Readout(id: "stopped", label: "stopped", value: nil, text: "the line passed \(Self.longest)")) }
        return list
    }

    func draw(in size: CGSize) -> CookieSim.Drawing {
        var drawing = CookieSim.Drawing()
        let mid = size.height / 2 - 6, server = CGRect(x: 226, y: mid - 22, width: 44, height: 44)
        drawing.strokes.append(.init(points: [CGPoint(x: server.minX, y: server.minY), CGPoint(x: server.maxX, y: server.minY), CGPoint(x: server.maxX, y: server.maxY),
                                              CGPoint(x: server.minX, y: server.maxY), CGPoint(x: server.minX, y: server.minY)], tone: .ink, pen: 1.9, key: "counter"))
        drawing.labels.append(.init(text: "counter", at: CGPoint(x: server.midX, y: server.maxY + 10)))
        if serviceEnd != nil { drawing.dots.append(.init(center: CGPoint(x: server.midX, y: server.midY), radius: 6, tone: .second)) }
        let shown = min(line.count, 14)
        for index in 0..<shown { drawing.dots.append(.init(center: CGPoint(x: server.minX - 14 - CGFloat(index) * 14, y: mid), radius: 5, tone: .ink)) }
        if line.count > shown { drawing.labels.append(.init(text: "+\(line.count - shown)", at: CGPoint(x: 12, y: mid - 16), tone: .text, anchor: CGPoint(x: 0, y: 0.5))) }
        for left in departures {
            let t = (time - left) / 0.6
            drawing.dots.append(.init(center: CGPoint(x: server.maxX + 8 + CGFloat(t) * 44, y: mid), radius: 5, tone: .quiet))
        }
        drawing.labels.append(.init(text: "\(CookieCard.format(time)) min", at: CGPoint(x: size.width - 8, y: 10), anchor: CGPoint(x: 1, y: 0.5)))
        return drawing
    }
}

// MARK: - Flow

/// Water through a pipe that narrows and widens again (1 m long, the narrow part 20 cm): the same
/// flow through every cross-section, so v₂ = v₁ (D₁/D₂)², and Bernoulli's pressure drop
/// ½ρ(v₂² − v₁²). Tracers move with the local speed (midpoint steps).
struct Flow: CookieSimulation {
    let v1: Double, wide: Double, narrow: Double
    var tracers: [(x: Double, lane: Double)]
    private(set) var time = 0.0
    let playback: Double
    let settled = false
    let h: Double
    let biggest: Double
    static let density = 1000.0

    init(_ values: [String: Double], _ extent: [String: ClosedRange<Double>]) {
        v1 = values["speed"] ?? 1; wide = values["wide"] ?? 10; narrow = values["narrow"] ?? 5
        let fastest = max(v1, v1 * (wide / narrow) * (wide / narrow))
        playback = min(1, 0.6 / fastest)
        h = min(1.0 / 600, 0.002 / fastest)
        biggest = max(CookieSim.top("wide", values, extent), CookieSim.top("narrow", values, extent))
        tracers = (0..<18).map { index in (Double(index) / 18, [-0.6, 0, 0.6][index % 3]) }
    }

    var v2: Double { v1 * (wide / narrow) * (wide / narrow) }
    var pressureDrop: Double { 0.5 * Self.density * (v2 * v2 - v1 * v1) }
    var flowRate: Double { v1 * .pi * pow(wide / 200, 2) * 1000 }

    /// The pipe's diameter (cm) at x along it (0…1 m).
    func diameter(_ x: Double) -> Double {
        switch x {
        case ..<0.3, 0.7...: return wide
        case 0.4..<0.6: return narrow
        case 0.3..<0.4: return wide + (narrow - wide) * (x - 0.3) / 0.1
        default: return narrow + (wide - narrow) * (x - 0.6) / 0.1
        }
    }
    func speed(_ x: Double) -> Double { v1 * pow(wide / diameter(x), 2) }

    private var clock: CookieSim.Clock?

    mutating func advance(by dt: Double) {
        var clock = self.clock ?? CookieSim.Clock(h: h)
        for _ in 0..<clock.steps(for: dt) {
            for index in tracers.indices {
                let x = tracers[index].x
                var next = x + h * speed(x + h / 2 * speed(x))
                if next >= 1 { next -= 1 }
                tracers[index].x = next
            }
            time += h
        }
        self.clock = clock
    }

    mutating func representative() {}

    func readouts() -> [CookieSim.Readout] {
        [CookieSim.readout("narrow_speed", "narrow speed", v2, "m/s"),
         CookieSim.readout("pressure_drop", pressureDrop >= 0 ? "pressure drop" : "pressure rise", abs(pressureDrop) / 1000, "kPa"),
         CookieSim.readout("flow_rate", "flow", flowRate, "L/s")]
    }

    func draw(in size: CGSize) -> CookieSim.Drawing {
        var drawing = CookieSim.Drawing()
        let left: CGFloat = 12, length = size.width - 24, mid: CGFloat = 74, maxRadius: CGFloat = 38
        func r(_ x: Double) -> CGFloat { CGFloat(diameter(x) / biggest) * maxRadius }
        let xs = [0, 0.3, 0.4, 0.6, 0.7, 1.0]
        for side in [-1.0, 1.0] {
            drawing.strokes.append(.init(points: xs.map { CGPoint(x: left + CGFloat($0) * length, y: mid + CGFloat(side) * r($0)) }, pen: 1.8, key: "wall \(side)"))
        }
        for (index, tracer) in tracers.enumerated() {
            let at = CGPoint(x: left + CGFloat(tracer.x) * length, y: mid + CGFloat(tracer.lane) * r(tracer.x) * 0.8)
            // A streak behind each: its length is how far it goes in a tenth of a second on screen.
            let streak = min(44, max(3, CGFloat(speed(tracer.x) * playback * 0.1) * length))
            if at.x - streak > left {
                drawing.strokes.append(.init(points: [CGPoint(x: at.x - streak, y: at.y), at], tone: .quiet, pen: 1.2, plain: true, key: "streak \(index)"))
            }
            drawing.dots.append(.init(center: at, radius: 2.6, tone: .ink))
        }
        drawing.labels.append(.init(text: CookieCard.format(v1) + " m/s", at: CGPoint(x: left + 0.15 * length, y: mid + maxRadius + 14)))
        drawing.labels.append(.init(text: CookieCard.format(v2) + " m/s", at: CGPoint(x: left + 0.5 * length, y: mid + maxRadius + 14), tone: .text))
        if let note = CookieSim.speedNote(playback) {
            drawing.labels.append(.init(text: note, at: CGPoint(x: size.width - 8, y: 8), anchor: CGPoint(x: 1, y: 0.5)))
        }
        return drawing
    }
}

// MARK: - Decay

/// Atoms that decay at random, each after its own exponential lifetime (mean T½ / ln 2), drawn
/// once from a seeded generator: exact at every moment, so the count left follows N₀·2^(−t/T½)
/// with the scatter real atoms have.
struct Decay: CookieSimulation {
    let halfLife: Double, atoms: Int
    let lifetimes: [Double]
    private let sorted: [Double]
    private(set) var time = 0.0
    var history: [(t: Double, left: Int)] = []
    let playback: Double

    init(_ values: [String: Double], _ extent: [String: ClosedRange<Double>]) {
        halfLife = values["halflife"] ?? 3
        atoms = Int((values["atoms"] ?? 100).rounded())
        var random = CookieSim.Random(state: 0xDECA1)
        let rate = log(2) / halfLife
        lifetimes = (0..<atoms).map { _ in random.exponential(rate) }
        sorted = lifetimes.sorted()
        playback = max(1, halfLife / 4)
        history = [(0, atoms)]
    }

    var settled: Bool { time >= 6 * halfLife }
    func left(at t: Double) -> Int {
        var low = 0, high = sorted.count
        while low < high { let mid = (low + high) / 2; if sorted[mid] <= t { low = mid + 1 } else { high = mid } }
        return sorted.count - low
    }
    func expected(at t: Double) -> Double { Double(atoms) * pow(2, -t / halfLife) }

    mutating func advance(by dt: Double) {
        time = min(6 * halfLife, time + dt)
        if time - (history.last?.t ?? 0) >= halfLife / 40 || settled { history.append((time, left(at: time))) }
    }

    mutating func representative() {
        while time < 2 * halfLife { advance(by: halfLife / 40) }
    }

    func readouts() -> [CookieSim.Readout] {
        let now = left(at: time)
        return [CookieSim.Readout(id: "left", label: "left", value: Double(now), text: "\(now) of \(atoms)"),
                CookieSim.readout("expected", "expected", expected(at: time), ""),
                CookieSim.readout("time", "time", time, "s"),
                CookieSim.readout("halflife", "half-life", halfLife, "s")]
    }

    func draw(in size: CGSize) -> CookieSim.Drawing {
        var drawing = CookieSim.Drawing()
        let area = CGRect(x: 10, y: 12, width: 150, height: 150)
        let columns = Int(Double(atoms).squareRoot().rounded(.up))
        let cell = area.width / CGFloat(columns)
        for (index, lifetime) in lifetimes.enumerated() {
            let centre = CGPoint(x: area.minX + (CGFloat(index % columns) + 0.5) * cell, y: area.minY + (CGFloat(index / columns) + 0.5) * cell)
            drawing.dots.append(.init(center: centre, radius: cell * (lifetime > time ? 0.33 : 0.16), tone: lifetime > time ? .ink : .quiet))
        }
        let plot = CGRect(x: 182, y: 16, width: size.width - 192, height: 130), span = 6 * halfLife
        func at(_ t: Double, _ n: Double) -> CGPoint { CGPoint(x: plot.minX + CGFloat(t / span) * plot.width, y: plot.maxY - CGFloat(n / Double(atoms)) * plot.height) }
        drawing.strokes.append(.init(points: [CGPoint(x: plot.minX, y: plot.minY), CGPoint(x: plot.minX, y: plot.maxY), CGPoint(x: plot.maxX, y: plot.maxY)], tone: .quiet, pen: 1.2, key: "axes"))
        drawing.strokes.append(.init(points: (0...60).map { at(span * Double($0) / 60, expected(at: span * Double($0) / 60)) }, tone: .second, pen: 1.2, smooth: true, plain: true, key: "expected"))
        drawing.strokes.append(.init(points: [at(0, Double(atoms) / 2), at(halfLife, Double(atoms) / 2), at(halfLife, 0)], tone: .quiet, pen: 0.8, plain: true, key: "half"))
        drawing.labels.append(.init(text: "T½", at: CGPoint(x: at(halfLife, 0).x, y: plot.maxY + 9)))
        drawing.labels.append(.init(text: "half", at: CGPoint(x: plot.minX - 4, y: at(0, Double(atoms) / 2).y), anchor: CGPoint(x: 1, y: 0.5)))
        let counted = history.map { at($0.t, Double($0.left)) } + [at(time, Double(left(at: time)))]
        if counted.count > 1 { drawing.strokes.append(.init(points: counted, tone: .ink, pen: 1.6, key: "counted")) }
        drawing.labels.append(.init(text: "time", at: CGPoint(x: plot.maxX, y: plot.maxY + 9), anchor: CGPoint(x: 1, y: 0.5)))
        if let note = CookieSim.speedNote(playback) {
            drawing.labels.append(.init(text: note, at: CGPoint(x: size.width - 8, y: 6), anchor: CGPoint(x: 1, y: 0.5)))
        }
        return drawing
    }
}

// MARK: - Growth

/// Money (or anything) growing at a yearly rate, compounded n times a year — P(1 + r/n)^(⌊nt⌋),
/// a step at each compounding — beside continuous growth P·e^(rt) for comparison.
struct Growth: CookieSimulation {
    let rate: Double, times: Int, start: Double, years: Double
    private(set) var time = 0.0
    let playback: Double

    init(_ values: [String: Double], _ extent: [String: ClosedRange<Double>]) {
        rate = (values["rate"] ?? 7) / 100
        times = Int((values["compounding"] ?? 12).rounded())
        start = values["start"] ?? 100
        years = values["years"] ?? 20
        playback = years / 4
    }

    var settled: Bool { time >= years }
    func balance(at t: Double) -> Double {
        times == 0 ? start * exp(rate * t) : start * pow(1 + rate / Double(times), (Double(times) * t + 1e-9).rounded(.down))
    }
    func continuous(at t: Double) -> Double { start * exp(rate * t) }
    var doublingTime: Double { times == 0 ? log(2) / rate : log(2) / (Double(times) * log(1 + rate / Double(times))) }

    mutating func advance(by dt: Double) { time = min(years, time + dt) }
    mutating func representative() { time = years }

    func readouts() -> [CookieSim.Readout] {
        [CookieSim.readout("balance", "now", balance(at: time), ""),
         CookieSim.readout("final", "after \(CookieCard.format(years)) yr", balance(at: years), ""),
         CookieSim.readout("doubling_time", "doubles every", doublingTime, "yr")]
    }

    func draw(in size: CGSize) -> CookieSim.Drawing {
        var drawing = CookieSim.Drawing()
        let plot = CGRect(x: 44, y: 14, width: size.width - 56, height: size.height - 40)
        let top = CookieSim.roundUp(continuous(at: years))
        func at(_ t: Double, _ v: Double) -> CGPoint {
            CGPoint(x: plot.minX + CGFloat(t / years) * plot.width, y: plot.maxY - CGFloat(v / top.upperBound) * plot.height)
        }
        drawing.strokes.append(.init(points: [CGPoint(x: plot.minX, y: plot.minY), CGPoint(x: plot.minX, y: plot.maxY), CGPoint(x: plot.maxX, y: plot.maxY)], tone: .quiet, pen: 1.2, key: "axes"))
        drawing.strokes.append(.init(points: (0...80).map { at(years * Double($0) / 80, continuous(at: years * Double($0) / 80)) }, tone: .second, pen: 1.1, smooth: true, plain: true, key: "continuous"))
        let samples = max(2, min(240, times == 0 ? 120 : Int(Double(times) * years) * 2 + 1))
        var points: [CGPoint] = []
        for step in 0...samples {
            let t = time * Double(step) / Double(samples)
            points.append(at(t, balance(at: t)))
        }
        if time > 0 { drawing.strokes.append(.init(points: points, tone: .ink, pen: 1.7, key: "balance")) }
        drawing.dots.append(.init(center: at(time, balance(at: time)), radius: 3.5, tone: .ink))
        for (value, label) in [(top.upperBound, CookieCard.format(top.upperBound)), (0, "0")] {
            drawing.labels.append(.init(text: label, at: CGPoint(x: plot.minX - 5, y: at(0, value).y), anchor: CGPoint(x: 1, y: 0.5)))
        }
        drawing.labels.append(.init(text: "0", at: CGPoint(x: plot.minX, y: plot.maxY + 10)))
        drawing.labels.append(.init(text: CookieCard.format(years) + " yr", at: CGPoint(x: plot.maxX, y: plot.maxY + 10), anchor: CGPoint(x: 1, y: 0.5)))
        drawing.labels.append(.init(text: times == 0 ? "compounded continuously" : "steps: compounded \(times)× a year", at: CGPoint(x: plot.minX + 6, y: plot.minY + 4), anchor: CGPoint(x: 0, y: 0.5)))
        return drawing
    }
}

// MARK: - Runner

/// Drives one simulation on the display link at the screen's rate, only while it is live (on
/// screen, not Reduce Motion), revealed, open and running; otherwise it holds still. Parameters are
/// kept inside the model's range; changing one starts the run again from its first moment.
@MainActor
final class CookieSimRunner: ObservableObject {
    private(set) var sim: CookieCard.Sim
    @Published private(set) var values: [String: Double]
    @Published private(set) var running: Bool
    /// Bumped every frame, so the drawing redraws.
    @Published private(set) var frame = 0
    private(set) var simulation: any CookieSimulation
    private let ticker = CookieScreenTicker()
    private var last: CFTimeInterval = 0
    private(set) var ticking = false
    var screen: NSScreen?

    /// Motion is on: the card is really on screen and Reduce Motion is off. Off, every setting
    /// shows its representative frame, trail and all.
    var live = false { didSet { if live != oldValue { rebuild(); update() } } }
    /// Its picture has been revealed on the speech clock.
    var shown = false { didSet { if shown != oldValue { update() } } }
    /// Folded, closed or covered: nothing to draw for.
    var hidden = false { didSet { if hidden != oldValue { update() } } }

    init(_ sim: CookieCard.Sim) {
        self.sim = sim
        values = sim.values
        running = sim.running
        simulation = Self.make(sim, values: sim.values)
        simulation.representative()
    }

    var model: CookieSim.Model { CookieSim.models[sim.model]! }
    var readouts: [CookieSim.Readout] { simulation.readouts() }
    var settled: Bool { simulation.settled }

    private static func make(_ sim: CookieCard.Sim, values: [String: Double]) -> any CookieSimulation {
        let extent = Dictionary(sim.sliders.map { ($0.param, $0.minimum...$0.maximum) }, uniquingKeysWith: { first, _ in first })
        return CookieSim.models[sim.model]!.make(values, extent)
    }

    /// A new state of the card: its parameters and whether it runs.
    func load(_ next: CookieCard.Sim) {
        sim = next
        values = next.values
        running = next.running
        rebuild()
        update()
    }

    /// One parameter to a new value (kept in its range). False when the model has no such parameter.
    @discardableResult
    func set(_ name: String, _ value: Double) -> Bool {
        guard let param = model.param(name), value.isFinite else { return false }
        values[param.id] = param.clamp(value)
        rebuild()
        update()
        return true
    }

    func run() {
        running = true
        if simulation.settled { rebuild() }
        update()
    }

    func pause() {
        running = false
        update()
    }

    func restart() {
        rebuild()
        update()
    }

    func stop() {
        hidden = true
        ticker.stop()
        ticking = false
    }

    private func rebuild() {
        simulation = Self.make(sim, values: values)
        if !live { simulation.representative() }
        frame += 1
    }

    private func update() {
        let wanted = live && shown && !hidden && running && !simulation.settled
        if wanted, !ticking {
            ticking = true
            last = CACurrentMediaTime()
            ticker.start(on: screen) { [weak self] in
                MainActor.assumeIsolated { self?.tick() }
            }
        } else if !wanted, ticking {
            ticking = false
            ticker.stop()
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        // A long gap (the machine slept, a hitch) plays as a tenth of a second, not a jump.
        let dt = min(0.1, max(0, now - last))
        last = now
        simulation.advance(by: dt * simulation.playback)
        frame += 1
        if simulation.settled { update() }
    }
}
