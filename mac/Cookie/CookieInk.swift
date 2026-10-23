//
//  CookieInk.swift
//  Cookie
//
//  Cookie's pen. A mark's ideal shape (a ring, a line) is first roughened the
//  way a hand misses a ruler, then each stroke is inked as a filled outline
//  whose width follows the pen's speed. Both halves are small pure-math ports:
//
//  - The roughening is the core of Rough.js's line and ellipse perturbation
//    (renderer.js `_line`, `_doubleLine`, `_curve`, `_computeEllipsePoints`,
//    `generateEllipseParams`, and its seeded `Random`), roughjs 4.6.6,
//    MIT License, Copyright (c) 2019 Preet Shihn.
//  - The ink outline is perfect-freehand's `getStrokePoints`,
//    `getStrokeOutlinePoints` and `simulatePressure`, MIT License,
//    Copyright (c) 2021 Stephen Ruiz Ltd.
//
//  Both licences are reproduced in THIRD_PARTY_NOTICES.md at the repository root.
//
//  A filled outline cannot be revealed by trimming its path, so a stroke draws
//  on by inking only the part of its centreline the pen has reached so far.
//

import CoreGraphics
import Foundation

/// One pen stroke: a centreline, evenly spaced, and how wide the pen is.
struct CookieInkStroke {
    let points: [CGPoint]
    /// Running length at each point.
    let lengths: [CGFloat]
    /// Pen diameter in points.
    let size: CGFloat

    var length: CGFloat { lengths.last ?? 0 }

    init(_ polyline: [CGPoint], size: CGFloat, spacing: CGFloat = 2) {
        self.size = size
        var points: [CGPoint] = []
        var lengths: [CGFloat] = []
        var run: CGFloat = 0
        for point in polyline {
            if let last = points.last {
                let step = hypot(point.x - last.x, point.y - last.y)
                guard step >= spacing * 0.5 else { continue }
                run += step
            }
            points.append(point)
            lengths.append(run)
        }
        self.points = points
        self.lengths = lengths
    }

    /// Where the pen is after `distance` along this stroke, and which way it is travelling (radians,
    /// 0 = right, y down).
    func pen(at distance: CGFloat) -> (point: CGPoint, heading: CGFloat)? {
        guard points.count >= 2 else { return points.first.map { ($0, 0) } }
        let reach = min(max(0, distance), length)
        let index = max(1, lengths.firstIndex { $0 >= reach } ?? points.count - 1)
        let a = points[index - 1], b = points[index]
        let t = (reach - lengths[index - 1]) / max(0.0001, lengths[index] - lengths[index - 1])
        return (CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), atan2(b.y - a.y, b.x - a.x))
    }

    /// The ink of the first `reveal` points of length: a closed outline to fill.
    func outline(revealed reveal: CGFloat) -> CGPath? {
        guard points.count >= 2, reveal > 0 else { return nil }
        var prefix: [CGPoint] = []
        for (index, point) in points.enumerated() {
            if lengths[index] <= reveal {
                prefix.append(point)
            } else {
                let previous = points[index - 1], from = lengths[index - 1]
                let t = (reveal - from) / max(0.0001, lengths[index] - from)
                prefix.append(CGPoint(x: previous.x + (point.x - previous.x) * t, y: previous.y + (point.y - previous.y) * t))
                break
            }
        }
        let polygon = CookieFreehand.outline(prefix, size: size, complete: reveal >= length)
        guard polygon.count >= 3 else { return nil }
        let path = CGMutablePath()
        path.addLines(between: polygon)
        path.closeSubpath()
        return path
    }
}

// MARK: - Rough

/// Rough.js's line and ellipse perturbation, seeded so a mark wobbles the same way every frame.
struct CookieRough {
    var roughness: CGFloat = 1
    var bowing: CGFloat = 1
    var maxRandomnessOffset: CGFloat = 2
    var curveFitting: CGFloat = 0.95
    var curveStepCount: CGFloat = 9
    private var seed: UInt32
    private var state: UInt32

    init(seed: UInt32) {
        self.seed = max(1, seed)
        self.state = max(1, seed)
    }

    /// Rough.js `Random`: a Park–Miller step, `(2^31 - 1) & (seed = imul(48271, seed))) / 2^31`.
    private mutating func random() -> CGFloat {
        state = state &* 48271
        return CGFloat(state & 0x7FFF_FFFF) / 2_147_483_648
    }

