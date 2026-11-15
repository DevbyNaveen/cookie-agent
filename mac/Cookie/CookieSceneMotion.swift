//
//  CookieSceneMotion.swift
//  Cookie
//
//  How a 3D model works in front of you. A scene may say what moves:
//  joints turn a part (or a group) about an axis, slide it back and forth, or
//  turn a crank; drives pass one joint's turning to another at a ratio (a gear
//  train, a belt); links tie a crank, a rod and a piston together and are
//  solved exactly each frame, so the rod's ends stay on the crankpin and the
//  piston pin; flows run small beads along a smooth path through named parts,
//  for air, fuel, blood or current. All of it is kinematics, never physics:
//  Cookie doesn't simulate fluid, and a flow is an illustration of the route.
//
//  The motion is read with the scene's forgiving reader (repairs and errors
//  named by field), worked out here from numbers alone, and shared by the stage
//  that draws it and the build check that samples a cycle before it's shown.
//
//  Also here: the camera rig, the spring-driven eye that frames a part, a
//  preset view or the whole model, and lets the person take over.
//

import Foundation
import simd

extension CookieScene {
    /// Something that moves parts: a turn about an axis, a back-and-forth slide, or a crank's turn.
    struct Joint: Equatable {
        enum Kind: String, CaseIterable { case spin, slide, crank }
        let id: String
        let kind: Kind
        /// The part or group it was given.
        let part: String
        /// Every part it moves, in scene order.
        let members: [String]
        /// A unit direction in the scene's own coordinates.
        let axis: SIMD3<Float>
        /// The point the axis passes through.
        let pivot: SIMD3<Float>
        /// Turns a second (spin, crank) or strokes a second (slide); negative runs the other way.
        /// A driven joint's rate comes from its driver.
        let rate: Float
        /// A slide's whole stroke, end to end.
        let travel: Float
    }

    /// One joint turning another: `to` turns `ratio` times for each turn of `from` (negative: the
    /// other way, as meshing gears do).
    struct Drive: Equatable {
        let from: String
        let to: String
        let ratio: Float
    }

    /// A slider-crank: the crank's joint turns the crankpin, the rod joins the pin to the piston,
    /// the piston slides along the line from the crank's axis out through where it was placed.
    struct Link: Equatable {
        let crank: String
        /// The joint that turns the crank.
        let joint: String
        let rod: String
        let piston: String
        /// The cylinder the piston runs in, when one was named or found (`CookieSceneCheck` uses it).
        let cylinder: String?
        /// The crankpin with the crank unturned, scene coordinates.
        let pin: SIMD3<Float>
        /// Where the piston's line crosses the crank's axis (at the piston's height along it).
        let origin: SIMD3<Float>
        /// The piston's line, a unit direction across the axis.
        let direction: SIMD3<Float>
        /// Eye to eye, the rod's length.
        let length: Float
    }

    /// Beads along a path through named parts' middles.
    struct Flow: Equatable {
        let id: String
        /// Parts or groups, in order.
        let through: [String]
        let tint: Tint
        /// Metres a second along the path.
        let speed: Float
        /// Beads a metre.
        let density: Float
        /// How far round the path the beads spread (a stream, not a string); 0 is a single file.
        let spread: Float
        /// The path closes back on its start (a circuit, the blood's loop).
        let loop: Bool
        /// Showing when the model appears.
        let on: Bool
    }

    static let maxJoints = 16
    static let maxDrives = 16
    static let maxLinks = 8
    static let maxFlows = 6
    /// Beads across every flow at once; each flow at most `maxBeadsPerFlow`.
    static let maxBeads = 240
    static let maxBeadsPerFlow = 120
    static let rates: ClosedRange<Float> = -3...3
    static let ratios: ClosedRange<Float> = -20...20
    static let defaultRate: Float = 0.5

    var moves: Bool { !joints.isEmpty || !links.isEmpty }
    var hasMotion: Bool { moves || !flows.isEmpty }

    /// The parts a part id or group name stands for (an id wins over a group of the same name).
    func parts(named name: String) -> [Part] {
        if let part = parts.first(where: { $0.id == name }) { return [part] }
        return parts.filter { $0.group == name }
    }

    /// A part id or group name written loosely ("Fan", "the_spool"): the name it means, or nil.
    func resolve(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !parts(named: trimmed).isEmpty { return trimmed }
        let folded = Self.fold(trimmed)
        guard !folded.isEmpty else { return nil }
        if let part = parts.first(where: { Self.fold($0.id) == folded }) { return part.id }
        return parts.lazy.compactMap(\.group).first { Self.fold($0) == folded }
    }

    /// The middle of what a name stands for, in scene coordinates.
    func centre(of name: String) -> SIMD3<Float> {
        let named = parts(named: name)
        guard !named.isEmpty else { return .zero }
        return named.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(named.count)
    }
}

// MARK: - Reading

extension SceneReader {
    typealias Motion = (joints: [Scene.Joint], drives: [Scene.Drive], links: [Scene.Link], flows: [Scene.Flow])

