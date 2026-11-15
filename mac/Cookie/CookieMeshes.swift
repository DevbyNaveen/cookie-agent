//
//  CookieMeshes.swift
//  Cookie
//
//  The parts library: every scene shape drawn in Swift from its numbers —
//  vertices, unit normals, texture coordinates and triangles wound
//  anticlockwise from outside (RealityKit's front face), closed wherever the
//  real thing is solid. The model never sends geometry, only a shape's name
//  and numbers (`CookieScene.Form`); everything here is vetted code.
//
//  A handful of builders make all of it: a lathe (a profile spun about y), an
//  extrusion (an outline with holes, given depth), a loft (a section carried
//  along a path or out a blade), a grid (the screw's thread) and a rounded
//  box. Each shape stays inside the box `CookieScene.bounds(of:)` promises,
//  so framing never needs the mesh.
//
//  Shapes are cached by their numbers: the plain geometry (thread-safe, so it
//  can be made off the main thread) and RealityKit's mesh made from it
//  (`CookieMeshResources`), warmed off the main thread before a scene shows.
//

import Foundation
import RealityKit
import simd

/// A triangle mesh in plain arrays: one normal and one texture coordinate per vertex.
struct CookieGeometry {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var indices: [UInt32] = []

    var triangleCount: Int { indices.count / 3 }

    @discardableResult
    mutating func add(_ position: SIMD3<Float>, _ normal: SIMD3<Float>, _ uv: SIMD2<Float>) -> UInt32 {
        positions.append(position)
        let length = simd_length(normal)
        normals.append(length > 1e-12 ? normal / length : [0, 1, 0])
        uvs.append(simd_clamp(uv, .zero, .one))
        return UInt32(positions.count - 1)
    }

    /// One triangle, anticlockwise seen from outside; a triangle with no area (where a ring meets
    /// the axis) is left out.
    mutating func triangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        let pa = positions[Int(a)], pb = positions[Int(b)], pc = positions[Int(c)]
        // Measured against its sides, so a sliver from two rounding-apart copies of one point goes too.
        let u = pb - pa, v = pc - pa
        guard simd_length_squared(simd_cross(u, v)) > 1e-10 * simd_length_squared(u) * simd_length_squared(v), simd_length_squared(u) > 0 else { return }
        indices += [a, b, c]
    }

    mutating func quad(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) {
        triangle(a, b, c)
        triangle(a, c, d)
    }

    /// Adds another mesh, moved by a rigid transform.
    mutating func append(_ other: CookieGeometry, _ transform: simd_float4x4 = matrix_identity_float4x4) {
        let base = UInt32(positions.count)
        let turn = simd_float3x3(SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                                 SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                                 SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        for index in other.positions.indices {
            let p = transform * SIMD4(other.positions[index], 1)
            positions.append(SIMD3(p.x, p.y, p.z))
            normals.append(simd_normalize(turn * other.normals[index]))
        }
        uvs += other.uvs
        indices += other.indices.map { $0 + base }
    }

    func moved(_ transform: simd_float4x4) -> CookieGeometry {
        var moved = CookieGeometry()
        moved.append(self, transform)
        return moved
    }

    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard let first = positions.first else { return (.zero, .zero) }
        return positions.reduce((first, first)) { (simd_min($0.0, $1), simd_max($0.1, $1)) }
    }

    /// RealityKit's description of this mesh.
    var descriptor: MeshDescriptor {
        var descriptor = MeshDescriptor(name: "cookie-part")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return descriptor
    }
}

enum CookieMeshes {
    // MARK: Cache

    private static let lock = NSLock()
    private static var cache: [CookieScene.Form: CookieGeometry] = [:]
    /// How many shapes have been drawn from scratch (not from the cache): for the parts checks.
    private(set) static var builds = 0
    /// ponytail: the whole cache clears when full; an LRU is only worth it if scenes ever cycle many more shapes.
    static let cacheLimit = 256

    /// The shape's mesh, drawn once per set of numbers. Safe from any thread.
    static func geometry(_ form: CookieScene.Form) -> CookieGeometry {
        lock.lock()
        if let cached = cache[form] { lock.unlock(); return cached }
        lock.unlock()
        let made = build(form)
        lock.lock()
        if cache.count >= cacheLimit { cache.removeAll() }
        cache[form] = made
        builds += 1
        lock.unlock()
        return made
    }

    // MARK: Shapes

    /// Segments around anything round.
    static let around = 48
    private static let up = SIMD3<Float>(0, 1, 0)

    static func build(_ form: CookieScene.Form) -> CookieGeometry {
        let f = form
        switch form.shape {
        case .box: return roundedBox(SIMD3(f["width"], f["height"], f["depth"]), corner: f.values["corner"] ?? min(f["width"], f["height"], f["depth"]) * 0.04)
        case .sphere: return lathe(arc(centre: .zero, radii: SIMD2(repeating: f["radius"]), from: -.pi / 2, to: .pi / 2, steps: 24), segments: around)
        case .cylinder: return lathe(polyline([[0, -f["height"] / 2], [f["radius"], -f["height"] / 2], [f["radius"], f["height"] / 2], [0, f["height"] / 2]]), segments: around)
        case .cone: return lathe(polyline([[0, -f["height"] / 2], [f["radius"], -f["height"] / 2], [0, f["height"] / 2]]), segments: around)
        case .capsule:
            let r = f["radius"], h = f["height"]
            return lathe(arc(centre: [0, -h / 2 + r], radii: [r, r], from: -.pi / 2, to: 0, steps: 12)
                         + arc(centre: [0, h / 2 - r], radii: [r, r], from: 0, to: .pi / 2, steps: 12), segments: around)
        case .torus: return lathe(arc(centre: [f["radius"], 0], radii: SIMD2(repeating: f["tube"]), from: -.pi, to: .pi, steps: 32), segments: around)
        case .tube: return lathe(ring(inner: f["inner"], outer: f["radius"], height: f["length"], chamfer: 0), segments: around)
        case .gear: return gear(f, taper: 1)
        case .bevelGear:
            let outer = CookieScene.gearRadii(f).outer
            return gear(f, taper: max(0.25, 1 - f["thickness"] / tan(f["cone"] * .pi / 180) / outer))
        case .rack: return rack(f)
        case .shaft: return shaft(f)
        case .bearing: return bearing(f)
        case .bladeRing: return bladeRing(f)
        case .spring: return spring(f)
        case .pipe: return pipe(f)
        case .piston: return piston(f)
        case .crank: return crank(f)
        case .rod: return rod(f)
        case .valve: return valve(f)
        case .wheel: return wheel(f)
        case .propeller: return propeller(f)
        case .screw: return screw(f)
        case .lathe: return turned(f)
        case .extrude: return extruded(f)
        case .sweep: return swept(f)
        case .arrow:
            let r = f["radius"], l = f["length"], head = min(l * 0.35, r * 7)
            return lathe(polyline([[0, -l / 2], [r, -l / 2], [r, l / 2 - head], [r * 2.6, l / 2 - head], [0, l / 2]]), segments: 32)
        }
    }

