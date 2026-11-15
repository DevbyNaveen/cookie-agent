//
//  CookieScenes.swift
//  Cookie
//
//  3D scenes: a small model of a physical thing, built from named parts out
//  of a library of machine shapes (gears, blade rings, springs, pipes, tubes,
//  pistons, shafts, lathed and extruded outlines…), that Cookie can put
//  beside what it says when the shape is the point — how an engine is laid
//  out, what sits inside a pump. The model writes one inline as
//  [SCENE {json}] at the word where it belongs, or (later) hands it to a tool.
//  The model only picks shapes and sets numbers; `CookieMeshes` draws them
//  from vetted Swift. Nothing the model writes is run: the scene is data.
//
//  Reading is forgiving in and strict out. Where the intent is clear the
//  input is repaired (a number clamped into range, the nearest palette
//  colour, a capsule too short becoming a cylinder, an unknown field ignored)
//  and each repair is written down; only what can't be understood is an
//  error, named by part and field so the model can fix it. A part with an
//  error is left out and says so; nothing is dropped silently.
//
//  The scene appears at its tag, and each labelled part's label follows,
//  one by one, over the sentence after it.
//

import Foundation
import simd

struct CookieScene: Equatable {
    /// Every shape Cookie can draw. Round things stand along y (a gear, wheel or blade ring turns
    /// about y; a cylinder's height is along y), flat outlines lie in x–y with their depth along z.
    enum Shape: String, CaseIterable {
        case box, sphere, cylinder, cone, capsule, torus
        case gear, bevelGear, rack, shaft, bearing, bladeRing
        case spring, pipe, tube, piston, crank, rod, valve, wheel, propeller, screw
        case lathe, extrude, sweep, arrow
    }

    /// Cookie's palette; each tint is a real surface (steel is metal, rubber is rough) and glass is
    /// always see-through.
    enum Tint: String, CaseIterable {
        case amber, cream, graphite, sky, mint, rose, steel, glass, copper, brass, rubber
        case plasticWhite = "plastic-white"
        case carbon
    }

    /// How a surface catches the light: matte is rough, polished is mirror-smooth.
    enum Finish: String, CaseIterable { case matte, satin, polished }

    /// A part's shape with every parameter settled: what `CookieMeshes` draws, and its cache key.
    struct Form: Hashable {
        let shape: Shape
        /// Every parameter of the shape, by name (missing ones already defaulted; optional ones absent).
        let values: [String: Float]
        /// The shape's point list, when it has one: pipe and sweep paths (x, y, z), lathe profiles
        /// (radius, y), extrude outlines (x, y), shaft steps (radius, length).
        let points: [SIMD3<Float>]
        /// An extrude outline's holes (x, y).
        let holes: [[SIMD3<Float>]]

        init(_ shape: Shape, _ values: [String: Float], points: [SIMD3<Float>] = [], holes: [[SIMD3<Float>]] = []) {
            self.shape = shape
            self.values = values
            self.points = points
            self.holes = holes
        }

        /// A form from the old positional size (box: width, height, depth; sphere: radius; cylinder,
        /// cone, capsule: radius, height), everything else defaulted.
        init(_ shape: Shape, size: [Float]) {
            var values: [String: Float] = [:]
            for (index, parameter) in CookieScene.parameters(shape).enumerated() {
                if index < size.count { values[parameter.name] = size[index] } else if let fallback = parameter.fallback { values[parameter.name] = fallback }
            }
            self.init(shape, values)
        }

        subscript(_ name: String) -> Float { values[name] ?? 0 }

        /// The box the shape fills about its own origin, before the part is turned.
        var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) { CookieScene.bounds(of: self) }