    /// The scene's joints, drives, links and flows, read against the parts that were built.
    mutating func motion(_ fields: [String: Any], parts: [Scene.Part]) -> Motion {
        let shell = Scene(title: "", parts: parts, explode: false, spin: false)
        var joints = readJoints(fields["joints"], shell)
        let drives = readDrives(fields["drives"], shell, joints: &joints)
        let links = readLinks(fields["links"], shell, joints: joints)
        let flows = readFlows(fields["flows"], shell)
        return (joints, drives, links, flows)
    }

    private mutating func list(_ raw: Any?, _ field: String, limit: Int) -> [[String: Any]?] {
        guard let raw else { return [] }
        guard let items = raw as? [Any] else { errors.append("scene.\(field): must be a list of objects; left out"); return [] }
        if items.count > limit { errors.append("scene.\(field): \(items.count) given, past the limit of \(limit); the rest left out") }
        return items.prefix(limit).map { $0 as? [String: Any] }
    }

    private mutating func ignoreOthers(_ raw: [String: Any], _ known: Set<String>, at: String) {
        for key in raw.keys.sorted() where !known.contains(key) { repairs.append("\(at).\(key): not a field here; ignored") }
    }

    private mutating func uniqueID(_ raw: Any?, fallback: String, taken: Set<String>, at: String) -> String {
        var id = text(raw)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if id.isEmpty { id = fallback; repairs.append("\(at).id: missing; named it \(id)") }
        id = shortened(id, to: Scene.labelLength, at: "\(at).id")
        if taken.contains(id) {
            var number = 2
            while taken.contains("\(id)-\(number)") { number += 1 }
            repairs.append("\(at).id: \(id) used twice; renamed this one \(id)-\(number)")
            id = "\(id)-\(number)"
        }
        return id
    }

    /// A part or group by name, loosely; an error naming what exists when there's no such thing.
    private mutating func named(_ raw: Any?, in scene: Scene, at: String) -> String? {
        guard let given = text(raw)?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty else {
            errors.append("\(at): missing; name a part or group"); return nil
        }
        guard let name = scene.resolve(given) else {
            let known = scene.parts.map(\.id).prefix(12).joined(separator: ", ")
            errors.append("\(at): \"\(given)\" isn't a part or group (parts: \(known))"); return nil
        }
        if name != given { repairs.append("\(at): \"\(given)\" read as \(name)") }
        return name
    }

    private func vectorText(_ v: SIMD3<Float>) -> String { "[\(format(v.x)), \(format(v.y)), \(format(v.z))]" }

    /// A finite number within a range, or the fallback when it's left out (silently: it's optional).
    private mutating func amount(_ raw: Any?, at: String, range: ClosedRange<Float>, fallback: Float) -> Float? {
        guard let raw else { return fallback }
        guard let value = number(raw, at: at) else { return nil }
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        if clamped != value { repairs.append("\(at): \(format(value)) is outside \(format(range.lowerBound))–\(format(range.upperBound)); used \(format(clamped))") }
        return clamped
    }

    // MARK: Joints