    // MARK: Lathe

    /// A point on a lathe profile: (radius, y) and its outward normal in that plane.
    struct ProfilePoint { var point: SIMD2<Float>; var normal: SIMD2<Float> }

    /// The profile spun about y. Walk the profile from the bottom of the outside up (the solid on the
    /// left), so its normals point out.
    static func lathe(_ profile: [ProfilePoint], segments: Int) -> CookieGeometry {
        var g = CookieGeometry()
        guard profile.count >= 2 else { return g }
        var travelled: [Float] = [0]
        for index in profile.indices.dropFirst() { travelled.append(travelled[index - 1] + simd_distance(profile[index].point, profile[index - 1].point)) }
        let total = max(travelled.last ?? 1, 1e-9)
        var rings: [[UInt32]] = []
        for (index, point) in profile.enumerated() {
            // cos(±π/2) isn't quite 0 in floats: a radius that small is on the axis, not a sliver turned inside out.
            let radius = point.point.x < 1e-6 ? 0 : point.point.x
            rings.append((0...segments).map { j in
                let (c, s) = turn(j, segments)
                return g.add(SIMD3(radius * c, point.point.y, -radius * s), SIMD3(point.normal.x * c, point.normal.y, -point.normal.x * s),
                             SIMD2(Float(j) / Float(segments), travelled[index] / total))
            })
        }
        for i in 0..<(rings.count - 1) {
            for j in 0..<segments { g.quad(rings[i][j], rings[i][j + 1], rings[i + 1][j + 1], rings[i + 1][j]) }
        }
        return g
    }

    /// The cosine and sine of step `j` of `segments` round; the last step is exactly the first, so
    /// a seam closes on the same numbers.
    static func turn(_ j: Int, _ segments: Int) -> (Float, Float) {
        let angle = Float(j % segments) * 2 * .pi / Float(segments)
        return (cos(angle), sin(angle))
    }

    /// Straight segments; corners turning less than `smooth` degrees are shaded round.
    static func polyline(_ points: [SIMD2<Float>], smooth: Float = 0) -> [ProfilePoint] {
        var corners: [SIMD2<Float>] = []
        for point in points where corners.last.map({ simd_distance($0, point) > 1e-7 }) ?? true { corners.append(point) }
        guard corners.count >= 2 else { return [] }
        let normals = (0..<(corners.count - 1)).map { k -> SIMD2<Float> in
            let d = simd_normalize(corners[k + 1] - corners[k])
            return SIMD2(d.y, -d.x)
        }
        let limit = cos(smooth * .pi / 180)
        func blend(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> { smooth > 0 && simd_dot(a, b) > limit ? simd_normalize(a + b) : b }
        var profile: [ProfilePoint] = []
        for k in normals.indices {
            let start = k > 0 ? blend(normals[k - 1], normals[k]) : normals[k]
            let end = k + 1 < normals.count ? blend(normals[k + 1], normals[k]) : normals[k]
            profile.append(ProfilePoint(point: corners[k], normal: start))
            profile.append(ProfilePoint(point: corners[k + 1], normal: end))
        }
        return profile
    }

    /// An elliptical arc, anticlockwise from `from` to `to` (radians), its normals pointing away from the centre.
    static func arc(centre: SIMD2<Float>, radii: SIMD2<Float>, from: Float, to: Float, steps: Int) -> [ProfilePoint] {
        (0...steps).map { k in
            let a = from + (to - from) * Float(k) / Float(steps)
            return ProfilePoint(point: centre + radii * SIMD2(cos(a), sin(a)), normal: simd_normalize(SIMD2(cos(a) / radii.x, sin(a) / radii.y)))
        }
    }

    /// The profile of a ring (a race, a rim, a tube), its four edges chamfered.
    static func ring(inner: Float, outer: Float, height: Float, chamfer c: Float) -> [ProfilePoint] {
        let h = height / 2
        return polyline([[inner + c, -h], [outer - c, -h], [outer, -h + c], [outer, h - c], [outer - c, h], [inner + c, h], [inner, h - c], [inner, -h + c], [inner + c, -h]])
    }

    // MARK: Rounded box

    /// A box whose edges and corners are rounded by `corner`: each face a grid, pushed out onto the
    /// rounding so the faces meet edge to edge.
    static func roundedBox(_ size: SIMD3<Float>, corner: Float) -> CookieGeometry {
        let h = size / 2
        let r = max(0, min(corner, h.min() * 0.999))
        func coordinates(_ half: Float) -> [Float] {
            guard r > 1e-6 else { return [-half, half] }
            let steps = 4
            return (0...steps).map { -half + r * Float($0) / Float(steps) } + (0...steps).map { half - r + r * Float($0) / Float(steps) }
        }
        let axes = [coordinates(h.x), coordinates(h.y), coordinates(h.z)]
        var g = CookieGeometry()
        for k in 0..<3 {
            let u = (k + 1) % 3, v = (k + 2) % 3
            for sign: Float in [1, -1] {
                var face = SIMD3<Float>.zero
                face[k] = sign
                let cu = axes[u], cv = axes[v]
                var grid: [[UInt32]] = []
                for (i, a) in cu.enumerated() {
                    grid.append(cv.enumerated().map { j, b in
                        var p = SIMD3<Float>.zero
                        p[k] = sign * h[k]; p[u] = a; p[v] = b
                        let uv = SIMD2(Float(i) / Float(cu.count - 1), Float(j) / Float(cv.count - 1))
                        guard r > 1e-6 else { return g.add(p, face, uv) }
                        let inner = simd_clamp(p, -(h - r), h - r)
                        let normal = simd_normalize(p - inner)
                        return g.add(inner + normal * r, normal, uv)
                    })
                }
                for i in 0..<(cu.count - 1) {
                    for j in 0..<(cv.count - 1) {
                        if sign > 0 { g.quad(grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]) }
                        else { g.quad(grid[i][j], grid[i][j + 1], grid[i + 1][j + 1], grid[i + 1][j]) }
                    }
                }
            }
        }
        return g
    }