    private mutating func offset(_ min: CGFloat, _ max: CGFloat, gain: CGFloat = 1) -> CGFloat {
        roughness * gain * (random() * (max - min) + min)
    }

    private mutating func offsetOpt(_ x: CGFloat, gain: CGFloat = 1) -> CGFloat {
        offset(-x, x, gain: gain)
    }

    /// Rough.js `cloneOptionsAlterSeed`: the second pass of a shape draws from seed + 1.
    private func altered() -> CookieRough {
        var copy = self
        copy.seed = seed &+ 1
        copy.state = copy.seed
        return copy
    }

    /// A line drawn twice, each pass a bowed cubic with jittered ends: two polylines.
    mutating func line(_ a: CGPoint, _ b: CGPoint) -> [[CGPoint]] {
        [flatten(roughLine(a, b, overlay: false)), flatten(roughLine(a, b, overlay: true))]
    }

    /// Each segment of a polyline as its own doubled line.
    mutating func linearPath(_ points: [CGPoint]) -> [[CGPoint]] {
        guard points.count >= 2 else { return [] }
        return (0..<(points.count - 1)).flatMap { line(points[$0], points[$0 + 1]) }
    }

    /// An ellipse drawn twice; the first pass's ends overshoot and don't quite meet.
    mutating func ellipse(center: CGPoint, width: CGFloat, height: CGFloat) -> [[CGPoint]] {
        // generateEllipseParams
        let psq = sqrt(CGFloat.pi * 2 * sqrt((pow(width / 2, 2) + pow(height / 2, 2)) / 2))
        let stepCount = ceil(max(curveStepCount, (curveStepCount / sqrt(200)) * psq))
        let increment = CGFloat.pi * 2 / stepCount
        var rx = abs(width / 2), ry = abs(height / 2)
        let fitRandomness = 1 - curveFitting
        rx += offsetOpt(rx * fitRandomness)
        ry += offsetOpt(ry * fitRandomness)
        // ellipseWithParams
        let overlap = increment * offset(0.1, offset(0.4, 1))
        let first = ellipsePoints(increment: increment, center: center, rx: rx, ry: ry, offset: 1, overlap: overlap)
        let second = ellipsePoints(increment: increment, center: center, rx: rx, ry: ry, offset: 1.5, overlap: 0)
        return [flatten(curve(first)), flatten(curve(second))]
    }

    /// A smooth curve through points, drawn twice with jittered points (Rough.js `curve`).
    mutating func curve(through points: [CGPoint]) -> [[CGPoint]] {
        var second = altered()
        let one = curveWithOffset(points, offset: 1 * (1 + roughness * 0.2))
        let two = second.curveWithOffset(points, offset: 1.5 * (1 + roughness * 0.22))
        return [flatten(one), flatten(two)]
    }

    // MARK: Rough.js internals

    private enum Op {
        case move(CGPoint)
        case curve(CGPoint, CGPoint, CGPoint)
    }

    private mutating func roughLine(_ a: CGPoint, _ b: CGPoint, overlay: Bool) -> [Op] {
        let lengthSq = pow(a.x - b.x, 2) + pow(a.y - b.y, 2)
        let length = sqrt(lengthSq)
        let gain: CGFloat = length < 200 ? 1 : length > 500 ? 0.4 : -0.0016668 * length + 1.233334
        var offset = maxRandomnessOffset
        if offset * offset * 100 > lengthSq { offset = length / 10 }
        let half = offset / 2
        let diverge = 0.2 + random() * 0.2
        let midX = offsetOpt(bowing * maxRandomnessOffset * (b.y - a.y) / 200, gain: gain)
        let midY = offsetOpt(bowing * maxRandomnessOffset * (a.x - b.x) / 200, gain: gain)
        let jitter = overlay ? half : offset
        let start = CGPoint(x: a.x + offsetOpt(jitter, gain: gain), y: a.y + offsetOpt(jitter, gain: gain))
        let c1 = CGPoint(x: midX + a.x + (b.x - a.x) * diverge + offsetOpt(jitter, gain: gain),
                         y: midY + a.y + (b.y - a.y) * diverge + offsetOpt(jitter, gain: gain))
        let c2 = CGPoint(x: midX + a.x + 2 * (b.x - a.x) * diverge + offsetOpt(jitter, gain: gain),
                         y: midY + a.y + 2 * (b.y - a.y) * diverge + offsetOpt(jitter, gain: gain))
        let end = CGPoint(x: b.x + offsetOpt(jitter, gain: gain), y: b.y + offsetOpt(jitter, gain: gain))
        return [.move(start), .curve(c1, c2, end)]
    }