    private mutating func readJoints(_ raw: Any?, _ scene: Scene) -> [Scene.Joint] {
        var joints: [Scene.Joint] = []
        var moved: [String: String] = [:]
        for (index, item) in list(raw, "joints", limit: Scene.maxJoints).enumerated() {
            guard let item else { errors.append("joints[\(index)]: must be an object; left out"); continue }
            let id = uniqueID(item["id"], fallback: "joint\(index + 1)", taken: Set(joints.map(\.id)), at: "joints[\(index)]")
            let at = "joints.\(id)"
            ignoreOthers(item, ["id", "kind", "type", "part", "parts", "group", "axis", "rate", "at", "pivot", "travel"], at: at)
            guard let part = named(item["part"] ?? item["group"] ?? item["parts"], in: scene, at: "\(at).part") else { continue }
            let members = scene.parts(named: part)

            let kind: Scene.Joint.Kind
            if let given = text(item["kind"] ?? item["type"])?.trimmingCharacters(in: .whitespaces), !given.isEmpty {
                let aliases: [String: Scene.Joint.Kind] = ["rotate": .spin, "turn": .spin, "revolve": .spin, "revolute": .spin, "hinge": .spin,
                                                           "rotation": .spin, "slider": .slide, "translate": .slide, "linear": .slide,
                                                           "prismatic": .slide, "reciprocate": .slide, "crankshaft": .crank]
                guard let read = Scene.Joint.Kind(rawValue: Scene.fold(given)) ?? aliases[Scene.fold(given)] else {
                    errors.append("\(at).kind: \"\(given)\" isn't spin, slide or crank; left out"); continue
                }
                if read.rawValue != given { repairs.append("\(at).kind: \"\(given)\" read as \(read.rawValue)") }
                kind = read
            } else {
                kind = members.count == 1 && members[0].shape == .crank ? .crank : .spin
                repairs.append("\(at).kind: missing; used \(kind.rawValue)")
            }

            if let taken = members.first(where: { moved[$0.id] != nil }) {
                errors.append("\(at).part: \(taken.id) is already moved by \(moved[taken.id]!); a part has one joint; left out"); continue
            }

            // The axis: given, else the part's own (round parts turn about their y).
            let own = simd_normalize(members[0].orientation.act(SIMD3<Float>(0, 1, 0)))
            var axis = own
            if let given = item["axis"] {
                guard let read = vector(given, at: "\(at).axis", range: -Scene.maxExtent...Scene.maxExtent, missing: nil) else { continue }
                guard simd_length(read) > 1e-4 else { errors.append("\(at).axis: zero length; give a direction such as [1,0,0]; left out"); continue }
                axis = simd_normalize(read)
            } else {
                repairs.append("\(at).axis: missing; used \(members[0].id)'s own axis \(vectorText(own.rounded3))")
            }
            var pivot = scene.centre(of: part)
            if let given = item["at"] ?? item["pivot"] {
                guard let read = vector(given, at: "\(at).at", range: -Scene.maxExtent...Scene.maxExtent, missing: nil) else { continue }
                pivot = read
            }
            guard var rate = amount(item["rate"], at: "\(at).rate", range: Scene.rates, fallback: Scene.defaultRate) else { continue }
            if rate == 0 { rate = Scene.defaultRate; repairs.append("\(at).rate: 0 doesn't move; used \(format(rate))") }
            var travel: Float = 0
            if kind == .slide {
                let reach = members.map(\.reach).max() ?? 0.1
                guard let read = amount(item["travel"], at: "\(at).travel", range: Scene.minSize...Scene.maxExtent, fallback: max(0.05, reach)) else { continue }
                travel = read
            } else if item["travel"] != nil {
                repairs.append("\(at).travel: only a slide travels; ignored")
            }
            for member in members { moved[member.id] = id }
            joints.append(.init(id: id, kind: kind, part: part, members: members.map(\.id), axis: axis, pivot: pivot, rate: rate, travel: travel))
        }
        return joints
    }

    // MARK: Drives

    private mutating func readDrives(_ raw: Any?, _ scene: Scene, joints: inout [Scene.Joint]) -> [Scene.Drive] {
        var drives: [Scene.Drive] = []
        func joint(for name: String) -> Int? {
            joints.firstIndex { $0.id == name } ?? joints.firstIndex { $0.part == name } ?? {
                let members = Set(scene.parts(named: name).map(\.id))
                return joints.firstIndex { !members.isDisjoint(with: $0.members) }
            }()
        }
        for (index, item) in list(raw, "drives", limit: Scene.maxDrives).enumerated() {
            let at = "drives[\(index)]"
            guard let item else { errors.append("\(at): must be an object; left out"); continue }
            ignoreOthers(item, ["from", "to", "ratio"], at: at)
            guard let fromName = text(item["from"])?.trimmingCharacters(in: .whitespaces), !fromName.isEmpty else {
                errors.append("\(at).from: missing; name the joint (or its part) that drives"); continue
            }
            let fromPart = joints.contains(where: { $0.id == fromName }) ? fromName : scene.resolve(fromName)
            guard let fromPart, let from = joint(for: fromPart) else {
                errors.append("\(at).from: \"\(fromName)\" has no joint to drive from; give it a joint first; left out"); continue
            }
            guard let toName = text(item["to"])?.trimmingCharacters(in: .whitespaces), !toName.isEmpty else {
                errors.append("\(at).to: missing; name the joint (or part) it drives"); continue
            }
            let toPart = joints.contains(where: { $0.id == toName }) ? toName : scene.resolve(toName)
            guard let toPart else { errors.append("\(at).to: \"\(toName)\" isn't a joint, part or group; left out"); continue }
            var to = joint(for: toPart)
            if to == nil {
                // A driven part with no joint of its own turns about its own middle, parallel to its driver.
                let driver = joints[from]
                let members = scene.parts(named: toPart).map(\.id)
                let id = joints.contains(where: { $0.id == toPart }) ? "\(toPart)-driven" : toPart
                joints.append(.init(id: id, kind: driver.kind == .slide ? .slide : .spin, part: toPart, members: members,
                                    axis: driver.axis, pivot: scene.centre(of: toPart), rate: driver.rate, travel: driver.travel))
                repairs.append("\(at).to: \(toPart) had no joint; it turns about its own middle, parallel to \(driver.id)")
                to = joints.count - 1
            }
            let a = joints[from], b = joints[to!]
            guard a.id != b.id else { errors.append("\(at): \(a.id) can't drive itself; left out"); continue }
            if let earlier = drives.first(where: { $0.to == b.id }) {
                errors.append("\(at).to: \(b.id) is already driven by \(earlier.from); a joint has one driver; left out"); continue
            }
            // b → … → a already would make a loop.
            var reach: Set<String> = [b.id], frontier = [b.id]
            while let next = frontier.popLast() {
                for drive in drives where drive.from == next && reach.insert(drive.to).inserted { frontier.append(drive.to) }
            }
            if reach.contains(a.id) { errors.append("\(at): \(a.id) → \(b.id) closes a loop of drives; left out"); continue }

            let ratio: Float
            if let given = item["ratio"] {
                guard let read = amount(given, at: "\(at).ratio", range: Scene.ratios, fallback: 1) else { continue }
                if read == 0 { errors.append("\(at).ratio: 0 never turns \(b.id); left out"); continue }
                ratio = read
            } else if let teeth = Self.teeth(scene, a.part, b.part) {
                ratio = -teeth.0 / teeth.1
                repairs.append("\(at).ratio: missing; used \(format(ratio)) from the teeth (\(format(teeth.0)) to \(format(teeth.1)), meshing gears turn opposite ways)")
            } else {
                ratio = 1
                repairs.append("\(at).ratio: missing; used 1")
            }
            drives.append(.init(from: a.id, to: b.id, ratio: ratio))
        }
        return drives
    }