    // MARK: Extrusion

    /// Front (+z) and back (−z) faces from triangles over `points`; the front is scaled by `taper`.
    static func caps(_ points: [SIMD2<Float>], _ triangles: [UInt32], depth: Float, taper: Float, into g: inout CookieGeometry) {
        guard let first = points.first else { return }
        let low = points.reduce(first) { simd_min($0, $1) }, span = simd_max(points.reduce(first) { simd_max($0, $1) } - low, SIMD2(repeating: 1e-6))
        let front = points.map { g.add(SIMD3($0 * taper, depth / 2), [0, 0, 1], ($0 - low) / span) }
        let back = points.map { g.add(SIMD3($0, -depth / 2), [0, 0, -1], ($0 - low) / span) }
        for t in stride(from: 0, to: triangles.count, by: 3) {
            let a = Int(triangles[t]), b = Int(triangles[t + 1]), c = Int(triangles[t + 2])
            g.triangle(front[a], front[b], front[c])
            g.triangle(back[a], back[c], back[b])
        }
    }

    /// The side walls of a closed outline (anticlockwise for an outside, clockwise for a hole), each
    /// edge its own quad; corners turning less than `smooth` degrees are shaded round.
    static func walls(_ loop: [SIMD2<Float>], depth: Float, taper: Float, smooth: Float, into g: inout CookieGeometry) {
        let n = loop.count
        guard n >= 3 else { return }
        func bottom(_ i: Int) -> SIMD3<Float> { SIMD3(loop[i % n], -depth / 2) }
        func top(_ i: Int) -> SIMD3<Float> { SIMD3(loop[i % n] * taper, depth / 2) }
        let faces = (0..<n).map { i in simd_normalize(simd_cross(bottom(i + 1) - bottom(i), top(i) - bottom(i))) }
        let limit = cos(smooth * .pi / 180)
        var travelled: [Float] = [0]
        for i in 0..<n { travelled.append(travelled[i] + simd_distance(loop[i], loop[(i + 1) % n])) }
        let total = max(travelled[n], 1e-9)
        for i in 0..<n {
            let before = faces[(i + n - 1) % n], after = faces[(i + 1) % n], face = faces[i]
            let start = simd_dot(before, face) > limit ? simd_normalize(before + face) : face
            let end = simd_dot(after, face) > limit ? simd_normalize(after + face) : face
            let u0 = travelled[i] / total, u1 = travelled[i + 1] / total
            g.quad(g.add(bottom(i), start, [u0, 0]), g.add(bottom(i + 1), end, [u1, 0]), g.add(top(i + 1), end, [u1, 1]), g.add(top(i), start, [u0, 1]))
        }
    }

    /// An outline with holes, given depth along z: caps, outside walls, hole walls.
    static func extrusion(_ outline: [SIMD2<Float>], holes: [[SIMD2<Float>]] = [], depth: Float, smooth: Float = 30) -> CookieGeometry {
        var g = CookieGeometry()
        let outer = CookiePolygon.area(outline.map { SIMD3($0, 0) }) < 0 ? Array(outline.reversed()) : outline
        let inner = holes.map { CookiePolygon.area($0.map { SIMD3($0, 0) }) > 0 ? Array($0.reversed()) : $0 }
        caps(outer + inner.flatMap { $0 }, triangulate(outer, holes: inner), depth: depth, taper: 1, into: &g)
        walls(outer, depth: depth, taper: 1, smooth: smooth, into: &g)
        for hole in inner { walls(hole, depth: depth, taper: 1, smooth: smooth, into: &g) }
        return g
    }