        /// The radius of a ball around the part's origin that holds all of it, however it is turned.
        var reach: Float {
            let box = bounds
            return simd_length(simd_max(simd_abs(box.min), simd_abs(box.max)))
        }
    }

    struct Part: Equatable {
        let id: String
        let label: String?
        let form: Form
        let position: SIMD3<Float>
        /// Degrees about x, then y, then z.
        let rotation: SIMD3<Float>
        let tint: Tint
        let finish: Finish?
        /// Drawn see-through, to show what is inside it.
        let cut: Bool
        /// Parts in one group explode, isolate and move together.
        let group: String?

        init(id: String, label: String?, form: Form, position: SIMD3<Float>, rotation: SIMD3<Float>, tint: Tint,
             finish: Finish? = nil, cut: Bool, group: String? = nil) {
            self.id = id
            self.label = label
            self.form = form
            self.position = position
            self.rotation = rotation
            self.tint = tint
            self.finish = finish
            self.cut = cut
            self.group = group
        }

        /// A primitive part from its old positional size.
        init(id: String, label: String?, shape: Shape, size: [Float], position: SIMD3<Float>, rotation: SIMD3<Float>, tint: Tint, cut: Bool) {
            self.init(id: id, label: label, form: Form(shape, size: size), position: position, rotation: rotation, tint: tint, cut: cut)
        }

        var shape: Shape { form.shape }

        var orientation: simd_quatf {
            let r = rotation * (.pi / 180)
            return simd_quatf(angle: r.z, axis: [0, 0, 1]) * simd_quatf(angle: r.y, axis: [0, 1, 0]) * simd_quatf(angle: r.x, axis: [1, 0, 0])
        }

        var reach: Float { form.reach }
    }

    let title: String
    let parts: [Part]
    let explode: Bool
    let spin: Bool
    /// UTF-16 offset in the spoken text where the tag sat (`CookieSpeechClock` units).
    var offset = 0
    /// Where each grouped part's group sits (the middle of its members): a group explodes as one.
    private let groupCentres: [String: SIMD3<Float>]

    // MARK: Limits

    static let maxParts = 64
    /// Metres, more or less: no size or position past this, and nothing smaller than `minSize`.
    static let maxExtent: Float = 10
    static let minSize: Float = 0.001
    static let titleLength = 60
    static let labelLength = 28
    /// How far apart an exploded scene's parts end up, as a multiple of their distance from the centre.
    static let explodeSpread: Float = 1.6

    /// The scene a SCENE tag describes, repaired where that's clear; nil when there's nothing to show.
    init?(tag: CookieReplyTag) {
        guard let scene = Self.read(tag: tag)?.scene else { return nil }
        self = scene
    }

    init(title: String, parts: [Part], explode: Bool, spin: Bool, offset: Int = 0) {
        self.title = title
        self.parts = parts
        self.explode = explode
        self.spin = spin
        self.offset = offset
        var members: [String: [SIMD3<Float>]] = [:]
        for part in parts { if let group = part.group { members[group, default: []].append(part.position) } }
        groupCentres = members.mapValues { $0.reduce(.zero, +) / Float($0.count) }
    }

    /// The parts that carry a label, in the order their labels appear.
    var labelled: [Part] { parts.filter { $0.label != nil } }

    /// The parts that move with `id`: its whole group, or just itself.
    func members(of id: String) -> Set<String> {
        guard let group = parts.first(where: { $0.id == id })?.group else { return [id] }
        return Set(parts.filter { $0.group == group }.map(\.id))
    }

    /// The middle of the parts; the model turns about it and explodes away from it.
    var centroid: SIMD3<Float> {
        parts.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(parts.count)
    }

    /// Where a part sits relative to the centroid, assembled or exploded. A grouped part moves out
    /// with its group's middle, so the group stays together.
    func place(of part: Part, exploded: Bool) -> SIMD3<Float> {
        let centre = centroid
        guard exploded else { return part.position - centre }
        let anchor = part.group.flatMap { groupCentres[$0] } ?? part.position
        return part.position - centre + (anchor - centre) * (Self.explodeSpread - 1)
    }

    /// The radius of a ball around the centroid that holds the whole scene, exploded if it will be.
    var radius: Float {
        max(0.05, parts.map { simd_length(place(of: $0, exploded: explode)) + $0.reach }.max() ?? 0.05)
    }

    var spokenSummary: String {
        ([title] + labelled.compactMap(\.label)).joined(separator: ". ")
    }

    /// Where on the speech clock each beat falls: the scene (and its title) at the tag, then each
    /// label, spread over the sentence after it.
    func revealOffsets(in spoken: String) -> [Int] {
        CookieCard.namedBeats(labelled.compactMap(\.label), from: offset, in: spoken)
    }

    // MARK: Shapes and their numbers

    /// One number a shape takes: its name, the default when it's left out (nil: optional, no
    /// default), the range it's clamped into, and whether it counts things (teeth, blades).
    struct Parameter {
        let name: String
        let fallback: Float?
        let range: ClosedRange<Float>
        var whole = false
    }

    /// A shape's numbers, in the order a positional `size` fills them.
    static func parameters(_ shape: Shape) -> [Parameter] {
        let length = minSize...maxExtent, zeroable: ClosedRange<Float> = 0...maxExtent
        func p(_ name: String, _ fallback: Float?, _ range: ClosedRange<Float> = length) -> Parameter { Parameter(name: name, fallback: fallback, range: range) }
        func count(_ name: String, _ fallback: Float?, _ range: ClosedRange<Float>) -> Parameter { Parameter(name: name, fallback: fallback, range: range, whole: true) }
        switch shape {
        case .box: return [p("width", 0.5), p("height", 0.5), p("depth", 0.5), p("corner", nil, zeroable)]
        case .sphere: return [p("radius", 0.25)]
        case .cylinder, .cone: return [p("radius", 0.25), p("height", 0.5)]
        case .capsule: return [p("radius", 0.15), p("height", 0.6)]
        case .torus: return [p("radius", 0.3), p("tube", 0.08)]
        case .gear: return [p("radius", 0.3), p("thickness", 0.08), count("teeth", 20, 6...120), p("bore", 0, zeroable)]
        case .bevelGear: return [p("radius", 0.3), p("thickness", 0.1), count("teeth", 20, 6...120), p("bore", 0, zeroable), p("cone", 45, 10...80)]
        case .rack: return [p("length", 1), p("height", 0.1), p("thickness", 0.06), count("teeth", 16, 3...80)]
        case .shaft: return [p("radius", 0.05), p("length", 1)]
        case .bearing: return [p("radius", 0.2), p("inner", 0.1), p("width", 0.08), count("balls", nil, 3...40)]
        case .bladeRing: return [p("tip", 0.5), p("hub", 0.15), p("thickness", 0.08), count("blades", 16, 2...64), p("twist", 30, -80...80)]
        case .spring: return [p("radius", 0.1), p("length", 0.5), p("wire", 0.015), count("coils", 8, 1...40)]
        case .pipe: return [p("radius", 0.05), p("bend", nil)]
        case .tube: return [p("radius", 0.3), p("inner", 0.25), p("length", 0.6)]
        case .piston: return [p("radius", 0.15), p("height", 0.2)]
        case .crank: return [p("throw", 0.15), p("radius", 0.05), p("thickness", 0.05)]
        case .rod: return [p("length", 0.5), p("radius", 0.07), p("small", 0.045), p("thickness", 0.04)]
        case .valve: return [p("radius", 0.08), p("length", 0.5), p("stem", 0.012)]
        case .wheel: return [p("radius", 0.35), p("width", 0.12), p("hub", 0.08), count("spokes", 6, 0...16)]
        case .propeller: return [p("radius", 0.4), count("blades", 3, 2...8), p("pitch", 25, 0...70), p("hub", 0.06)]
        case .screw: return [p("radius", 0.03), p("length", 0.25), p("pitch", 0.012), p("head", 0.05)]
        case .lathe: return []
        case .extrude: return [p("depth", 0.1)]
        case .sweep: return [p("radius", 0.05), p("width", nil), p("height", nil)]
        case .arrow: return [p("length", 0.6), p("radius", 0.03)]
        }
    }

    /// The list of points a shape takes, when it takes one.
    struct PointList {
        let field: String
        let aliases: [String]
        let dimensions: Int
        let count: ClosedRange<Int>
        let required: Bool
    }

    static func pointList(_ shape: Shape) -> PointList? {
        switch shape {
        case .pipe: return PointList(field: "points", aliases: ["path"], dimensions: 3, count: 2...24, required: true)
        case .sweep: return PointList(field: "path", aliases: ["points"], dimensions: 3, count: 2...32, required: true)
        case .lathe: return PointList(field: "profile", aliases: ["points"], dimensions: 2, count: 2...64, required: true)
        case .extrude: return PointList(field: "outline", aliases: ["points"], dimensions: 2, count: 3...64, required: true)
        case .shaft: return PointList(field: "steps", aliases: [], dimensions: 2, count: 1...8, required: false)
        default: return nil
        }
    }

    static let maxHoles = 6
    static let holePoints = 3...48

    /// The shared numbers of the toothed and bladed shapes, so drawing and bounds agree exactly.
    static func gearRadii(_ form: Form) -> (module: Float, outer: Float, root: Float) {
        let module = 2 * form["radius"] / max(form["teeth"], 6)
        return (module, form["radius"] + module, max(form["radius"] - 1.25 * module, form["radius"] * 0.5))
    }

    static func rackTooth(_ form: Form) -> (module: Float, depth: Float) {
        let module = form["length"] / (max(form["teeth"], 3) * .pi)
        return (module, min(2.25 * module, form["height"] * 0.5))
    }

    /// The box a form fills about its own origin. Drawn shapes stay inside it (the parts checks hold
    /// every shape to that), so framing and exploding can trust it without drawing anything.
    static func bounds(of form: Form) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        func centred(_ x: Float, _ y: Float, _ z: Float) -> (min: SIMD3<Float>, max: SIMD3<Float>) { (-SIMD3(x, y, z), SIMD3(x, y, z)) }
        func pointBox(_ points: [SIMD3<Float>], pad: SIMD3<Float>) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
            guard let first = points.first else { return centred(pad.x, pad.y, pad.z) }
            let low = points.reduce(first) { simd_min($0, $1) }, high = points.reduce(first) { simd_max($0, $1) }
            return (low - pad, high + pad)
        }
        let f = form
        switch form.shape {
        case .box: return centred(f["width"] / 2, f["height"] / 2, f["depth"] / 2)
        case .sphere: return centred(f["radius"], f["radius"], f["radius"])
        case .cylinder, .cone, .capsule, .piston: return centred(f["radius"], f["height"] / 2, f["radius"])
        case .torus: return centred(f["radius"] + f["tube"], f["tube"], f["radius"] + f["tube"])
        case .gear, .bevelGear:
            let outer = gearRadii(f).outer
            return centred(outer, f["thickness"] / 2, outer)
        case .rack: return centred(f["length"] / 2, f["height"] / 2, f["thickness"] / 2)
        case .shaft:
            let widest = max(f["radius"], f.points.map(\.x).max() ?? 0)
            return centred(widest, (f["length"] + f.points.reduce(0) { $0 + $1.y }) / 2, widest)
        case .bearing: return centred(f["radius"], f["width"] / 2, f["radius"])
        case .bladeRing: return centred(f["tip"] * 1.05, f["thickness"] * 0.6, f["tip"] * 1.05)
        case .spring: return centred(f["radius"] + f["wire"], f["length"] / 2 + f["wire"], f["radius"] + f["wire"])
        case .pipe: return pointBox(f.points, pad: SIMD3(repeating: f["radius"]))
        case .tube: return centred(f["radius"], f["length"] / 2, f["radius"])
        case .crank:
            let r = f["radius"], t = f["thickness"]
            return (SIMD3(-1.7 * r, -2 * t, -1.7 * r), SIMD3(f["throw"] + 1.35 * r, 2 * t, 1.7 * r))
        case .rod: return (SIMD3(-f["radius"], -f["length"] / 2 - f["radius"], -f["thickness"] / 2), SIMD3(f["radius"], f["length"] / 2 + f["small"], f["thickness"] / 2))
        case .valve: return centred(f["radius"], f["length"] / 2, f["radius"])
        case .wheel: return centred(f["radius"], f["width"] / 2, f["radius"])
        case .propeller:
            let r = f["radius"] * 1.05, hub = f["hub"]
            return (SIMD3(-r, -max(hub, f["radius"] * 0.12), -r), SIMD3(r, max(hub * 1.8, f["radius"] * 0.12), r))
        case .screw:
            let wide = max(f["radius"], f["head"])
            return centred(wide, f["length"] / 2, wide)
        case .lathe:
            let wide = f.points.map(\.x).max() ?? 0
            let low = f.points.map(\.y).min() ?? 0, high = f.points.map(\.y).max() ?? 0
            return (SIMD3(-wide, low, -wide), SIMD3(wide, high, wide))
        case .extrude:
            let box = pointBox(f.points, pad: .zero)
            return (SIMD3(box.min.x, box.min.y, -f["depth"] / 2), SIMD3(box.max.x, box.max.y, f["depth"] / 2))
        case .sweep:
            let half = f.values["width"].map { simd_length(SIMD2($0, f.values["height"] ?? $0)) / 2 } ?? f["radius"]
            return pointBox(f.points, pad: SIMD3(repeating: half))
        case .arrow: return centred(f["radius"] * 2.6, f["length"] / 2, f["radius"] * 2.6)
        }
    }

    // MARK: Reading

    /// What reading a scene gave: the scene (nil when nothing could be shown), what was repaired,
    /// and what couldn't be understood — each line names the part and field.
    struct Reading {
        let scene: CookieScene?
        let repairs: [String]
        let errors: [String]
    }

    static let sceneFields: Set<String> = ["title", "parts", "explode", "spin"]
    static let baseFields: Set<String> = ["id", "label", "shape", "size", "position", "rotation", "color", "colour", "finish", "cut", "group"]
    static let aliasFields: Set<String> = ["diameter", "outer", "module", "section", "holes"]
    /// Every field a part may carry, across all shapes.
    static let partFields: Set<String> = {
        var fields = baseFields.union(aliasFields)
        for shape in Shape.allCases {
            fields.formUnion(parameters(shape).map(\.name))
            if let list = pointList(shape) { fields.insert(list.field); fields.formUnion(list.aliases) }
        }
        return fields
    }()

    /// The errors in a reading as one line for the model to fix (the first few, then a count), or
    /// nil when everything in it could be built.
    static func problems(_ reading: Reading) -> String? {
        guard !reading.errors.isEmpty else { return nil }
        let shown = reading.errors.prefix(6).joined(separator: "; ")
        return reading.errors.count > 6 ? shown + "; and \(reading.errors.count - 6) more" : shown
    }

    /// One short line for the person when a model was shown without some of its parts, naming the
    /// first problem; nil when the model is whole (or wasn't shown: that has its own line).
    static func leftOutNote(_ reading: Reading?) -> String? {
        guard let reading, reading.scene != nil, let first = reading.errors.first else { return nil }
        let more = reading.errors.count > 1 ? " (and \(reading.errors.count - 1) more)" : ""
        return "Part of the model couldn't be built, so it's missing: \(first)\(more)."
    }

    /// The reading of a SCENE tag, or nil when the tag isn't one.
    static func read(tag: CookieReplyTag) -> Reading? {
        tag.kind == "SCENE" ? read(tag.body, offset: tag.offset) : nil
    }

    static func read(_ body: String, offset: Int = 0) -> Reading {
        var reader = SceneReader()
        let scene = reader.scene(body, offset: offset)
        return Reading(scene: scene, repairs: reader.repairs, errors: reader.errors)
    }

    /// Shape names a model reaches for that mean one of Cookie's (folded: lowercase letters only).
    static let shapeAliases: [String: Shape] = [
        "cube": .box, "cuboid": .box, "block": .box, "plate": .box, "ball": .sphere, "disc": .cylinder, "disk": .cylinder,
        "ring": .torus, "donut": .torus, "doughnut": .torus, "cog": .gear, "spurgear": .gear, "fan": .bladeRing,
        "compressor": .bladeRing, "turbine": .bladeRing, "impeller": .bladeRing, "rotor": .bladeRing, "coil": .spring,
        "helix": .spring, "hose": .pipe, "duct": .pipe, "sleeve": .tube, "cylindertube": .tube, "hollowcylinder": .tube,
        "axle": .shaft, "crankshaft": .crank, "connectingrod": .rod, "conrod": .rod, "bolt": .screw, "revolve": .lathe,
        "extrusion": .extrude, "prism": .extrude, "tyre": .wheel, "tire": .wheel, "prop": .propeller,
    ]

    /// Colour words a model reaches for, by the palette tint that's nearest (folded).
    static let colourAliases: [String: Tint] = [
        "red": .rose, "pink": .rose, "orange": .amber, "yellow": .amber, "gold": .brass, "golden": .brass,
        "brown": .copper, "bronze": .copper, "grey": .steel, "gray": .steel, "silver": .steel, "metal": .steel,
        "aluminium": .steel, "aluminum": .steel, "iron": .graphite, "black": .graphite, "darkgrey": .graphite,
        "darkgray": .graphite, "white": .plasticWhite, "plastic": .plasticWhite, "blue": .sky, "lightblue": .sky,
        "green": .mint, "teal": .mint, "beige": .cream, "ivory": .cream, "tan": .cream, "clear": .glass,
        "transparent": .glass, "rubberblack": .rubber, "carbonfibre": .carbon, "carbonfiber": .carbon,
    ]

    /// Each tint's colour, for finding the nearest one to a hex colour (and for drawing).
    static func rgb(_ tint: Tint) -> SIMD3<Float> {
        switch tint {
        case .amber: return [0.93, 0.56, 0.24]
        case .cream: return [0.96, 0.92, 0.84]
        case .graphite: return [0.24, 0.24, 0.26]
        case .sky: return [0.48, 0.70, 0.90]
        case .mint: return [0.55, 0.84, 0.70]
        case .rose: return [0.92, 0.52, 0.56]
        case .steel: return [0.72, 0.74, 0.78]
        case .glass: return [0.85, 0.93, 0.97]
        case .copper: return [0.85, 0.52, 0.36]
        case .brass: return [0.86, 0.72, 0.40]
        case .rubber: return [0.13, 0.13, 0.14]
        case .plasticWhite: return [0.94, 0.94, 0.92]
        case .carbon: return [0.11, 0.11, 0.12]
        }
    }

    /// Lowercase letters only: "Blade_Ring", "blade-ring" and "bladering" are one word.
    static func fold(_ text: String) -> String { String(text.lowercased().unicodeScalars.filter { CharacterSet.lowercaseLetters.contains($0) }) }
}