    /// Teeth counts when both names are single gears.
    static func teeth(_ scene: Scene, _ a: String, _ b: String) -> (Float, Float)? {
        let pa = scene.parts(named: a), pb = scene.parts(named: b)
        guard pa.count == 1, pb.count == 1, [.gear, .bevelGear].contains(pa[0].shape), [.gear, .bevelGear].contains(pb[0].shape) else { return nil }
        return (pa[0].form["teeth"], pb[0].form["teeth"])
    }

    // MARK: Links

    private mutating func readLinks(_ raw: Any?, _ scene: Scene, joints: [Scene.Joint]) -> [Scene.Link] {
        var links: [Scene.Link] = []
        for (index, item) in list(raw, "links", limit: Scene.maxLinks).enumerated() {
            let at = "links[\(index)]"
            guard let item else { errors.append("\(at): must be an object; left out"); continue }
            ignoreOthers(item, ["crank", "rod", "piston", "cylinder"], at: at)
            guard let crank = named(item["crank"], in: scene, at: "\(at).crank"),
                  let rod = named(item["rod"], in: scene, at: "\(at).rod"),
                  let piston = named(item["piston"], in: scene, at: "\(at).piston") else { continue }
            guard let crankPart = scene.parts.first(where: { $0.id == crank }), crankPart.shape == .crank else {
                errors.append("\(at).crank: \(crank) must be a crank part (its throw is where the rod hangs); left out"); continue
            }
            guard let joint = joints.first(where: { $0.members.contains(crank) && $0.kind != .slide }) else {
                errors.append("\(at).crank: \(crank) isn't turned by a joint; give it {\"kind\":\"crank\",\"part\":\"\(crank)\"}; left out"); continue
            }
            guard let rodPart = scene.parts.first(where: { $0.id == rod }), rodPart.shape == .rod else {
                errors.append("\(at).rod: \(rod) must be a rod part (its length is eye to eye); left out"); continue
            }
            guard let pistonPart = scene.parts.first(where: { $0.id == piston }) else {
                errors.append("\(at).piston: \(piston) must be one part, not a group; left out"); continue
            }
            if let other = joints.first(where: { $0.members.contains(rod) || $0.members.contains(piston) }) {
                errors.append("\(at): \(other.members.contains(rod) ? rod : piston) is already moved by \(other.id); the link moves it, so give it no joint; left out"); continue
            }
            if let earlier = links.first(where: { [$0.rod, $0.piston].contains(rod) || [$0.rod, $0.piston].contains(piston) }) {
                errors.append("\(at): \(rod) or \(piston) is already in the link from \(earlier.crank); left out"); continue
            }
            let a = joint.axis, o = joint.pivot
            // The crankpin is the stub at the throw, standing off the web (`CookieMeshes.crank`).
            let pin = crankPart.position + crankPart.orientation.act(SIMD3<Float>(crankPart.form["throw"], 1.25 * crankPart.form["thickness"], 0))
            let origin = o + a * simd_dot(pistonPart.position - o, a)
            let out = pistonPart.position - origin
            guard simd_length(out) > Scene.minSize else {
                errors.append("\(at).piston: \(piston) sits on the crank's axis; place it out along its cylinder; left out"); continue
            }
            let offset = simd_dot(pin - origin, a)
            let throwLength = simd_length((pin - origin) - a * offset)
            let length = rodPart.form["length"]
            guard length * length - offset * offset > throwLength * throwLength * 1.1 else {
                errors.append("\(at).rod: \(rod) is \(format(length)) eye to eye, not long enough past the crank's throw \(format(throwLength)), so the crank can't turn; left out"); continue
            }
            var cylinder: String?
            if let given = item["cylinder"] {
                if let name = text(given).flatMap(scene.resolve), scene.parts.contains(where: { $0.id == name }) { cylinder = name }
                else { repairs.append("\(at).cylinder: \"\(text(given) ?? "")\" isn't a part; ignored") }
            }
            links.append(.init(crank: crank, joint: joint.id, rod: rod, piston: piston, cylinder: cylinder, pin: pin,
                               origin: origin, direction: simd_normalize(out), length: length))
        }
        return links
    }