    private mutating func curveWithOffset(_ points: [CGPoint], offset: CGFloat) -> [Op] {
        guard let first = points.first else { return [] }
        var jittered: [CGPoint] = []
        let jitter = { (point: CGPoint, rough: inout CookieRough) in
            CGPoint(x: point.x + rough.offsetOpt(offset), y: point.y + rough.offsetOpt(offset))
        }
        jittered.append(jitter(first, &self))
        jittered.append(jitter(first, &self))
        for index in 1..<points.count {
            jittered.append(jitter(points[index], &self))
            if index == points.count - 1 { jittered.append(jitter(points[index], &self)) }
        }
        return curve(jittered)
    }

    /// Catmull-Rom through points as cubics (curveTightness 0), from the second point.
    private func curve(_ points: [CGPoint]) -> [Op] {
        let count = points.count
        guard count > 3 else {
            if count == 3 { return [.move(points[1]), .curve(points[1], points[2], points[2])] }
            return []
        }
        var ops: [Op] = [.move(points[1])]
        for i in 1..<(count - 2) {
            let p = points[i], next = points[i + 1]
            let c1 = CGPoint(x: p.x + (next.x - points[i - 1].x) / 6, y: p.y + (next.y - points[i - 1].y) / 6)
            let c2 = CGPoint(x: next.x + (p.x - points[i + 2].x) / 6, y: next.y + (p.y - points[i + 2].y) / 6)
            ops.append(.curve(c1, c2, next))
        }
        return ops
    }

    private mutating func ellipsePoints(increment: CGFloat, center: CGPoint, rx: CGFloat, ry: CGFloat,
                                        offset: CGFloat, overlap: CGFloat) -> [CGPoint] {
        var points: [CGPoint] = []
        let radOffset = offsetOpt(0.5) - CGFloat.pi / 2
        func at(_ angle: CGFloat, _ scale: CGFloat, _ rough: inout CookieRough) -> CGPoint {
            CGPoint(x: rough.offsetOpt(offset) + center.x + scale * rx * cos(angle),
                    y: rough.offsetOpt(offset) + center.y + scale * ry * sin(angle))
        }
        points.append(at(radOffset - increment, 0.9, &self))
        let endAngle = CGFloat.pi * 2 + radOffset - 0.01
        var angle = radOffset
        while angle < endAngle {
            points.append(at(angle, 1, &self))
            angle += increment
        }
        points.append(at(radOffset + CGFloat.pi * 2 + overlap * 0.5, 1, &self))
        points.append(at(radOffset + overlap, 0.98, &self))
        points.append(at(radOffset + overlap * 0.5, 0.9, &self))
        return points
    }

    /// Cubic ops → one polyline, about a point every 2 points of length.
    private func flatten(_ ops: [Op]) -> [CGPoint] {
        var line: [CGPoint] = []
        var current = CGPoint.zero
        for op in ops {
            switch op {
            case .move(let point):
                current = point
                line.append(point)
            case .curve(let c1, let c2, let end):
                let span = hypot(c1.x - current.x, c1.y - current.y) + hypot(c2.x - c1.x, c2.y - c1.y) + hypot(end.x - c2.x, end.y - c2.y)
                let steps = max(4, Int(span / 2))
                for step in 1...steps {
                    let t = CGFloat(step) / CGFloat(steps), u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    line.append(CGPoint(x: a * current.x + b * c1.x + c * c2.x + d * end.x,
                                        y: a * current.y + b * c1.y + c * c2.y + d * end.y))
                }
                current = end
            }
        }
        return line
    }
}

// MARK: - Freehand

/// perfect-freehand's outline, with simulated pressure, round caps and optional tapers.
enum CookieFreehand {
    static let thinning: CGFloat = 0.55
    static let smoothing: CGFloat = 0.5
    static let streamline: CGFloat = 0.35

    private struct StrokePoint {
        var point: CGPoint
        var pressure: CGFloat
        var vector: CGPoint
        var distance: CGFloat
        var runningLength: CGFloat
    }