/// Reads a scene's JSON leniently, writing down every repair and error as it goes.
private struct SceneReader {
    var repairs: [String] = []
    var errors: [String] = []
    typealias Scene = CookieScene

    mutating func scene(_ body: String, offset: Int) -> Scene? {
        let data = Data(body.utf8)
        var object = try? JSONSerialization.jsonObject(with: data)
        if object == nil {
            // Comments, single quotes, unquoted keys: JSON5 reads what the model clearly meant.
            object = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
            if object != nil { repairs.append("scene: read as relaxed JSON (a comment, quote style or unquoted key)") }
        }
        guard let object else { errors.append("scene: not valid JSON; write one JSON object {\"title\":…,\"parts\":[…]}"); return nil }
        guard let fields = object as? [String: Any] else { errors.append("scene: must be a JSON object {\"title\":…,\"parts\":[…]}"); return nil }
        for key in fields.keys.sorted() where !Scene.sceneFields.contains(key) { repairs.append("scene.\(key): not a scene field; ignored") }

        var title = (fields["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty { title = "Model"; repairs.append("scene.title: missing; used \"Model\"") }
        title = shortened(title, to: Scene.titleLength, at: "scene.title")

        guard let rawParts = fields["parts"] as? [Any] else { errors.append("scene.parts: missing; give a list of parts"); return nil }
        guard !rawParts.isEmpty else { errors.append("scene.parts: empty; give at least one part"); return nil }
        if rawParts.count > Scene.maxParts {
            errors.append("scene.parts: \(rawParts.count) parts, past the limit of \(Scene.maxParts); parts \(Scene.maxParts + 1)–\(rawParts.count) left out")
        }
        var parts: [Scene.Part] = []
        for (index, raw) in rawParts.prefix(Scene.maxParts).enumerated() {
            guard let raw = raw as? [String: Any] else { errors.append("parts[\(index)]: must be an object; left out"); continue }
            if let part = part(raw, index: index, taken: Set(parts.map(\.id))) { parts.append(part) }
        }
        guard !parts.isEmpty else { errors.append("scene: no part could be built, so there is nothing to show"); return nil }
        return Scene(title: title, parts: parts, explode: flag(fields["explode"], at: "scene.explode"),
                     spin: flag(fields["spin"], at: "scene.spin"), offset: offset)
    }