    // MARK: Flows

    private mutating func readFlows(_ raw: Any?, _ scene: Scene) -> [Scene.Flow] {
        var flows: [Scene.Flow] = []
        for (index, item) in list(raw, "flows", limit: Scene.maxFlows).enumerated() {
            guard let item else { errors.append("flows[\(index)]: must be an object; left out"); continue }
            let id = uniqueID(item["id"], fallback: "flow\(index + 1)", taken: Set(flows.map(\.id)), at: "flows[\(index)]")
            let at = "flows.\(id)"
            ignoreOthers(item, ["id", "through", "path", "color", "colour", "speed", "density", "spread", "loop", "on"], at: at)
            guard let given = (item["through"] ?? item["path"]) as? [Any] else {
                errors.append("\(at).through: missing; list the parts it passes through, in order; left out"); continue
            }
            var through: [String] = []
            for (k, raw) in given.prefix(24).enumerated() {
                guard let name = text(raw)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { repairs.append("\(at).through[\(k)]: not a name; skipped"); continue }
                guard let read = scene.resolve(name) else { repairs.append("\(at).through[\(k)]: \"\(name)\" isn't a part or group; skipped"); continue }
                if read != name { repairs.append("\(at).through[\(k)]: \"\(name)\" read as \(read)") }
                if through.last != read { through.append(read) }
            }
            if given.count > 24 { repairs.append("\(at).through: \(given.count) names, past 24; kept the first 24") }
            let points = through.map(scene.centre(of:))
            guard through.count >= 2, zip(points, points.dropFirst()).contains(where: { simd_distance($0, $1) > Scene.minSize }) else {
                errors.append("\(at).through: needs at least two parts in different places; left out"); continue
            }
            let colour = item["color"] ?? item["colour"]
            let tint = colour == nil ? Scene.Tint.sky : self.tint(colour, at: "\(at).color")
            guard let speed = amount(item["speed"], at: "\(at).speed", range: 0.05...3, fallback: 0.6),
                  let density = amount(item["density"], at: "\(at).density", range: 1...40, fallback: 12),
                  let spread = amount(item["spread"], at: "\(at).spread", range: 0...Scene.maxExtent, fallback: 0) else { continue }
            flows.append(.init(id: id, through: through, tint: tint, speed: speed, density: density, spread: spread,
                               loop: flag(item["loop"], at: "\(at).loop"), on: item["on"] == nil ? true : flag(item["on"], at: "\(at).on")))
        }
        return flows
    }
}

private extension SIMD3 where Scalar == Float {
    /// To three places, with no "-0".
    var rounded3: SIMD3<Float> { (self * 1000).rounded(.toNearestOrAwayFromZero) / 1000 + SIMD3(repeating: 0) }
}

// MARK: - Kinematics

/// Where moving parts are at a moment, worked out from the joints, drives and links alone.
enum CookieSceneMotion {
    struct Placement: Equatable {
        var position: SIMD3<Float>
        var orientation: simd_quatf
    }

    /// Each joint's turns (a slide's strokes), the driven ones from their drivers; `free` gives the rest.
    static func turns(_ scene: CookieScene, free: (CookieScene.Joint) -> Float) -> [String: Float] {
        let driven = Set(scene.drives.map(\.to))
        var turns: [String: Float] = [:]
        for joint in scene.joints where !driven.contains(joint.id) { turns[joint.id] = free(joint) }
        var pending = scene.drives
        while !pending.isEmpty {
            let before = pending.count
            pending.removeAll { drive in
                guard let from = turns[drive.from] else { return false }
                turns[drive.to] = from * drive.ratio
                return true
            }
            if pending.count == before { break }
        }
        return turns
    }

    /// `time` seconds into running.
    static func turns(_ scene: CookieScene, time: Float) -> [String: Float] { turns(scene) { $0.rate * time } }

    /// The still pose Reduce Motion shows: every free joint a sixth of a turn on (a crank part-way
    /// round reads as a crank), plus a twelfth for each step asked for.
    static func representative(_ scene: CookieScene, steps: Int = 0) -> [String: Float] {
        turns(scene) { joint in (1 / 6 + Float(steps) / 12) * (joint.rate < 0 ? -1 : 1) }
    }

    /// How long one step is: a twelfth of the first free joint's turn.
    static func stepSeconds(_ scene: CookieScene) -> Float {
        let driven = Set(scene.drives.map(\.to))
        let rate = scene.joints.first { !driven.contains($0.id) }.map { abs($0.rate) } ?? CookieScene.defaultRate
        return 1 / (12 * max(0.01, rate))
    }