    /// Triangles over an anticlockwise outline and its clockwise holes, by clipping ears after
    /// joining each hole to the outline with a bridge. Indices count through `outer` then each hole.
    static func triangulate(_ outer: [SIMD2<Float>], holes: [[SIMD2<Float>]]) -> [UInt32] {
        let points = outer + holes.flatMap { $0 }
        var polygon = Array(outer.indices)
        var starts: [Int] = []
        var offset = outer.count
        for hole in holes { starts.append(offset); offset += hole.count }
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        // Rightmost holes first, each bridged from its rightmost point to the nearest outline corner it can see.
        let order = holes.indices.sorted { (holes[$0].map(\.x).max() ?? 0) > (holes[$1].map(\.x).max() ?? 0) }
        for h in order {
            let hole = holes[h]
            let local = hole.indices.max { hole[$0].x < hole[$1].x }!
            let m = points[starts[h] + local]
            var best: (position: Int, distance: Float)?
            for (position, index) in polygon.enumerated() {
                let candidate = points[index]
                guard candidate.x >= m.x - 1e-7 else { continue }
                let distance = simd_distance_squared(candidate, m)
                guard distance < (best?.distance ?? .infinity) else { continue }
                // Inside the polygon's angle at that corner…
                let previous = points[polygon[(position + polygon.count - 1) % polygon.count]], next = points[polygon[(position + 1) % polygon.count]]
                let convex = cross(previous, candidate, next) >= 0
                let left1 = cross(previous, candidate, m) > 0, left2 = cross(candidate, next, m) > 0
                guard convex ? (left1 && left2) : (left1 || left2) else { continue }
                // …and crossing no edge on the way.
                let blocked = polygon.indices.contains { e in
                    let a = points[polygon[e]], b = points[polygon[(e + 1) % polygon.count]]
                    return a != candidate && b != candidate && CookiePolygon.segmentsCross(SIMD3(m, 0), SIMD3(candidate, 0), SIMD3(a, 0), SIMD3(b, 0))
                }
                if !blocked { best = (position, distance) }
            }
            guard let best else { continue }
            let loop = (0...hole.count).map { starts[h] + (local + $0) % hole.count }
            polygon.insert(contentsOf: loop + [polygon[best.position]], at: best.position + 1)
        }
        var triangles: [UInt32] = []
        var guardCount = polygon.count * polygon.count + 10
        while polygon.count > 3 && guardCount > 0 {
            guardCount -= 1
            var clipped = false
            for i in polygon.indices {
                let ia = polygon[(i + polygon.count - 1) % polygon.count], ib = polygon[i], ic = polygon[(i + 1) % polygon.count]
                let a = points[ia], b = points[ib], c = points[ic]
                guard cross(a, b, c) > 1e-12 else { continue }
                let blocked = polygon.contains { index in
                    let p = points[index]
                    guard p != a && p != b && p != c else { return false }
                    return cross(a, b, p) >= 0 && cross(b, c, p) >= 0 && cross(c, a, p) >= 0
                }
                guard !blocked else { continue }
                triangles += [UInt32(ia), UInt32(ib), UInt32(ic)]
                polygon.remove(at: i)
                clipped = true
                break
            }
            // Only flat or overlapping corners left (rounding): drop the flattest and carry on.
            if !clipped {
                let flattest = polygon.indices.min { i, j in
                    let si = abs(cross(points[polygon[(i + polygon.count - 1) % polygon.count]], points[polygon[i]], points[polygon[(i + 1) % polygon.count]]))
                    let sj = abs(cross(points[polygon[(j + polygon.count - 1) % polygon.count]], points[polygon[j]], points[polygon[(j + 1) % polygon.count]]))
                    return si < sj
                }!
                polygon.remove(at: flattest)
            }
        }
        if polygon.count == 3, cross(points[polygon[0]], points[polygon[1]], points[polygon[2]]) > 0 { triangles += polygon.map(UInt32.init) }
        return triangles
    }