    // MARK: Parts

    private mutating func part(_ raw: [String: Any], index: Int, taken: Set<String>) -> Scene.Part? {
        var id = text(raw["id"]) ?? ""
        if id.isEmpty { id = "part\(index + 1)"; repairs.append("parts[\(index)].id: missing; named it \(id)") }
        id = shortened(id, to: Scene.labelLength, at: "parts[\(index)].id")
        if taken.contains(id) {
            var number = 2
            while taken.contains("\(id)-\(number)") { number += 1 }
            repairs.append("\(id).id: used twice; renamed this one \(id)-\(number)")
            id = "\(id)-\(number)"
        }
        let at = id

        guard let shapeName = text(raw["shape"]), !shapeName.isEmpty else {
            errors.append("\(at).shape: missing; one of \(Scene.Shape.allCases.map(\.rawValue).joined(separator: ", "))"); return nil
        }
        var shape: Scene.Shape
        if let exact = Scene.Shape(rawValue: shapeName) {
            shape = exact
        } else if let folded = Scene.Shape.allCases.first(where: { Scene.fold($0.rawValue) == Scene.fold(shapeName) }) ?? Scene.shapeAliases[Scene.fold(shapeName)] {
            shape = folded
            repairs.append("\(at).shape: \"\(shapeName)\" read as \(folded.rawValue)")
        } else if Scene.fold(shapeName) == "label" || Scene.fold(shapeName) == "text" {
            errors.append("\(at).shape: there's no text in 3D; put words in a part's \"label\" instead"); return nil
        } else {
            errors.append("\(at).shape: \"\(shapeName)\" isn't a shape; one of \(Scene.Shape.allCases.map(\.rawValue).joined(separator: ", "))"); return nil
        }

        // Fields that don't belong to this shape are ignored, and said so.
        let own = Set(Scene.parameters(shape).map(\.name)).union(Scene.baseFields)
            .union(Scene.pointList(shape).map { [$0.field] + $0.aliases } ?? [])
            .union(shape == .extrude ? ["holes"] : []).union(shape == .sweep ? ["section"] : [])
            .union(["diameter"]).union(shape == .tube || shape == .bearing ? ["outer"] : []).union(shape == .gear || shape == .bevelGear ? ["module"] : [])
        for key in raw.keys.sorted() where !own.contains(key) {
            repairs.append(Scene.partFields.contains(key) ? "\(at).\(key): a \(shape.rawValue) doesn't take \(key); ignored" : "\(at).\(key): not a part field; ignored")
        }

        guard var values = numbers(of: shape, raw, at: at) else { return nil }
        var points: [SIMD3<Float>] = [], holes: [[SIMD3<Float>]] = []
        if let list = Scene.pointList(shape) {
            let given = ([list.field] + list.aliases).lazy.compactMap { raw[$0] }.first
            if let given {
                guard let read = pointList(given, list: list, at: "\(at).\(list.field)") else { return nil }
                points = read
            } else if list.required {
                errors.append("\(at).\(list.field): missing; a \(shape.rawValue) needs \(list.count.lowerBound)–\(list.count.upperBound) points"); return nil
            }
        }
        if shape == .extrude, let rawHoles = raw["holes"] {
            guard let read = holeLists(rawHoles, at: "\(at).holes") else { return nil }
            holes = read
        }
        if shape == .sweep {
            let section = text(raw["section"]).map(Scene.fold) ?? (values["width"] != nil ? "rect" : "circle")
            if !["circle", "rect", "rectangle", "square", "round"].contains(section) {
                repairs.append("\(at).section: \"\(section)\" isn't circle or rect; used circle")
            }
            if ["rect", "rectangle", "square"].contains(section) {
                values["width"] = values["width"] ?? values["radius"].map { $0 * 2 } ?? 0.1
                values["height"] = values["height"] ?? values["width"]
            } else {
                values["width"] = nil
                values["height"] = nil
            }
        }
        guard settle(&shape, &values, &points, &holes, at: at) else { return nil }

        let position = vector(raw["position"], at: "\(at).position", range: -Scene.maxExtent...Scene.maxExtent, missing: nil)
        guard let position else { return nil }
        let rotation = vector(raw["rotation"], at: "\(at).rotation", range: -360...360, missing: nil)
        guard let rotation else { return nil }

        var label = text(raw["label"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        if label?.isEmpty == true { label = nil }
        label = label.map { shortened($0, to: Scene.labelLength, at: "\(at).label") }
        var group = text(raw["group"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        if group?.isEmpty == true { group = nil }
        group = group.map { shortened($0, to: Scene.labelLength, at: "\(at).group") }

        return Scene.Part(id: id, label: label, form: Scene.Form(shape, values, points: points, holes: holes),
                          position: position, rotation: rotation, tint: tint(raw["color"] ?? raw["colour"], at: "\(at).color"),
                          finish: finish(raw["finish"], at: "\(at).finish"), cut: flag(raw["cut"], at: "\(at).cut"), group: group)
    }

    /// The shape's numbers: from named fields, else the positional size, else defaults; each clamped.
    private mutating func numbers(of shape: Scene.Shape, _ raw: [String: Any], at: String) -> [String: Float]? {
        let parameters = Scene.parameters(shape)
        var given: [String: Float] = [:]
        var named = raw
        if let diameter = raw["diameter"], named["radius"] == nil, let value = number(diameter, at: "\(at).diameter") { named["radius"] = Double(value / 2) }
        if let outer = raw["outer"], named["radius"] == nil, shape == .tube || shape == .bearing { named["radius"] = outer }
        if let size = raw["size"] {
            guard let list = (size as? [Any]) ?? (size is NSNumber ? [size] : nil) else {
                errors.append("\(at).size: must be a list of numbers (\(parameters.map(\.name).joined(separator: ", ")))"); return nil
            }
            if list.count > parameters.count {
                repairs.append("\(at).size: \(list.count) numbers for a \(shape.rawValue), which takes \(parameters.count) (\(parameters.map(\.name).joined(separator: ", "))); extra ignored")
            }
            for (parameter, value) in zip(parameters, list) where named[parameter.name] == nil { named[parameter.name] = value }
        }
        for parameter in parameters {
            guard let value = named[parameter.name] else { continue }
            guard let read = number(value, at: "\(at).\(parameter.name)") else { return nil }
            given[parameter.name] = read
        }
        if (shape == .gear || shape == .bevelGear), given["radius"] == nil, let module = raw["module"], let read = number(module, at: "\(at).module") {
            given["radius"] = read * (given["teeth"] ?? 20) / 2
        }
        if given.isEmpty && !parameters.isEmpty && Scene.pointList(shape) == nil {
            repairs.append("\(at): no size given; used a default \(shape.rawValue)")
        }
        var values: [String: Float] = [:]
        for parameter in parameters {
            guard var value = given[parameter.name] ?? parameter.fallback else { continue }
            if parameter.whole, value != value.rounded() {
                repairs.append("\(at).\(parameter.name): \(format(value)) rounded to \(format(value.rounded()))")
                value = value.rounded()
            }
            let clamped = min(parameter.range.upperBound, max(parameter.range.lowerBound, value))
            if clamped != value { repairs.append("\(at).\(parameter.name): \(format(value)) is outside \(format(parameter.range.lowerBound))–\(format(parameter.range.upperBound)); used \(format(clamped))") }
            values[parameter.name] = clamped
        }
        return values
    }

    /// Numbers that only make sense together; repaired the way the intent is plain.
    private mutating func settle(_ shape: inout Scene.Shape, _ v: inout [String: Float], _ points: inout [SIMD3<Float>], _ holes: inout [[SIMD3<Float>]], at: String) -> Bool {
        func cap(_ name: String, below limit: Float, to repaired: Float, because reason: String) {
            guard let value = v[name], value >= limit else { return }
            v[name] = max(Scene.minSize, repaired)
            repairs.append("\(at).\(name): \(format(value)) \(reason); used \(format(max(Scene.minSize, repaired)))")
        }
        switch shape {
        case .capsule:
            if v["height"]! < v["radius"]! * 2 {
                shape = .cylinder
                repairs.append("\(at).shape: a capsule \(format(v["height"]!)) tall can't hold two round ends of radius \(format(v["radius"]!)); drawn as a cylinder")
            }
        case .torus: cap("tube", below: v["radius"]!, to: v["radius"]! * 0.9, because: "is as thick as the ring is wide")
        case .tube: cap("inner", below: v["radius"]!, to: v["radius"]! * 0.8, because: "isn't inside the outer radius")
        case .bearing: cap("inner", below: v["radius"]! * 0.9, to: v["radius"]! * 0.5, because: "leaves no room for the balls")
        case .bladeRing: cap("hub", below: v["tip"]! * 0.9, to: v["tip"]! * 0.3, because: "leaves no room for blades")
        case .gear, .bevelGear:
            let root = Scene.gearRadii(Scene.Form(shape, v)).root
            cap("bore", below: root * 0.9, to: root * 0.5, because: "is wider than the gear's body")
        case .spring:
            cap("wire", below: v["radius"]! * 0.5, to: v["radius"]! * 0.25, because: "is too thick for the coil")
            cap("wire", below: v["length"]! / v["coils"]! / 2.2, to: v["length"]! / v["coils"]! / 2.4, because: "makes the coils overlap")
        case .rod:
            cap("small", below: v["radius"]! * 1.0001, to: v["radius"]!, because: "is bigger than the big end")
            if v["length"]! < (v["radius"]! + v["small"]!) * 1.2 {
                let repaired = (v["radius"]! + v["small"]!) * 1.5
                repairs.append("\(at).length: \(format(v["length"]!)) puts the two ends on top of each other; used \(format(repaired))")
                v["length"] = repaired
            }
        case .crank:
            if v["throw"]! < v["radius"]! * 2 {
                repairs.append("\(at).throw: \(format(v["throw"]!)) is inside the journal; used \(format(v["radius"]! * 2))")
                v["throw"] = v["radius"]! * 2
            }
        case .valve:
            cap("stem", below: v["radius"]! * 0.6, to: v["radius"]! * 0.25, because: "is as wide as the head")
            if v["length"]! < v["radius"]! * 1.6 + v["stem"]! * 3 {
                let repaired = min(Scene.maxExtent, v["radius"]! * 2.5 + v["stem"]! * 4)
                repairs.append("\(at).length: \(format(v["length"]!)) is too short for the head and stem; used \(format(repaired))")
                v["length"] = repaired
            }
        case .wheel: cap("hub", below: v["radius"]! * 0.6, to: v["radius"]! * 0.25, because: "fills the wheel")
        case .propeller: cap("hub", below: v["radius"]! * 0.5, to: v["radius"]! * 0.15, because: "is as big as the blades")
        case .screw:
            if v["head"]! < v["radius"]! * 1.2 {
                repairs.append("\(at).head: \(format(v["head"]!)) is narrower than the thread; used \(format(v["radius"]! * 1.6))")
                v["head"] = v["radius"]! * 1.6
            }
            cap("pitch", below: v["length"]! / 3, to: v["length"]! / 6, because: "is too coarse for the length")
            cap("pitch", below: v["radius"]! * 1.5, to: v["radius"]! * 0.6, because: "cuts deeper than the thread")
            if v["pitch"]! < v["length"]! / 40 {
                repairs.append("\(at).pitch: \(format(v["pitch"]!)) is finer than can be drawn; used \(format(v["length"]! / 40))")
                v["pitch"] = v["length"]! / 40
            }
        case .pipe:
            points = dedupe(points, at: "\(at).points")
            guard points.count >= 2 else { errors.append("\(at).points: needs two different points"); return false }
            if v["bend"] == nil { v["bend"] = v["radius"]! * 2 }
        case .sweep:
            points = dedupe(points, at: "\(at).path")
            guard points.count >= 2 else { errors.append("\(at).path: needs two different points"); return false }
        case .lathe:
            if points.contains(where: { $0.x < 0 }) {
                repairs.append("\(at).profile: a lathe profile is [radius, y]; negative radii read as positive")
                points = points.map { SIMD3(abs($0.x), $0.y, 0) }
            }
            points = dedupe(points, at: "\(at).profile")
            guard points.count >= 2, (points.map(\.x).max() ?? 0) >= Scene.minSize else {
                errors.append("\(at).profile: needs at least two different [radius, y] points away from the axis"); return false
            }
        case .extrude:
            points = dedupe(points, at: "\(at).outline")
            if let crossing = CookiePolygon.crossing(points) {
                errors.append("\(at).outline: crosses itself (edges \(crossing.0) and \(crossing.1)); give a simple outline"); return false
            }
            guard points.count >= 3, abs(CookiePolygon.area(points)) > Scene.minSize * Scene.minSize else {
                errors.append("\(at).outline: needs at least three points enclosing an area"); return false
            }
            for (index, hole) in holes.enumerated() {
                guard CookiePolygon.crossing(hole) == nil, abs(CookiePolygon.area(hole)) > 0,
                      hole.allSatisfy({ CookiePolygon.contains(points, $0) }), !CookiePolygon.edgesCross(points, hole) else {
                    errors.append("\(at).holes[\(index)]: must be a simple outline inside the part's outline"); return false
                }
                for (other, earlier) in holes.prefix(index).enumerated() where CookiePolygon.edgesCross(earlier, hole) || hole.contains(where: { CookiePolygon.contains(earlier, $0) }) {
                    errors.append("\(at).holes[\(index)]: overlaps holes[\(other)]"); return false
                }
            }
        case .shaft:
            points = points.map { SIMD3(min(Scene.maxExtent, max(Scene.minSize, $0.x)), min(Scene.maxExtent, max(Scene.minSize, $0.y)), 0) }
        default: break
        }
        return true
    }

    /// Repeated points in a row are one point.
    private mutating func dedupe(_ points: [SIMD3<Float>], at: String) -> [SIMD3<Float>] {
        var kept: [SIMD3<Float>] = []
        for point in points where kept.last.map({ simd_distance($0, point) > Scene.minSize / 10 }) ?? true { kept.append(point) }
        if kept.count != points.count { repairs.append("\(at): \(points.count - kept.count) repeated point\(points.count - kept.count == 1 ? "" : "s") dropped") }
        return kept
    }

    // MARK: Values

    private mutating func pointList(_ raw: Any, list: Scene.PointList, at: String) -> [SIMD3<Float>]? {
        guard let items = raw as? [Any] else { errors.append("\(at): must be a list of [\(list.dimensions == 3 ? "x, y, z" : "a, b")] points"); return nil }
        guard items.count >= list.count.lowerBound else {
            errors.append("\(at): \(items.count) point\(items.count == 1 ? "" : "s"); needs at least \(list.count.lowerBound)"); return nil
        }
        if items.count > list.count.upperBound { repairs.append("\(at): \(items.count) points, past \(list.count.upperBound); kept the first \(list.count.upperBound)") }
        var points: [SIMD3<Float>] = []
        for (index, item) in items.prefix(list.count.upperBound).enumerated() {
            guard let read = coordinates(item, count: list.dimensions, at: "\(at)[\(index)]") else { return nil }
            points.append(read)
        }
        return points
    }

    private mutating func holeLists(_ raw: Any, at: String) -> [[SIMD3<Float>]]? {
        guard let items = raw as? [Any] else { errors.append("\(at): must be a list of outlines"); return nil }
        if items.count > Scene.maxHoles { repairs.append("\(at): \(items.count) holes, past \(Scene.maxHoles); kept the first \(Scene.maxHoles)") }
        var holes: [[SIMD3<Float>]] = []
        for (index, item) in items.prefix(Scene.maxHoles).enumerated() {
            let list = Scene.PointList(field: "", aliases: [], dimensions: 2, count: Scene.holePoints, required: true)
            guard let hole = pointList(item, list: list, at: "\(at)[\(index)]") else { return nil }
            holes.append(dedupe(hole, at: "\(at)[\(index)]"))
        }
        return holes
    }

    /// `count` numbers (2 or 3), each within ±10.
    private mutating func coordinates(_ raw: Any, count: Int, at: String) -> SIMD3<Float>? {
        guard let items = raw as? [Any], items.count >= count else { errors.append("\(at): must be \(count) numbers"); return nil }
        if items.count > count { repairs.append("\(at): \(items.count) numbers; used the first \(count)") }
        var values: [Float] = []
        for (index, item) in items.prefix(count).enumerated() {
            guard let value = number(item, at: "\(at)[\(index)]") else { return nil }
            let clamped = min(Scene.maxExtent, max(-Scene.maxExtent, value))
            if clamped != value { repairs.append("\(at)[\(index)]: \(format(value)) is past ±\(format(Scene.maxExtent)); used \(format(clamped))") }
            values.append(clamped)
        }
        return SIMD3(values[0], values[1], count == 3 ? values[2] : 0)
    }

    /// Three numbers (position, rotation); two get a 0 added, missing ones default.
    private mutating func vector(_ raw: Any?, at: String, range: ClosedRange<Float>, missing: String?) -> SIMD3<Float>? {
        guard let raw else {
            if let missing { repairs.append("\(at): missing; \(missing)") }
            return .zero
        }
        guard let items = raw as? [Any], !items.isEmpty else {
            errors.append("\(at): must be three numbers [x, y, z]"); return nil
        }
        if items.count < 3 { repairs.append("\(at): \(items.count) number\(items.count == 1 ? "" : "s"); the rest read as 0") }
        if items.count > 3 { repairs.append("\(at): \(items.count) numbers; used the first three") }
        var values: [Float] = []
        for (index, item) in items.prefix(3).enumerated() {
            guard let value = number(item, at: "\(at)[\(index)]") else { return nil }
            let clamped = min(range.upperBound, max(range.lowerBound, value))
            if clamped != value { repairs.append("\(at)[\(index)]: \(format(value)) is past \(format(range.upperBound)); used \(format(clamped))") }
            values.append(clamped)
        }
        while values.count < 3 { values.append(0) }
        return SIMD3(values[0], values[1], values[2])
    }

    /// A finite number; numbers written as text are read, anything else is an error.
    private mutating func number(_ raw: Any, at: String) -> Float? {
        if let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, abs(value.doubleValue) < 1e6 {
            return Float(value.doubleValue)
        }
        if let text = raw as? String, let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite, abs(value) < 1e6 {
            repairs.append("\(at): \"\(text)\" read as the number \(format(Float(value)))")
            return Float(value)
        }
        errors.append("\(at): must be a number")
        return nil
    }

    private mutating func flag(_ raw: Any?, at: String) -> Bool {
        guard let raw else { return false }
        if let value = raw as? NSNumber { return value.boolValue }
        if let text = raw as? String, ["true", "yes", "1", "false", "no", "0"].contains(text.lowercased()) {
            repairs.append("\(at): \"\(text)\" read as \(["true", "yes", "1"].contains(text.lowercased()))")
            return ["true", "yes", "1"].contains(text.lowercased())
        }
        repairs.append("\(at): not true or false; read as false")
        return false
    }

    private func text(_ raw: Any?) -> String? {
        if let text = raw as? String { return text }
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }

    private mutating func tint(_ raw: Any?, at: String) -> Scene.Tint {
        guard let name = text(raw)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            repairs.append("\(at): missing; used steel"); return .steel
        }
        if let exact = Scene.Tint(rawValue: name) { return exact }
        let folded = Scene.fold(name)
        if let tint = Scene.Tint.allCases.first(where: { Scene.fold($0.rawValue) == folded }) ?? Scene.colourAliases[folded] {
            repairs.append("\(at): \"\(name)\" read as \(tint.rawValue)"); return tint
        }
        if let rgb = Self.hex(name) {
            let nearest = Scene.Tint.allCases.filter { $0 != .glass }.min { simd_distance(Scene.rgb($0), rgb) < simd_distance(Scene.rgb($1), rgb) }!
            repairs.append("\(at): \(name) read as the nearest palette colour, \(nearest.rawValue)"); return nearest
        }
        repairs.append("\(at): \"\(name)\" isn't a palette colour (\(Scene.Tint.allCases.map(\.rawValue).joined(separator: ", "))); used steel")
        return .steel
    }

    private mutating func finish(_ raw: Any?, at: String) -> Scene.Finish? {
        guard let name = text(raw)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        if let exact = Scene.Finish(rawValue: Scene.fold(name)) {
            if exact.rawValue != name { repairs.append("\(at): \"\(name)\" read as \(exact.rawValue)") }
            return exact
        }
        let near: [String: Scene.Finish] = ["glossy": .polished, "shiny": .polished, "mirror": .polished, "chrome": .polished,
                                            "brushed": .satin, "semigloss": .satin, "rough": .matte, "flat": .matte, "dull": .matte]
        let read = near[Scene.fold(name)] ?? .satin
        repairs.append("\(at): \"\(name)\" read as \(read.rawValue)")
        return read
    }

    /// "#B87333" or "B87333" as 0–1 RGB.
    private static func hex(_ text: String) -> SIMD3<Float>? {
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return SIMD3(Float((value >> 16) & 0xFF), Float((value >> 8) & 0xFF), Float(value & 0xFF)) / 255
    }

    private mutating func shortened(_ text: String, to limit: Int, at: String) -> String {
        guard text.count > limit else { return text }
        var cut = String(text.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 { cut = String(cut[..<space]) }
        cut = cut.trimmingCharacters(in: .whitespaces)
        repairs.append("\(at): longer than \(limit) characters; shortened to \"\(cut)\"")
        return cut
    }

    private func format(_ value: Float) -> String {
        value == value.rounded() && abs(value) < 1e6 ? String(Int(value)) : String(format: "%.3g", value)
    }
}

/// Small plane-geometry helpers for outlines (x, y in a SIMD3 with z unused).
enum CookiePolygon {
    /// Signed area: positive when the points run anticlockwise.
    static func area(_ points: [SIMD3<Float>]) -> Float {
        guard points.count >= 3 else { return 0 }
        var sum: Float = 0
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// Two edges of one closed outline that cross, if any (neighbours share a corner and don't count).
    static func crossing(_ points: [SIMD3<Float>]) -> (Int, Int)? {
        let n = points.count
        for i in 0..<n {
            for j in (i + 1)..<n where j != i + 1 && !(i == 0 && j == n - 1) {
                if segmentsCross(points[i], points[(i + 1) % n], points[j], points[(j + 1) % n]) { return (i, j) }
            }
        }
        return nil
    }

    /// Whether any edge of one closed outline crosses any edge of another.
    static func edgesCross(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Bool {
        for i in a.indices {
            for j in b.indices where segmentsCross(a[i], a[(i + 1) % a.count], b[j], b[(j + 1) % b.count]) { return true }
        }
        return false
    }

    /// Point in polygon by the even–odd rule.
    static func contains(_ polygon: [SIMD3<Float>], _ point: SIMD3<Float>) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    static func segmentsCross(_ p: SIMD3<Float>, _ q: SIMD3<Float>, _ r: SIMD3<Float>, _ s: SIMD3<Float>) -> Bool {
        func side(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        let d1 = side(r, s, p), d2 = side(r, s, q), d3 = side(p, q, r), d4 = side(p, q, s)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }
}