    /// Every moved part's place and turn, scene coordinates; parts not listed stay where they were built.
    static func pose(_ scene: CookieScene, turns: [String: Float]) -> [String: Placement] {
        var byID: [String: CookieScene.Part] = [:]
        for part in scene.parts where byID[part.id] == nil { byID[part.id] = part }
        var pose: [String: Placement] = [:]
        for joint in scene.joints {
            let t = turns[joint.id] ?? 0
            for id in joint.members {
                guard let part = byID[id] else { continue }
                switch joint.kind {
                case .slide:
                    pose[id] = .init(position: part.position + joint.axis * (joint.travel / 2 * sin(2 * .pi * t)), orientation: part.orientation)
                case .spin, .crank:
                    let q = simd_quatf(angle: 2 * .pi * t, axis: joint.axis)
                    pose[id] = .init(position: joint.pivot + q.act(part.position - joint.pivot), orientation: q * part.orientation)
                }
            }
        }
        for link in scene.links {
            guard let joint = scene.joints.first(where: { $0.id == link.joint }), let piston = byID[link.piston] else { continue }
            let solved = solve(link, axis: joint.axis, pivot: joint.pivot, turns: turns[joint.id] ?? 0)
            pose[link.rod] = .init(position: (solved.pin + solved.wrist) / 2, orientation: rodOrientation(from: solved.pin, to: solved.wrist, axis: joint.axis))
            pose[link.piston] = .init(position: solved.wrist, orientation: piston.orientation)
        }
        return pose
    }

    /// The slider-crank solved exactly: the crankpin turned, and the piston pin where the rod, eye to
    /// eye, reaches the piston's line (the far root, so the piston stays on its side of the crank).
    /// The pin may stand off the piston's plane along the axis; the rod then leans, still exact.
    static func solve(_ link: CookieScene.Link, axis: SIMD3<Float>, pivot: SIMD3<Float>, turns: Float) -> (pin: SIMD3<Float>, wrist: SIMD3<Float>, travel: Float) {
        let q = simd_quatf(angle: 2 * .pi * turns, axis: axis)
        let pin = pivot + q.act(link.pin - pivot)
        let p = pin - link.origin
        let lean = simd_dot(p, axis)
        let flat = p - axis * lean
        let along = simd_dot(flat, link.direction)
        let across = max(0, simd_length_squared(flat) - along * along)
        let travel = along + sqrt(max(0, link.length * link.length - lean * lean - across))
        return (pin, link.origin + link.direction * travel, travel)
    }

    /// The rod's own y from its big end (on the pin) to its small end, its flat face across the crank's axis.
    static func rodOrientation(from pin: SIMD3<Float>, to wrist: SIMD3<Float>, axis: SIMD3<Float>) -> simd_quatf {
        let y = simd_normalize(wrist - pin)
        var z = axis - y * simd_dot(axis, y)
        z = simd_length(z) > 1e-5 ? simd_normalize(z) : simd_normalize(simd_cross(y, abs(y.x) < 0.9 ? [1, 0, 0] : [0, 1, 0]))
        let x = simd_cross(y, z)
        return simd_quatf(simd_float3x3(columns: (x, y, z)))
    }

    /// Where a part sits on the stage (about the centroid, its explosion `blend` of the way out), moved or not.
    static func placed(_ scene: CookieScene, _ part: CookieScene.Part, pose: [String: Placement], explosion blend: Float) -> Placement {
        let moved = pose[part.id] ?? .init(position: part.position, orientation: part.orientation)
        let outward = scene.place(of: part, exploded: true) - scene.place(of: part, exploded: false)
        return .init(position: moved.position - scene.centroid + outward * blend, orientation: moved.orientation)
    }
}

// MARK: - Flow paths

/// A smooth path through points (a Catmull–Rom spline, centripetal so it never loops on itself
/// between close points), sampled once and walked by arc length.
struct CookieFlowPath {
    private(set) var samples: [SIMD3<Float>] = []
    private(set) var distances: [Float] = []
    var length: Float { distances.last ?? 0 }
    let loop: Bool

    init(through points: [SIMD3<Float>], loop: Bool, steps: Int = 16) {
        self.loop = loop
        var kept: [SIMD3<Float>] = []
        for point in points where kept.last.map({ simd_distance($0, point) > 1e-5 }) ?? true { kept.append(point) }
        if loop, kept.count > 2, let first = kept.first, simd_distance(first, kept.last!) < 1e-5 { kept.removeLast() }
        guard kept.count >= 2 else { samples = kept; distances = kept.map { _ in 0 }; return }
        let n = kept.count
        func at(_ i: Int) -> SIMD3<Float> {
            if loop { return kept[((i % n) + n) % n] }
            if i < 0 { return kept[0] * 2 - kept[1] }
            if i >= n { return kept[n - 1] * 2 - kept[n - 2] }
            return kept[i]
        }
        let spans = loop ? n : n - 1
        for span in 0..<spans {
            let p0 = at(span - 1), p1 = at(span), p2 = at(span + 1), p3 = at(span + 2)
            for k in 0..<steps { samples.append(Self.centripetal(p0, p1, p2, p3, Float(k) / Float(steps))) }
        }
        samples.append(loop ? kept[0] : kept[n - 1])
        distances = [0]
        for (a, b) in zip(samples, samples.dropFirst()) { distances.append(distances.last! + simd_distance(a, b)) }
    }