    // Constants from perfect-freehand's constants.ts.
    private static let rateOfPressureChange: CGFloat = 0.275
    private static let fixedPi = CGFloat.pi + 0.0001
    private static let startCapSegments: CGFloat = 13
    private static let endCapSegments: CGFloat = 29
    private static let cornerCapSegments: CGFloat = 13
    private static let endNoiseThreshold: CGFloat = 3
    private static let minRadius: CGFloat = 0.01

    /// The filled outline around `input`, a pen `size` across. `complete` = the pen has lifted.
    /// The end always tapers, so the tip moving across the screen reads as a pen, and the
    /// stroke doesn't change shape when it finishes.
    static func outline(_ input: [CGPoint], size: CGFloat, complete: Bool) -> [CGPoint] {
        outlinePoints(strokePoints(input, size: size, complete: complete), size: size, taperEnd: size * 2.5)
    }

    private static func strokePoints(_ input: [CGPoint], size: CGFloat, complete: Bool) -> [StrokePoint] {
        guard !input.isEmpty else { return [] }
        let t = 0.15 + (1 - streamline) * 0.85
        var pts = input
        if pts.count == 2 {
            let last = pts[1]
            pts = [pts[0]] + (1..<5).map { lerp(pts[0], last, CGFloat($0) / 4) }
        }
        if pts.count == 1 { pts.append(CGPoint(x: pts[0].x + 1, y: pts[0].y + 1)) }
        var stroke = [StrokePoint(point: pts[0], pressure: 0.25, vector: CGPoint(x: 1, y: 1), distance: 0, runningLength: 0)]
        var reachedMinimum = false
        var running: CGFloat = 0
        var previous = stroke[0]
        let max = pts.count - 1
        for i in 1..<pts.count {
            let point = complete && i == max ? pts[i] : lerp(previous.point, pts[i], t)
            if point == previous.point { continue }
            let distance = hypot(point.x - previous.point.x, point.y - previous.point.y)
            running += distance
            if i < max && !reachedMinimum {
                if running < size { continue }
                reachedMinimum = true
            }
            previous = StrokePoint(point: point, pressure: 0.5,
                                   vector: unit(CGPoint(x: previous.point.x - point.x, y: previous.point.y - point.y)),
                                   distance: distance, runningLength: running)
            stroke.append(previous)
        }
        stroke[0].vector = stroke.count > 1 ? stroke[1].vector : .zero
        return stroke
    }

    private static func simulatePressure(_ previous: CGFloat, _ distance: CGFloat, _ size: CGFloat) -> CGFloat {
        let sp = min(1, distance / size)
        let rp = min(1, 1 - sp)
        return min(1, previous + (rp - previous) * (sp * rateOfPressureChange))
    }

    private static func radius(_ size: CGFloat, _ pressure: CGFloat) -> CGFloat {
        size * (0.5 - thinning * (0.5 - pressure))
    }