    /// Lying in x–y with depth along z, turned so depth runs along y (round machine parts turn about y).
    static let depthToY = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]))

    // MARK: Toothed shapes

    static func gearOutline(_ form: CookieScene.Form) -> [SIMD2<Float>] {
        let (_, outer, root) = CookieScene.gearRadii(form)
        let pitch = form["radius"], teeth = Int(form["teeth"])
        let tooth: [(Float, Float)] = [(-0.5, root), (-0.4, root), (-0.3, root), (-0.25, pitch), (-0.16, outer), (-0.05, outer),
                                       (0.05, outer), (0.16, outer), (0.25, pitch), (0.3, root), (0.4, root)]
        return (0..<teeth).flatMap { k in
            tooth.map { fraction, radius in
                let angle = (Float(k) + fraction) * 2 * .pi / Float(teeth)
                return SIMD2(cos(angle), sin(angle)) * radius
            }
        }
    }

    /// A spur or bevel gear: the toothed outline round its bore, the face scaled by `taper`.
    static func gear(_ form: CookieScene.Form, taper: Float) -> CookieGeometry {
        let outline = gearOutline(form)
        let n = outline.count, bore = form["bore"]
        var g = CookieGeometry()
        var points = outline, triangles: [UInt32] = []
        if bore > 1e-5 {
            // The outline is star-shaped round the axis, so its face is a ring of quads out to the bore.
            points += outline.map { simd_normalize($0) * bore }
            for i in 0..<n {
                let j = (i + 1) % n
                triangles += [UInt32(i), UInt32(j), UInt32(n + j), UInt32(i), UInt32(n + j), UInt32(n + i)]
            }
        } else {
            points.append(.zero)
            for i in 0..<n { triangles += [UInt32(n), UInt32(i), UInt32((i + 1) % n)] }
        }
        caps(points, triangles, depth: form["thickness"], taper: taper, into: &g)
        walls(outline, depth: form["thickness"], taper: taper, smooth: 25, into: &g)
        if bore > 1e-5 { walls(Array(points[n...].reversed()), depth: form["thickness"], taper: taper, smooth: 25, into: &g) }
        return g.moved(depthToY)
    }

    /// A toothed bar along x, teeth up, depth along z.
    static func rack(_ form: CookieScene.Form) -> CookieGeometry {
        let length = form["length"], height = form["height"], teeth = Int(form["teeth"])
        let (_, depth) = CookieScene.rackTooth(form)
        let pitch = length / Float(teeth), base = height / 2 - depth, crest = height / 2
        var outline: [SIMD2<Float>] = [[-length / 2, -height / 2], [length / 2, -height / 2], [length / 2, base]]
        for k in (0..<teeth).reversed() {
            let x = -length / 2 + Float(k) * pitch
            outline += [[x + 0.85 * pitch, base], [x + 0.65 * pitch, crest], [x + 0.35 * pitch, crest], [x + 0.15 * pitch, base]]
        }
        outline.append([-length / 2, base])
        return extrusion(outline, depth: form["thickness"], smooth: 0)
    }

    // MARK: Turned shapes

    static func shaft(_ form: CookieScene.Form) -> CookieGeometry {
        let sections = [SIMD2(form["radius"], form["length"])] + form.points.map { SIMD2($0.x, $0.y) }
        let total = sections.reduce(0) { $0 + $1.y }
        let chamfer = min(sections.map(\.x).min()! * 0.12, sections.map(\.y).min()! * 0.3)
        var y = -total / 2
        var points: [SIMD2<Float>] = [[0, y], [sections[0].x - chamfer, y], [sections[0].x, y + chamfer]]
        for (index, section) in sections.enumerated() {
            if index > 0 { points.append([section.x, y]) }
            y += section.y
            points.append([section.x, index == sections.count - 1 ? y - chamfer : y])
        }
        points += [[sections.last!.x - chamfer, y], [0, y]]
        return lathe(polyline(points), segments: 40)
    }

    static func bearing(_ form: CookieScene.Form) -> CookieGeometry {
        let outer = form["radius"], inner = form["inner"], width = form["width"]
        let race = (outer - inner) * 0.22, chamfer = min(race, width) * 0.15
        var g = lathe(ring(inner: outer - race, outer: outer, height: width, chamfer: chamfer), segments: around)
        g.append(lathe(ring(inner: inner, outer: inner + race, height: width, chamfer: chamfer), segments: around))
        let ball = min((outer - inner - 2 * race) * 0.525, width * 0.48), middle = (outer + inner) / 2
        let count = Int(form.values["balls"] ?? min(40, max(3, floor(2 * .pi * middle / (2 * ball * 1.15)))))
        let sphere = lathe(arc(centre: .zero, radii: SIMD2(repeating: ball), from: -.pi / 2, to: .pi / 2, steps: 10), segments: 16)
        for k in 0..<count {
            let angle = Float(k) * 2 * .pi / Float(count)
            g.append(sphere, simd_float4x4(translation: [middle * cos(angle), 0, -middle * sin(angle)]))
        }
        return g
    }

    static func piston(_ form: CookieScene.Form) -> CookieGeometry {
        let r = form["radius"], h = form["height"], c = r * 0.05
        let groove = h * 0.045, deep = r * 0.07
        var points: [SIMD2<Float>] = [[0, -h / 2], [r - c, -h / 2], [r, -h / 2 + c]]
        for k in (0..<3).reversed() {
            let top = h / 2 - h * 0.1 - Float(k) * groove * 2.2
            points += [[r, top - groove], [r - deep, top - groove], [r - deep, top], [r, top]]
        }
        points += [[r, h / 2 - c], [r - c, h / 2], [r * 0.6, h / 2], [0, h / 2 - h * 0.03]]
        return lathe(polyline(points, smooth: 8), segments: around)
    }

    static func valve(_ form: CookieScene.Form) -> CookieGeometry {
        let r = form["radius"], l = form["length"], s = form["stem"], bottom = -l / 2
        let seat = SIMD2(r * 0.78, bottom + r * 0.32), neckTop = SIMD2(s, min(bottom + r * 1.4, l / 2 - s * 2.5))
        // The neck flares from the stem into the seat along a curve.
        let control = SIMD2(s, bottom + r * 0.42)
        let neck = (1...8).map { k -> SIMD2<Float> in
            let t = Float(k) / 8
            return (1 - t) * (1 - t) * seat + 2 * (1 - t) * t * control + t * t * neckTop
        }
        let points: [SIMD2<Float>] = [[0, bottom], [r, bottom], [r, bottom + r * 0.1], seat] + neck
            + [[s, l / 2 - s * 1.5], [s * 0.8, l / 2 - s * 1.2], [s * 0.8, l / 2 - s * 0.6], [s, l / 2 - s * 0.5], [s, l / 2], [0, l / 2]]
        return lathe(polyline(points, smooth: 30), segments: 40)
    }

    static func wheel(_ form: CookieScene.Form) -> CookieGeometry {
        let r = form["radius"], w = form["width"], hub = form["hub"], spokes = Int(form["spokes"])
        let tyre = r * 0.2
        var g = lathe(arc(centre: [r - tyre / 2, 0], radii: [tyre / 2, w / 2], from: -.pi, to: .pi, steps: 28), segments: around)
        let rimInner = r - tyre * 1.25
        g.append(lathe(ring(inner: rimInner, outer: r - tyre * 0.9, height: w * 0.75, chamfer: tyre * 0.05), segments: around))
        g.append(lathe(polyline([[0, -w * 0.45], [hub, -w * 0.45], [hub, w * 0.45], [0, w * 0.45]]), segments: 32))
        if spokes == 0 {
            g.append(lathe(polyline([[0, -w * 0.1], [rimInner * 1.02, -w * 0.1], [rimInner * 1.02, w * 0.1], [0, w * 0.1]]), segments: around))
        } else {
            let length = rimInner * 1.02 - hub * 0.8
            let spoke = roundedBox([length, w * 0.25, r * 0.06], corner: 0)
            for k in 0..<spokes {
                let angle = Float(k) * 2 * .pi / Float(spokes)
                g.append(spoke, simd_float4x4(simd_quatf(angle: angle, axis: up)) * simd_float4x4(translation: [hub * 0.8 + length / 2, 0, 0]))
            }
        }
        return g
    }

    static func turned(_ form: CookieScene.Form) -> CookieGeometry {
        var profile = form.points.map { SIMD2($0.x, $0.y) }
        if profile[0].x > 1e-6 { profile.insert([0, profile[0].y], at: 0) }
        if profile[profile.count - 1].x > 1e-6 { profile.append([0, profile[profile.count - 1].y]) }
        // Walked so the solid is on the left (anticlockwise with the axis closing it), whichever way it was written.
        if CookiePolygon.area(profile.map { SIMD3($0, 0) }) < 0 { profile.reverse() }
        return lathe(polyline(profile, smooth: 35), segments: around)
    }

    // MARK: Lofts: blades, springs, pipes, sweeps

    /// A station of a loft: where the section sits and how it's turned (`normal` × `binormal` points
    /// along the loft) and scaled.
    struct Station { var origin: SIMD3<Float>; var normal: SIMD3<Float>; var binormal: SIMD3<Float>; var scale: SIMD2<Float> }

    /// A closed section (anticlockwise in normal–binormal, outward normals) carried through the
    /// stations; `capped` closes both ends.
    static func loft(_ stations: [Station], section: [ProfilePoint], capped: Bool, into g: inout CookieGeometry) {
        let count = section.count
        func place(_ s: Station, _ p: ProfilePoint) -> (SIMD3<Float>, SIMD3<Float>) {
            (s.origin + s.normal * (p.point.x * s.scale.x) + s.binormal * (p.point.y * s.scale.y),
             s.normal * (p.normal.x / s.scale.x) + s.binormal * (p.normal.y / s.scale.y))
        }
        let rings = stations.enumerated().map { k, station in
            section.enumerated().map { i, p in
                let (position, normal) = place(station, p)
                return g.add(position, normal, [Float(i) / Float(max(1, count - 1)), Float(k) / Float(max(1, stations.count - 1))])
            }
        }
        for k in 0..<(stations.count - 1) {
            for i in 0..<(count - 1) { g.quad(rings[k][i], rings[k][i + 1], rings[k + 1][i + 1], rings[k + 1][i]) }
        }
        guard capped, let first = stations.first, let last = stations.last else { return }
        for (station, outward, flip) in [(first, -simd_cross(first.normal, first.binormal), true), (last, simd_cross(last.normal, last.binormal), false)] {
            let centre = g.add(station.origin, outward, [0.5, 0.5])
            let ring = section.map { p in g.add(place(station, p).0, outward, simd_clamp(p.point * 0.5 + 0.5, .zero, .one)) }
            for i in 0..<(count - 1) { flip ? g.triangle(centre, ring[i + 1], ring[i]) : g.triangle(centre, ring[i], ring[i + 1]) }
        }
    }

    /// A unit circle section; `inward` faces it into a bore.
    static func circle(_ steps: Int, inward: Bool = false) -> [ProfilePoint] {
        (0...steps).map { k in
            let (c, s) = turn(inward ? steps - k : k, steps)
            return ProfilePoint(point: [c, s], normal: inward ? [-c, -s] : [c, s])
        }
    }

    /// A unit square section with sharp edges.
    static let square: [ProfilePoint] = {
        let corners: [SIMD2<Float>] = [[1, -1], [1, 1], [-1, 1], [-1, -1]]
        var points: [ProfilePoint] = []
        for k in 0..<4 {
            let a = corners[k], b = corners[(k + 1) % 4]
            let normal = simd_normalize(SIMD2((a + b).x, (a + b).y))
            points += [ProfilePoint(point: a, normal: normal), ProfilePoint(point: b, normal: normal)]
        }
        return points + [points[0]]
    }()

    /// Frames along a path that twist as little as possible (parallel transport).
    static func stations(along path: [SIMD3<Float>], scale: SIMD2<Float>) -> [Station] {
        guard path.count >= 2 else { return [] }
        let tangents = path.indices.map { k in simd_normalize(path[min(k + 1, path.count - 1)] - path[max(k - 1, 0)]) }
        let t0 = tangents[0]
        let seed: SIMD3<Float> = abs(t0.x) < 0.9 ? [1, 0, 0] : [0, 1, 0]
        var normal = simd_normalize(seed - t0 * simd_dot(seed, t0))
        var stations: [Station] = []
        for k in path.indices {
            if k > 0 {
                normal = simd_quatf(from: tangents[k - 1], to: tangents[k]).act(normal)
                normal = simd_normalize(normal - tangents[k] * simd_dot(normal, tangents[k]))
            }
            stations.append(Station(origin: path[k], normal: normal, binormal: simd_cross(tangents[k], normal), scale: scale))
        }
        return stations
    }

    /// A path with each corner rounded by an arc of radius `bend` (smaller where the legs are short).
    static func rounded(_ path: [SIMD3<Float>], bend: Float) -> [SIMD3<Float>] {
        guard path.count > 2 else { return path }
        var points = [path[0]]
        for k in 1..<(path.count - 1) {
            let before = path[k] - path[k - 1], after = path[k + 1] - path[k]
            let d1 = simd_normalize(before), d2 = simd_normalize(after)
            let angle = acos(min(1, max(-1, simd_dot(d1, d2))))
            guard angle > 1e-3, angle < .pi - 1e-3 else { points.append(path[k]); continue }
            let reach = min(bend * tan(angle / 2), simd_length(before) / 2, simd_length(after) / 2)
            let radius = reach / tan(angle / 2)
            let start = path[k] - d1 * reach, end = path[k] + d2 * reach
            let centre = path[k] + simd_normalize(d2 - d1) * (radius / cos(angle / 2))
            let from = simd_normalize(start - centre), to = simd_normalize(end - centre)
            let steps = max(2, Int(angle / (.pi / 16)))
            for s in 0...steps { points.append(centre + slerp(from, to, Float(s) / Float(steps)) * radius) }
        }
        points.append(path[path.count - 1])
        // Arc ends that land on the leg ends would repeat a point.
        var kept: [SIMD3<Float>] = []
        for point in points where kept.last.map({ simd_distance($0, point) > 1e-6 }) ?? true { kept.append(point) }
        return kept
    }

    private static func slerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        let angle = acos(min(1, max(-1, simd_dot(a, b))))
        guard angle > 1e-5 else { return a }
        return (sin((1 - t) * angle) * a + sin(t * angle) * b) / sin(angle)
    }

    static func spring(_ form: CookieScene.Form) -> CookieGeometry {
        let r = form["radius"], l = form["length"], coils = form["coils"]
        let steps = Int(coils) * 28
        let path = (0...steps).map { k -> SIMD3<Float> in
            let t = Float(k) / Float(steps), angle = t * coils * 2 * .pi
            return [r * cos(angle), -l / 2 + l * t, -r * sin(angle)]
        }
        var g = CookieGeometry()
        loft(stations(along: path, scale: SIMD2(repeating: form["wire"])), section: circle(14), capped: true, into: &g)
        return g
    }

    /// A hollow pipe along its path: outside, bore and the two end rings.
    static func pipe(_ form: CookieScene.Form) -> CookieGeometry {
        let path = rounded(form.points, bend: form["bend"])
        let outer = form["radius"], inner = outer * 0.82, steps = 20
        let frames = stations(along: path, scale: SIMD2(repeating: outer))
        var g = CookieGeometry()
        loft(frames, section: circle(steps), capped: false, into: &g)
        loft(frames.map { var s = $0; s.scale = SIMD2(repeating: inner); return s }, section: circle(steps, inward: true), capped: false, into: &g)
        for (station, front) in [(frames[0], false), (frames[frames.count - 1], true)] {
            let outward = simd_cross(station.normal, station.binormal) * (front ? 1 : -1)
            func point(_ k: Int, _ radius: Float) -> UInt32 {
                let (c, s) = turn(k, steps)
                return g.add(station.origin + (station.normal * c + station.binormal * s) * radius, outward, [Float(k) / Float(steps), radius == outer ? 1 : 0])
            }
            for k in 0..<steps {
                let o0 = point(k, outer), o1 = point(k + 1, outer), i0 = point(k, inner), i1 = point(k + 1, inner)
                front ? g.quad(o0, o1, i1, i0) : g.quad(i0, i1, o1, o0)
            }
        }
        return g
    }

    static func swept(_ form: CookieScene.Form) -> CookieGeometry {
        let rect = form.values["width"].map { SIMD2($0 / 2, (form.values["height"] ?? $0) / 2) }
        let half = rect.map { simd_length($0) } ?? form["radius"]
        var g = CookieGeometry()
        loft(stations(along: rounded(form.points, bend: half * 1.2), scale: rect ?? SIMD2(repeating: form["radius"])),
             section: rect == nil ? circle(20) : square, capped: true, into: &g)
        return g
    }

    /// Blades out along +x from `from` to `to`, `count` of them round y. `angle(r)` is the blade's
    /// pitch from the plane of turning (radians), `chord(r)` its width, `thick` its thickness over chord.
    static func blades(_ count: Int, from: Float, to: Float, angle: (Float) -> Float, chord: (Float) -> Float, thick: Float) -> CookieGeometry {
        let stations = (0...8).map { k -> Station in
            let r = from + (to - from) * Float(k) / 8, beta = angle(r), c = chord(r)
            let along = SIMD3<Float>(0, sin(beta), cos(beta)), across = SIMD3<Float>(0, cos(beta), -sin(beta))
            // across × along points out along +x, so the section winds the right way.
            return Station(origin: [r, 0, 0], normal: across, binormal: along, scale: SIMD2(max(c * thick, 1e-4) / 2, c / 2))
        }
        var blade = CookieGeometry()
        loft(stations, section: circle(14), capped: true, into: &blade)
        var g = CookieGeometry()
        for k in 0..<count { g.append(blade, simd_float4x4(simd_quatf(angle: Float(k) * 2 * .pi / Float(count), axis: up))) }
        return g
    }

    static func bladeRing(_ form: CookieScene.Form) -> CookieGeometry {
        let tip = form["tip"], hub = form["hub"], depth = form["thickness"], count = Int(form["blades"])
        let rootAngle: Float = 55 * .pi / 180, tipAngle = min(85, max(5, 55 - form["twist"])) * .pi / 180
        var g = lathe(polyline([[0, -depth * 0.6], [hub, -depth * 0.6], [hub, depth * 0.6], [0, depth * 0.6]]), segments: around)
        let start = hub * 0.85
        func beta(_ r: Float) -> Float { rootAngle + (tipAngle - rootAngle) * (r - start) / max(tip - start, 1e-6) }
        g.append(blades(count, from: start, to: tip, angle: beta, chord: { r in
            let b = beta(r)
            // As deep as the ring along its axis, and no wider round it than its share of the circle.
            return min(depth / (sin(b) + 0.12 * cos(b)), 0.6 * r / (cos(b) + 0.12 * sin(b)), 1.3 * 2 * .pi * r / Float(count) / max(cos(b), 0.05))
        }, thick: 0.12))
        return g
    }

    static func propeller(_ form: CookieScene.Form) -> CookieGeometry {
        let radius = form["radius"], hub = form["hub"], count = Int(form["blades"])
        var g = lathe(polyline([[0, -hub * 0.8], [hub, -hub * 0.8], [hub, 0]])
                      + arc(centre: .zero, radii: [hub, hub * 1.8], from: 0, to: .pi / 2, steps: 12), segments: 32)
        let start = hub * 0.7, pitch = tan(form["pitch"] * .pi / 180) * 0.7 * radius
        func beta(_ r: Float) -> Float { min(80 * .pi / 180, max(3 * .pi / 180, atan(pitch / max(r, 1e-5)))) }
        g.append(blades(count, from: start, to: radius, angle: beta, chord: { r in
            let t = (r - start) / max(radius - start, 1e-6), b = beta(r)
            let c = radius * 0.24 * (1 - 0.65 * t * t)
            return min(c, radius * 0.22 / (sin(b) + 0.1 * cos(b)), 0.6 * r / (cos(b) + 0.1 * sin(b)))
        }, thick: 0.1))
        return g
    }

    // MARK: Plates and links

    /// The outline round two circles (their convex hull), anticlockwise.
    static func hull(_ circles: [(centre: SIMD2<Float>, radius: Float)], steps: Int = 32) -> [SIMD2<Float>] {
        var points = circles.flatMap { circle in (0..<steps).map { k -> SIMD2<Float> in
            let (c, s) = turn(k, steps)
            return circle.centre + SIMD2(c, s) * circle.radius
        } }
        points.sort { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [SIMD2<Float>] = [], upper: [SIMD2<Float>] = []
        for p in points {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 1e-12 { lower.removeLast() }
            lower.append(p)
        }
        for p in points.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 1e-12 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// A crank: a web from the main journal (on the axis, y) out to the crankpin at `throw` along x.
    static func crank(_ form: CookieScene.Form) -> CookieGeometry {
        let r = form["radius"], t = form["thickness"], reach = form["throw"]
        let web = hull([(.zero, r * 1.7), ([reach, 0], r * 1.35)])
        var g = CookieGeometry()
        caps(web, (1..<(web.count - 1)).flatMap { [0, UInt32($0), UInt32($0 + 1)] }, depth: t, taper: 1, into: &g)
        walls(web, depth: t, taper: 1, smooth: 30, into: &g)
        let alongZ = simd_float4x4(simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
        let journal = lathe(polyline([[0, -t * 0.75], [r, -t * 0.75], [r, t * 0.75], [0, t * 0.75]]), segments: 32)
        let pin = lathe(polyline([[0, -t * 0.75], [r * 0.85, -t * 0.75], [r * 0.85, t * 0.75], [0, t * 0.75]]), segments: 32)
        g.append(journal, simd_float4x4(translation: [0, 0, -t * 1.25]) * alongZ)
        g.append(pin, simd_float4x4(translation: [reach, 0, t * 1.25]) * alongZ)
        return g.moved(depthToY)
    }

    /// A connecting rod in x–y: the big end at −y, the small end at +y, an eye through each.
    static func rod(_ form: CookieScene.Form) -> CookieGeometry {
        let l = form["length"], big = form["radius"], small = form["small"]
        let outline = hull([([0, -l / 2], big), ([0, l / 2], small)])
        let eye = { (centre: SIMD2<Float>, radius: Float) in (0..<20).map { k -> SIMD2<Float> in
            let (c, s) = turn(20 - k, 20)
            return centre + SIMD2(c, s) * radius * 0.55
        } }
        return extrusion(outline, holes: [eye([0, -l / 2], big), eye([0, l / 2], small)], depth: form["thickness"])
    }

    static func extruded(_ form: CookieScene.Form) -> CookieGeometry {
        extrusion(form.points.map { SIMD2($0.x, $0.y) }, holes: form.holes.map { $0.map { SIMD2($0.x, $0.y) } }, depth: form["depth"])
    }

    // MARK: Screw

    /// A threaded screw along y: a pointed tip, a V thread round a core, a domed head.
    static func screw(_ form: CookieScene.Form) -> CookieGeometry {
        let r = form["radius"], l = form["length"], pitch = form["pitch"], head = form["head"]
        let core = r * 0.72, segments = 32
        let tipTop = -l / 2 + min(r * 1.2, l * 0.2), headHeight = min(head * 0.6, l * 0.25), threadTop = l / 2 - headHeight
        var g = lathe(polyline([[0, -l / 2], [core, tipTop]]), segments: segments)
        // The thread fades in and out over a pitch at each end, so it meets the tip and head exactly at the core.
        func radius(_ angle: Float, _ y: Float) -> Float {
            let phase = (y - tipTop) / pitch - angle / (2 * .pi)
            let v = 1 - abs(2 * (phase - floor(phase)) - 1)
            let fade = min(1, max(0, (y - tipTop) / pitch), max(0, (threadTop - y) / pitch))
            return core + (r - core) * v * fade * fade * (3 - 2 * fade)
        }
        func point(_ angle: Float, _ c: Float, _ s: Float, _ y: Float) -> SIMD3<Float> { let rr = radius(angle, y); return [rr * c, y, -rr * s] }
        let rows = min(600, max(8, Int(((threadTop - tipTop) / pitch * 12).rounded(.up))))
        var grid: [[UInt32]] = []
        for i in 0...rows {
            let y = i == rows ? threadTop : tipTop + (threadTop - tipTop) * Float(i) / Float(rows)
            grid.append((0...segments).map { j in
                let (c, s) = turn(j, segments), angle = Float(j % segments) * 2 * .pi / Float(segments)
                let e: Float = 1e-3
                let (cp, sp) = (cos(angle + e), sin(angle + e)), (cm, sm) = (cos(angle - e), sin(angle - e))
                let dy = (threadTop - tipTop) / Float(rows) * 0.5
                let du = point(angle + e, cp, sp, y) - point(angle - e, cm, sm, y)
                let dv = point(angle, c, s, y + dy) - point(angle, c, s, y - dy)
                return g.add(point(angle, c, s, y), simd_cross(du, dv), [Float(j) / Float(segments), Float(i) / Float(rows)])
            })
        }
        for i in 0..<rows { for j in 0..<segments { g.quad(grid[i][j], grid[i][j + 1], grid[i + 1][j + 1], grid[i + 1][j]) } }
        g.append(lathe(polyline([[core, threadTop], [head, threadTop], [head, threadTop + headHeight * 0.45]])
                       + arc(centre: [0, threadTop + headHeight * 0.45], radii: [head, headHeight * 0.55], from: 0, to: .pi / 2, steps: 10), segments: segments))
        return g
    }
}

extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t, 1)
    }
}