    /// The point `s` along (wrapping round a loop, clamped on an open path).
    func point(at s: Float) -> SIMD3<Float> {
        guard samples.count > 1, length > 0 else { return samples.first ?? .zero }
        let s = loop ? s.truncatingRemainder(dividingBy: length) + (s < 0 ? length : 0) : min(length, max(0, s))
        var low = 0, high = distances.count - 1
        while high - low > 1 { let mid = (low + high) / 2; if distances[mid] <= s { low = mid } else { high = mid } }
        let span = distances[high] - distances[low]
        return simd_mix(samples[low], samples[high], SIMD3(repeating: span > 0 ? (s - distances[low]) / span : 0))
    }

    /// The way the path runs at `s`, a unit vector.
    func tangent(at s: Float) -> SIMD3<Float> {
        let h = max(1e-4, length * 0.01)
        let d = point(at: s + h) - point(at: s - h)
        return simd_length(d) > 1e-7 ? simd_normalize(d) : SIMD3(1, 0, 0)
    }

    /// Two directions across the path at `s`, for spreading beads round it.
    func across(at s: Float) -> (SIMD3<Float>, SIMD3<Float>) {
        let t = tangent(at: s)
        let reference: SIMD3<Float> = abs(t.y) < 0.9 ? [0, 1, 0] : [1, 0, 0]
        let a = simd_normalize(simd_cross(t, reference))
        return (a, simd_cross(t, a))
    }

    static func centripetal(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>, _ u: Float) -> SIMD3<Float> {
        func knot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { max(1e-4, sqrt(simd_distance(a, b))) }
        let t1 = knot(p0, p1), t2 = t1 + knot(p1, p2), t3 = t2 + knot(p2, p3)
        let t = t1 + (t2 - t1) * u
        func lerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ ta: Float, _ tb: Float) -> SIMD3<Float> { a * ((tb - t) / (tb - ta)) + b * ((t - ta) / (tb - ta)) }
        let a1 = lerp(p0, p1, 0, t1), a2 = lerp(p1, p2, t1, t2), a3 = lerp(p2, p3, t2, t3)
        let b1 = lerp(a1, a2, 0, t2), b2 = lerp(a2, a3, t1, t3)
        return lerp(b1, b2, t1, t2)
    }
}

extension CookieSceneMotion {
    /// A flow's path on the stage, through its parts' middles where they sit (exploded `blend` of the way).
    static func path(_ scene: CookieScene, _ flow: CookieScene.Flow, explosion blend: Float) -> CookieFlowPath {
        let points = flow.through.map { name -> SIMD3<Float> in
            let named = scene.parts(named: name)
            let places = named.map { placed(scene, $0, pose: [:], explosion: blend).position }
            return places.reduce(.zero, +) / Float(max(1, places.count))
        }
        return CookieFlowPath(through: points, loop: flow.loop)
    }

    /// How many beads each flow gets: its density along its length, at least four and at most
    /// `maxBeadsPerFlow`, the lot scaled down together to fit `maxBeads`.
    static func beadCounts(_ scene: CookieScene, lengths: [Float]) -> [Int] {
        let wanted = zip(scene.flows, lengths).map { flow, length in min(CookieScene.maxBeadsPerFlow, max(4, Int((flow.density * length).rounded()))) }
        let total = wanted.reduce(0, +)
        guard total > CookieScene.maxBeads else { return wanted }
        let scale = Float(CookieScene.maxBeads) / Float(total)
        return wanted.map { max(2, Int(Float($0) * scale)) }
    }

    /// Bead `index` of `count`: how far along it is at `time`, and its fixed place round the stream.
    static func bead(_ index: Int, of count: Int, flow: CookieScene.Flow, path: CookieFlowPath, time: Float) -> (s: Float, offset: SIMD3<Float>, fade: Float) {
        let length = max(path.length, 1e-4)
        var s = (Float(index) / Float(max(1, count)) * length + flow.speed * time).truncatingRemainder(dividingBy: length)
        if s < 0 { s += length }
        let golden: Float = 2.399963
        let angle = Float(index) * golden
        let radius = flow.spread * (0.55 + 0.45 * (Float(index) * 0.618034).truncatingRemainder(dividingBy: 1))
        let (a, b) = path.across(at: s)
        // An open path's beads fade in at the start and out at the end instead of popping.
        let edge = path.loop ? 1 : min(1, min(s, length - s) / (length * 0.08))
        return (s, (a * cos(angle) + b * sin(angle)) * radius, edge)
    }
}

// MARK: - Camera rig