    private static func outlinePoints(_ points: [StrokePoint], size: CGFloat, taperEnd: CGFloat) -> [CGPoint] {
        guard let lastStroke = points.last, size > 0 else { return [] }
        let totalLength = lastStroke.runningLength
        let minDistance = pow(size * smoothing, 2)
        var left: [CGPoint] = [], right: [CGPoint] = []
        // Averaged over the first points so a stroke doesn't start fat.
        var prevPressure = points.prefix(10).reduce(points[0].pressure) { acc, current in
            (acc + simulatePressure(acc, current.distance, size)) / 2
        }
        var r = radius(size, lastStroke.pressure)
        var firstRadius: CGFloat?
        var prevVector = points[0].vector
        var prevLeft = points[0].point, prevRight = points[0].point
        var tempLeft = prevLeft, tempRight = prevRight
        var prevWasSharpCorner = false

        for i in points.indices {
            let current = points[i]
            let isLast = i == points.count - 1
            if !isLast && totalLength - current.runningLength < endNoiseThreshold { continue }
            let pressure = simulatePressure(prevPressure, current.distance, size)
            r = radius(size, pressure)
            if firstRadius == nil { firstRadius = r }
            // Taper the end (taperEnd easing: --t * t * t + 1).
            if taperEnd > 0, totalLength - current.runningLength < taperEnd {
                let x = (totalLength - current.runningLength) / taperEnd - 1
                r *= x * x * x + 1
            }
            r = Swift.max(minRadius, r)

            let nextVector = (isLast ? current : points[i + 1]).vector
            let nextDot = isLast ? 1 : dot(current.vector, nextVector)
            let prevDot = dot(current.vector, prevVector)
            let sharp = prevDot < 0 && !prevWasSharpCorner
            let nextSharp = nextDot < 0
            if sharp || nextSharp {
                let offset = scale(perpendicular(prevVector), r)
                var t: CGFloat = 0
                while t <= 1 {
                    tempLeft = rotate(CGPoint(x: current.point.x - offset.x, y: current.point.y - offset.y), around: current.point, by: fixedPi * t)
                    left.append(tempLeft)
                    tempRight = rotate(CGPoint(x: current.point.x + offset.x, y: current.point.y + offset.y), around: current.point, by: fixedPi * -t)
                    right.append(tempRight)
                    t += 1 / cornerCapSegments
                }
                prevLeft = tempLeft
                prevRight = tempRight
                if nextSharp { prevWasSharpCorner = true }
                continue
            }
            prevWasSharpCorner = false
            if isLast {
                let offset = scale(perpendicular(current.vector), r)
                left.append(CGPoint(x: current.point.x - offset.x, y: current.point.y - offset.y))
                right.append(CGPoint(x: current.point.x + offset.x, y: current.point.y + offset.y))
                continue
            }
            let offset = scale(perpendicular(lerp(nextVector, current.vector, nextDot)), r)
            tempLeft = CGPoint(x: current.point.x - offset.x, y: current.point.y - offset.y)
            if i <= 1 || distanceSquared(prevLeft, tempLeft) > minDistance {
                left.append(tempLeft)
                prevLeft = tempLeft
            }
            tempRight = CGPoint(x: current.point.x + offset.x, y: current.point.y + offset.y)
            if i <= 1 || distanceSquared(prevRight, tempRight) > minDistance {
                right.append(tempRight)
                prevRight = tempRight
            }
            prevPressure = pressure
            prevVector = current.vector
        }

        let first = points[0].point
        let last = points.count > 1 ? lastStroke.point : CGPoint(x: first.x + 1, y: first.y + 1)
        if points.count == 1 {
            // A dot.
            let start = project(first, unit(perpendicular(CGPoint(x: -1, y: -1))), -(firstRadius ?? r))
            return stride(from: 1 / startCapSegments, through: 1, by: 1 / startCapSegments).map {
                rotate(start, around: first, by: fixedPi * 2 * $0)
            }
        }
        guard let rightFirst = right.first else { return [] }
        var startCap: [CGPoint] = []
        var t = 1 / startCapSegments
        while t <= 1 {
            startCap.append(rotate(rightFirst, around: first, by: fixedPi * t))
            t += 1 / startCapSegments
        }
        var endCap: [CGPoint] = []
        if taperEnd > 0 {
            endCap.append(last)
        } else {
            let direction = perpendicular(CGPoint(x: -lastStroke.vector.x, y: -lastStroke.vector.y))
            let start = project(last, direction, r)
            var t = 1 / endCapSegments
            while t < 1 {
                endCap.append(rotate(start, around: last, by: fixedPi * 3 * t))
                t += 1 / endCapSegments
            }
        }
        return left + endCap + right.reversed() + startCap
    }

    // perfect-freehand's vec.ts, the parts used.
    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
    private static func unit(_ a: CGPoint) -> CGPoint {
        let length = hypot(a.x, a.y)
        return length == 0 ? .zero : CGPoint(x: a.x / length, y: a.y / length)
    }
    private static func perpendicular(_ a: CGPoint) -> CGPoint { CGPoint(x: a.y, y: -a.x) }
    private static func scale(_ a: CGPoint, _ s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
    private static func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }
    private static func project(_ a: CGPoint, _ b: CGPoint, _ c: CGFloat) -> CGPoint { CGPoint(x: a.x + b.x * c, y: a.y + b.y * c) }
    private static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat { pow(a.x - b.x, 2) + pow(a.y - b.y, 2) }
    private static func rotate(_ a: CGPoint, around c: CGPoint, by r: CGFloat) -> CGPoint {
        let s = sin(r), co = cos(r)
        let px = a.x - c.x, py = a.y - c.y
        return CGPoint(x: px * co - py * s + c.x, y: px * s + py * co + c.y)
    }
}