/// RealityKit meshes for scene parts, made once per shape and kept; warmed off the main thread.
@MainActor
enum CookieMeshResources {
    private static var meshes: [CookieScene.Form: MeshResource] = [:]
    static let limit = 128

    static func cached(_ form: CookieScene.Form) -> MeshResource? { meshes[form] }

    /// The part's mesh: from the cache, else made now (the geometry may already be warm).
    static func mesh(_ form: CookieScene.Form) -> MeshResource {
        if let mesh = meshes[form] { return mesh }
        let geometry = CookieMeshes.geometry(form)
        let mesh: MeshResource
        if let made = try? MeshResource.generate(from: [geometry.descriptor]) {
            mesh = made
        } else {
            // Never seen in practice; a plain box of the part's size beats a hole in the model.
            let box = form.bounds
            mesh = .generateBox(size: simd_max(box.max - box.min, SIMD3(repeating: CookieScene.minSize)))
        }
        store(mesh, for: form)
        return mesh
    }

    private static func store(_ mesh: MeshResource, for form: CookieScene.Form) {
        if meshes.count >= limit { meshes.removeAll() }
        meshes[form] = mesh
    }

    /// Draws and uploads every part of the scene off the main thread, so showing it is instant.
    @discardableResult
    static func warm(_ scene: CookieScene) -> Task<Void, Never> {
        let forms = Array(Set(scene.parts.map(\.form))).filter { meshes[$0] == nil }
        return Task.detached(priority: .userInitiated) {
            for form in forms {
                if Task.isCancelled { return }
                let descriptor = CookieMeshes.geometry(form).descriptor
                guard let mesh = try? await MeshResource(from: [descriptor]) else { continue }
                await MainActor.run { if meshes[form] == nil { store(mesh, for: form) } }
            }
        }
    }
}