/// The 3D camera: where it looks (a point) and from which way and how far (yaw, pitch, distance),
/// each on a `CookieSpring3D`, so a move from one shot to the next is eased and keeps its speed when
/// retargeted. Yaw and pitch are springs rather than the eye's position, so a move from the front
/// to the side swings round the model instead of cutting through it.
struct CookieSceneCameraRig {
    enum View: String, CaseIterable { case front, side, top, overview }

    /// The look-at point, world coordinates.
    private(set) var look: CookieSpring3D
    /// (yaw, pitch, distance): yaw about world y from +z, pitch up from level, radians; distance in metres.
    private(set) var orbit: CookieSpring3D
    /// The model-space point being framed; the look follows it as the model turns. Nil: the centre.
    private(set) var subject: SIMD3<Float>?

    static let defaultPitch = Double(asin(CookieSceneCamera.direction.y))
    /// Pitch stays inside this, so "top" never lines the camera up with its up vector.
    static let pitchLimit = 80 * Double.pi / 180

    init(overview distance: Float) {
        look = CookieSpring3D(position: .zero, duration: 0.9)
        orbit = CookieSpring3D(position: [0, Self.defaultPitch, Double(distance)], duration: 0.9)
    }

    /// Where the eye is, for a person's zoom on top (they win: zoom is applied as is).
    func eye(zoom: Float = 1) -> SIMD3<Float> {
        let o = orbit.position
        let direction = SIMD3<Double>(cos(o.y) * sin(o.x), sin(o.y), cos(o.y) * cos(o.x))
        return SIMD3<Float>(look.position + direction * o.z / Double(max(0.1, zoom)))
    }

    var target: SIMD3<Float> { SIMD3<Float>(look.position) }
    var isSettled: Bool { look.isSettled && orbit.isSettled }

    /// The way a world direction (eye from the look point) is, as yaw and pitch.
    static func angles(_ direction: SIMD3<Float>) -> (yaw: Double, pitch: Double) {
        let d = simd_normalize(SIMD3<Double>(direction))
        let pitch = min(pitchLimit, max(-pitchLimit, asin(min(1, max(-1, d.y)))))
        let level = SIMD2(d.x, d.z)
        return (simd_length(level) < 1e-6 ? 0 : atan2(d.x, d.z), pitch)
    }

    /// Frames a point (model space, turned into the world by `turn`) from a way and distance; any
    /// left nil keep their current target. `instantly`: a cut (Reduce Motion).
    mutating func frame(_ point: SIMD3<Float>?, turn: simd_quatf, yaw: Double? = nil, pitch: Double? = nil,
                        distance: Float? = nil, instantly: Bool) {
        subject = point
        let lookTarget = SIMD3<Double>(turn.act(point ?? .zero))
        var orbitTarget = orbit.target
        if let yaw {
            // The short way round.
            var delta = (yaw - orbit.position.x).truncatingRemainder(dividingBy: 2 * .pi)
            if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
            orbitTarget.x = orbit.position.x + delta
        }
        if let pitch { orbitTarget.y = min(Self.pitchLimit, max(-Self.pitchLimit, pitch)) }
        if let distance { orbitTarget.z = Double(max(0.02, distance)) }
        if instantly {
            look.snap(to: lookTarget)
            orbit.snap(to: orbitTarget)
        } else {
            look.target = lookTarget
            orbit.target = orbitTarget
        }
    }

    /// A preset view of the model: front looks from its +z, side from its +x, top from above
    /// (its front facing down the view), overview is the default shot of the whole model.
    mutating func show(_ view: View, turn: simd_quatf, overview: Float, instantly: Bool) {
        switch view {
        case .overview:
            frame(nil, turn: turn, yaw: 0, pitch: Self.defaultPitch, distance: overview, instantly: instantly)
        case .front, .side:
            let a = Self.angles(turn.act(view == .front ? SIMD3(0, 0.12, 1) : SIMD3(1, 0.12, 0)))
            frame(nil, turn: turn, yaw: a.yaw, pitch: a.pitch, distance: overview, instantly: instantly)
        case .top:
            let front = Self.angles(turn.act(SIMD3<Float>(0, 0, 1)))
            frame(nil, turn: turn, yaw: front.yaw, pitch: Self.pitchLimit, distance: overview, instantly: instantly)
        }
    }

    /// The person took the model: the camera stops where it is and stops following.
    mutating func hold() {
        look.hold()
        orbit.hold()
        subject = nil
    }

    /// One frame; the framed point follows the model as it turns.
    mutating func step(_ seconds: Float, turn: simd_quatf) {
        if let subject { look.target = SIMD3<Double>(turn.act(subject)) }
        look.step(seconds: Double(seconds))
        orbit.step(seconds: Double(seconds))
    }

    /// How far back to frame a ball of `radius`, the same fit the overview uses, with room round it.
    static func distance(radius: Float) -> Float {
        radius / sin(CookieSceneCamera.fieldOfView / 2 * .pi / 180) * 1.35
    }
}
