//
//  CookieBuildModel.swift
//  Cookie
//
//  Building a 3D model before it's shown. The model hands its scene to the
//  `build_model` tool; Cookie reads it with the same forgiving reader as an
//  inline [SCENE {json}], keeps it for the turn under an id, and checks how it
//  will look from the camera the person will see it through: where each part
//  lands on the view, what hides behind what, what sits sealed inside an opaque
//  part, whether labels collide or their leader lines cross, and how the model
//  fills the frame; and for a machine that works, a sampled cycle of its motion
//  (gears that don't touch, a piston that leaves its cylinder, parts that run
//  out of view). The reply then shows it with [SCENE:#id] at its word.
//
//  The check goes back as words, not a picture: a tool result reaching the
//  harness is text only (serve.rs `tool_result.output`), so a PNG would have
//  nowhere to go. The check is worked out from the same numbers the stage
//  draws with (`CookieSceneCamera`, the label rails), off the main thread and
//  inside two seconds.
//

import CoreGraphics
import Foundation
import simd

// MARK: - Camera

/// The default view of a model, shared by the stage that draws it and the check that reads it,
/// so what the check reports is what the person sees.
enum CookieSceneCamera {
    /// The RealityView's size on the card, in points.
    static let viewport = CGSize(width: 520, height: 360)
    /// Vertical field of view, degrees.
    static let fieldOfView: Float = 34
    /// The model starts turned a little to the left, so it reads as a solid, not a silhouette.
    static let turn = simd_quatf(angle: -0.5, axis: [0, 1, 0])
    /// Where the camera looks from: a little above, along +z.
    static let direction = simd_normalize(SIMD3<Float>(0, 0.32, 1))

    /// The radius of a ball around the centroid that holds every part, assembled or exploded.
    static func radius(_ scene: CookieScene, exploded: Bool) -> Float {
        max(0.05, scene.parts.map { simd_length(scene.place(of: $0, exploded: exploded)) + $0.reach }.max() ?? 0.05)
    }

    /// Far enough back that the bounding ball fits the view's height.
    static func eye(radius: Float, zoom: Float = 1) -> SIMD3<Float> {
        let half = fieldOfView / 2 * .pi / 180
        return direction * (radius / sin(half) * 1.12 / zoom)
    }
}

// MARK: - The tool and the turn's models

/// The models built this turn, by id, and how many builds are left. One shelf per harness client;
/// it empties when the next run starts.
@MainActor
final class CookieModelShelf {
    /// One build and two rebuilds a turn; then the model uses what it has. That also bounds the shelf.
    static let buildsPerTurn = 3
    static let maxBody = 200_000

    static let tool = HarnessRequest.Tool(
        name: "build_model",
        description: "Build a 3D model before showing it. scene: the SCENE JSON ({\"title\",\"parts\",\"explode\",\"spin\"}, and for a machine that works \"joints\",\"drives\",\"links\",\"flows\",\"run\"; the same fields as an inline [SCENE {json}]). id: optional; leave it out and the id comes from the title, so a rebuild with the same title replaces the model. Answers {ok, id, show, repairs, errors, issues, render, snapshot, rebuilds_left}: show is the tag to put in the reply at the word where the model should appear ([SCENE:#id]); repairs are what Cookie fixed for you; errors name the part and field that couldn't be built (that part is left out); render reports, from the camera the person sees, each part's box on the 520×360 view, what hides behind what, what is sealed inside an opaque part, label collisions and framing, assembled and exploded, and for a model that moves, motion: what each joint does, whether driven gears touch at the teeth's ratio, whether a piston stays in its cylinder over a whole crank turn, whether moving parts stay in view; issues is the short list worth fixing. Fix errors and issues once and call again if they matter; at most \(buildsPerTurn) calls a turn.",
        effect: "read",
        schema: .init(properties: [
            "scene": .init(description: "the scene as a JSON object encoded as a string"),
            "id": .init(description: "optional short id; lowercase words joined by hyphens"),
        ], required: ["scene"]),
        parallel_safe: false)

    private(set) var models: [String: CookieScene.Reading] = [:]
    private(set) var builds = 0

    /// A new turn: nothing built, every build available again.
    func beginRun() {
        models = [:]
        builds = 0
    }

    /// The reading a SCENE tag stands for: a built model by id ([SCENE:#id]), or an inline scene.
    /// An id nobody built reads as an error naming it, so the reply says the model couldn't be built.
    func reading(_ tag: CookieReplyTag) -> CookieScene.Reading? {
        guard tag.kind == "SCENE" else { return nil }
        guard let id = Self.reference(tag.body) else { return CookieScene.read(tag: tag) }
        guard let built = models[id], var scene = built.scene else {
            let known = models.keys.sorted()
            return .init(scene: nil, repairs: [], errors: ["SCENE:#\(id): no model was built with that id this turn"
                + (known.isEmpty ? "" : "; built: " + known.map { "#" + $0 }.joined(separator: ", "))])
        }
        scene.offset = tag.offset
        return .init(scene: scene, repairs: built.repairs, errors: built.errors)
    }

    func scene(_ tag: CookieReplyTag) -> CookieScene? { reading(tag)?.scene }

    /// The id in "#engine" (or a bare "engine"); nil when the body is a JSON scene.
    static func reference(_ body: String) -> String? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.hasPrefix("{") else { return nil }
        return slug(text.hasPrefix("#") ? String(text.dropFirst()) : text)
    }

    /// Lowercase letters and digits, everything else one hyphen, at most 40 characters; "model" when empty.
    static func slug(_ text: String) -> String {
        var out = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII { out.unicodeScalars.append(scalar) }
            else if !out.isEmpty, out.last != "-" { out.append("-") }
        }
        while out.last == "-" { out.removeLast() }
        let short = String(out.prefix(40))
        let trimmed = short.hasSuffix("-") ? String(short.dropLast()) : short
        return trimmed.isEmpty ? "model" : trimmed
    }

    /// Reads, keeps and checks one scene. The tool result is JSON text; `isError` when nothing could be built
    /// or the turn's builds are used up.
    func build(_ args: [String: Any]) async -> (output: String, isError: Bool) {
        guard builds < Self.buildsPerTurn else {
            let last = models.keys.sorted().first.map { " Show what you have with [SCENE:#\($0)]." } ?? ""
            return (Self.json(["ok": false, "errors": ["build_model: already called \(builds) times this turn (one build and two rebuilds), so this model wasn't built.\(last)"]]), true)
        }
        builds += 1
        let left = Self.buildsPerTurn - builds
        guard let body = Self.body(args) else {
            return (Self.json(["ok": false, "errors": ["scene: missing; pass the SCENE JSON as the scene argument"], "rebuilds_left": left]), true)
        }
        guard body.utf8.count <= Self.maxBody else {
            return (Self.json(["ok": false, "errors": ["scene: \(body.utf8.count) bytes, past the limit of \(Self.maxBody)"], "rebuilds_left": left]), true)
        }
        let deadline = Date().addingTimeInterval(2)
        let (reading, check) = await Task.detached(priority: .userInitiated) { () -> (CookieScene.Reading, CookieSceneCheck.Report?) in
            let reading = CookieScene.read(body)
            return (reading, reading.scene.map { CookieSceneCheck.report($0, until: deadline) })
        }.value
        guard let scene = reading.scene, let check else {
            return (Self.json(["ok": false, "repairs": reading.repairs, "errors": reading.errors, "snapshot": NSNull(), "rebuilds_left": left]), true)
        }
        let given = (args["id"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let id = Self.slug(given.isEmpty ? scene.title : given)
        models[id] = reading
        _ = CookieMeshResources.warm(scene)
        var render: [String: Any] = ["view": check.view, "assembled": check.assembled.lines]
        if let exploded = check.exploded { render["exploded"] = exploded.lines }
        if let motion = check.motion { render["motion"] = motion.lines }
        return (Self.json([
            "ok": true, "id": id, "show": "[SCENE:#\(id)]",
            "repairs": reading.repairs, "errors": reading.errors,
            "issues": check.issues, "render": render,
            "snapshot": NSNull(),
            "snapshot_note": "no picture: tool results here carry text only, so render is the same view described in words",
            "rebuilds_left": left,
        ]), false)
    }

    /// The scene's JSON: a string, an object, or (leniently) the scene's fields given at the top level.
    private static func body(_ args: [String: Any]) -> String? {
        if let text = args["scene"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        let object = args["scene"] as? [String: Any] ?? (args["parts"] != nil ? args.filter { $0.key != "id" } : nil)
        guard let object, let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{\"ok\":false}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - The check

/// How a scene will look from the default camera, worked out from its numbers. Boxes, not pixels:
/// each part is its oriented bounding box projected onto the view, so "hidden" means covered by a
/// nearer opaque part's box (a torus's hole counts as covered).
enum CookieSceneCheck {
    struct Report {
        let view: String
        let assembled: View
        let exploded: View?
        /// What moves and whether it works: gears that touch, a piston that stays in its cylinder,
        /// parts that stay in view over a whole cycle. Nil for a model that doesn't move.
        var motion: View? = nil
        /// What's worth fixing, from every view, without repeats.
        var issues: [String] {
            var seen = Set<String>()
            return (assembled.issues + (exploded?.issues ?? []) + (motion?.issues ?? [])).filter { seen.insert($0).inserted }
        }
    }

    struct View {
        var lines: [String] = []
        var issues: [String] = []
    }

    /// One part as the camera sees it.
    struct Placed {
        let part: CookieScene.Part
        /// On the view, top-left origin, points.
        let box: CGRect
        /// The part's origin on the view (where its label's leader ends).
        let anchor: CGPoint
        /// Distance from the camera to the part's origin, along the view.
        let depth: Float
        let low: SIMD3<Float>, high: SIMD3<Float>
        var opaque: Bool { !part.cut && part.tint != .glass }
        var volume: Float { let side = simd_max(high - low, .zero); return side.x * side.y * side.z }
    }

    /// Labels on screen at once, as `CookieSceneLabels` shows them.
    static let shownLabels = 6

    static func report(_ scene: CookieScene, until deadline: Date) -> Report {
        let size = CookieSceneCamera.viewport
        let yaw = Int((CookieSceneCamera.turn.angle * 180 / .pi).rounded())
        let pitch = Int((atan2(CookieSceneCamera.direction.y, CookieSceneCamera.direction.z) * 180 / .pi).rounded())
        let view = "\(Int(size.width))×\(Int(size.height)) pt view, x right and y down from the top-left; the model turned \(yaw)° to the left, seen from \(pitch)° above"
        return Report(view: view, assembled: check(scene, exploded: false, until: deadline),
                      exploded: scene.explode ? check(scene, exploded: true, until: deadline) : nil,
                      motion: scene.hasMotion ? motion(scene, until: deadline) : nil)
    }

    /// The pose the person first sees: every joint unturned, every link solved.
    static func startPose(_ scene: CookieScene) -> [String: CookieSceneMotion.Placement] {
        scene.moves ? CookieSceneMotion.pose(scene, turns: CookieSceneMotion.turns(scene, time: 0)) : [:]
    }

    static func place(_ scene: CookieScene, exploded: Bool, pose: [String: CookieSceneMotion.Placement]? = nil) -> [Placed] {
        let pose = pose ?? startPose(scene)
        let size = CookieSceneCamera.viewport
        let eye = CookieSceneCamera.eye(radius: CookieSceneCamera.radius(scene, exploded: exploded))
        let forward = simd_normalize(-eye)
        let right = simd_normalize(simd_cross(forward, [0, 1, 0]))
        let up = simd_cross(right, forward)
        let focal = Float(size.height) / 2 / tan(CookieSceneCamera.fieldOfView / 2 * .pi / 180)
        func project(_ point: SIMD3<Float>) -> (CGPoint, Float) {
            let d = point - eye
            let z = max(0.001, simd_dot(d, forward))
            return (CGPoint(x: Double(Float(size.width) / 2 + simd_dot(d, right) / z * focal),
                            y: Double(Float(size.height) / 2 - simd_dot(d, up) / z * focal)), z)
        }
        return scene.parts.map { part in
            let placement = CookieSceneMotion.placed(scene, part, pose: pose, explosion: exploded ? 1 : 0)
            let origin = placement.position
            let local = CookieScene.bounds(of: part.form)
            var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
            var minX = CGFloat.greatestFiniteMagnitude, minY = minX, maxX = -minX, maxY = -minX
            for corner in 0..<8 {
                let q = SIMD3<Float>(corner & 1 == 0 ? local.min.x : local.max.x, corner & 2 == 0 ? local.min.y : local.max.y,
                                     corner & 4 == 0 ? local.min.z : local.max.z)
                let world = CookieSceneCamera.turn.act(origin + placement.orientation.act(q))
                low = simd_min(low, world); high = simd_max(high, world)
                let (p, _) = project(world)
                minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            let (anchor, depth) = project(CookieSceneCamera.turn.act(origin))
            return Placed(part: part, box: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                          anchor: anchor, depth: depth, low: low, high: high)
        }
    }

    static func check(_ scene: CookieScene, exploded: Bool, until deadline: Date) -> View {
        let size = CookieSceneCamera.viewport
        let frame = CGRect(origin: .zero, size: size)
        let placed = place(scene, exploded: exploded)
        let state = exploded ? "exploded" : "assembled"
        var view = View()
        func name(_ p: Placed) -> String { p.part.label.map { "\(p.part.id) (\"\($0)\")" } ?? p.part.id }
        func pt(_ value: CGFloat) -> Int { Int(value.rounded()) }

        // Framing.
        let whole = placed.map(\.box).reduce(CGRect.null) { $0.union($1) }
        let shown = whole.intersection(frame)
        view.lines.append("\(state): the model spans x \(pt(whole.minX))–\(pt(whole.maxX)), y \(pt(whole.minY))–\(pt(whole.maxY)), filling \(pt(shown.width / size.width * 100))% of the width and \(pt(shown.height / size.height * 100))% of the height")
        if !frame.insetBy(dx: -2, dy: -2).contains(whole) { view.issues.append("\(state): part of the model runs off the view") }

        // Each part: its box, and how much of it nearer opaque parts cover.
        var cutShort = false
        for p in placed {
            if Date() > deadline { cutShort = true; break }
            var line = "\(name(p)): x \(pt(p.box.minX))–\(pt(p.box.maxX)), y \(pt(p.box.minY))–\(pt(p.box.maxY)) (\(pt(p.box.width))×\(pt(p.box.height)) pt), depth \(String(format: "%.2f", p.depth))"
            let nearer = placed.filter { $0.part.id != p.part.id && $0.opaque && $0.depth < p.depth && $0.box.intersects(p.box) }
            var covered = 0, by: [String: Int] = [:]
            let steps = 10
            for i in 0..<steps { for j in 0..<steps {
                let sample = CGPoint(x: p.box.minX + (CGFloat(i) + 0.5) / CGFloat(steps) * p.box.width,
                                     y: p.box.minY + (CGFloat(j) + 0.5) / CGFloat(steps) * p.box.height)
                let over = nearer.filter { $0.box.contains(sample) }
                if !over.isEmpty { covered += 1 }
                for o in over { by[o.part.id, default: 0] += 1 }
            } }
            let visible = 100 - covered
            line += ", \(visible)% in view"
            let behind = by.filter { $0.value >= 25 }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
            if !behind.isEmpty { line += ", behind " + behind.joined(separator: ", ") }
            if p.part.cut || p.part.tint == .glass { line += ", see-through" }
            view.lines.append(line)
            if p.part.label != nil, visible < 15 {
                view.issues.append("\(state): \(name(p)) is hidden behind \(behind.first ?? "nearer parts"); move it, or make what covers it cut")
            }
            if p.part.label != nil, p.box.width < 6 || p.box.height < 6 {
                view.issues.append("\(state): \(name(p)) is \(pt(p.box.width))×\(pt(p.box.height)) pt, too small to see; make it bigger or the model smaller")
            }
        }

        // In space: parts sealed inside an opaque part, and parts sitting in the same place.
        for a in placed {
            if cutShort || Date() > deadline { cutShort = true; break }
            for b in placed where a.part.id != b.part.id {
                if a.opaque, a.volume > b.volume, all(b.low .>= a.low - 0.001), all(b.high .<= a.high + 0.001), encloses(a, b) {
                    view.lines.append("\(b.part.id) sits inside \(a.part.id)")
                    if !exploded { view.issues.append("\(name(b)) is sealed inside \(a.part.id), which is opaque; set \(a.part.id) \"cut\":true (or explode the model) to show it") }
                }
                if a.part.id < b.part.id, a.part.shape == b.part.shape, simd_distance(a.low + a.high, b.low + b.high) / 2 < 0.01 * CookieSceneCamera.radius(scene, exploded: exploded),
                   simd_distance(a.high - a.low, b.high - b.low) < 0.01 {
                    view.issues.append("\(state): \(a.part.id) and \(b.part.id) are the same shape in the same place, so one hides the other")
                }
            }
        }

        // Labels: the last six named stay up, on two rails, with leaders to their parts.
        let labelled = placed.filter { $0.part.label != nil }
        let visible = Array(labelled.suffix(shownLabels))
        if labelled.count > shownLabels { view.lines.append("labels: \(labelled.count) labelled parts; six show at once, earlier ones give way as later ones are named") }
        let pills = visible.enumerated().map { index, p in pill(p.part.label ?? "", at: CookieSceneLabelLayout.centre(index: index, count: visible.count, size: size)) }
        for (i, p) in visible.enumerated() {
            if !frame.contains(p.anchor) { view.issues.append("\(state): \(name(p))'s point is off the view") }
            for (k, other) in pills.enumerated() where k != i && other.insetBy(dx: -2, dy: -2).contains(p.anchor) {
                view.issues.append("\(state): the label \"\(visible[k].part.label ?? "")\" covers the point of \(name(p))")
            }
            for j in visible.indices where j > i {
                let q = visible[j]
                if pills[i].intersects(pills[j]) { view.issues.append("\(state): the labels \"\(p.part.label ?? "")\" and \"\(q.part.label ?? "")\" overlap; shorten them") }
                if hypot(p.anchor.x - q.anchor.x, p.anchor.y - q.anchor.y) < 12 {
                    view.issues.append("\(state): \(name(p)) and \(name(q)) point at nearly the same spot")
                }
                let a = [p.anchor, pills[i].centre].map { SIMD3<Float>(Float($0.x), Float($0.y), 0) }
                let b = [q.anchor, pills[j].centre].map { SIMD3<Float>(Float($0.x), Float($0.y), 0) }
                if CookiePolygon.segmentsCross(a[0], a[1], b[0], b[1]) {
                    view.lines.append("labels: the leaders of \(p.part.id) and \(q.part.id) cross")
                }
            }
        }
        if !visible.isEmpty {
            view.lines.append("labels: " + visible.enumerated().map { index, p in
                "\"\(p.part.label ?? "")\" on the \(index % 2 == 0 ? "left" : "right") at y \(pt(pills[index].midY)), pointing to (\(pt(p.anchor.x)), \(pt(p.anchor.y)))"
            }.joined(separator: "; "))
        }
        if cutShort { view.lines.append("check cut short at two seconds; the rest wasn't checked") }
        return view
    }

    // MARK: Motion

    /// Round parts, whose own axis is y: turned about anything else they tumble.
    static let round: Set<CookieScene.Shape> = [.gear, .bevelGear, .bladeRing, .wheel, .propeller, .bearing, .shaft, .tube,
                                                .cylinder, .cone, .torus, .spring, .screw, .lathe, .piston, .valve, .capsule]

    private static func f(_ value: Float) -> String { String(format: "%.3g", value) }
    private static func v(_ value: SIMD3<Float>) -> String { "[\(f(value.x + 0)), \(f(value.y + 0)), \(f(value.z + 0))]" }
    private static func degrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Int {
        Int((acos(min(1, abs(simd_dot(simd_normalize(a), simd_normalize(b))))) * 180 / .pi).rounded())
    }

    /// What moves, sampled over its cycle: what each joint does, whether driven gears touch and agree
    /// with their teeth, whether a piston stays in its cylinder over a whole crank turn, whether
    /// moving parts stay in view, and what each flow runs through.
    static func motion(_ scene: CookieScene, until deadline: Date) -> View {
        var view = View()
        var byID: [String: CookieScene.Part] = [:]
        for part in scene.parts where byID[part.id] == nil { byID[part.id] = part }
        let perSecond = CookieSceneMotion.turns(scene, time: 1)
        let drivers = Dictionary(scene.drives.map { ($0.to, $0) }, uniquingKeysWith: { a, _ in a })

        // Joints.
        for joint in scene.joints {
            let rate = perSecond[joint.id] ?? joint.rate
            let moved = joint.members.joined(separator: ", ")
            var line = switch joint.kind {
            case .slide: "\(joint.id): slides \(f(joint.travel)) along \(v(joint.axis)), \(f(abs(rate))) strokes a second, moving \(moved)"
            case .spin, .crank: "\(joint.id): \(joint.kind == .crank ? "cranks" : "spins") about \(v(joint.axis)) through \(v(joint.pivot)) at \(f(abs(rate))) turns a second\(rate < 0 ? " backward" : ""), moving \(moved)"
            }
            if let drive = drivers[joint.id] { line += "; driven by \(drive.from) at ratio \(f(drive.ratio))" }
            view.lines.append(line)
            guard joint.kind != .slide else { continue }
            for id in joint.members {
                guard let part = byID[id], round.contains(part.shape) else { continue }
                let own = part.orientation.act(SIMD3<Float>(0, 1, 0))
                let off = degrees(own, joint.axis)
                if off > 8 {
                    view.issues.append("motion: \(id) turns about \(v(joint.axis)), \(off)° off its own axis \(v(own)), so it tumbles instead of spinning; set \(joint.id)'s axis to \(v(own)) or turn \(id)")
                } else if joint.members.count == 1 {
                    let out = part.position - joint.pivot
                    let across = simd_length(out - joint.axis * simd_dot(out, joint.axis))
                    if across > max(0.002, part.reach * 0.02) {
                        view.issues.append("motion: \(id) spins about a point \(f(across)) off its middle, so it swings round; leave out \(joint.id)'s \"at\" or set it to \(id)'s position")
                    }
                }
            }
        }

        // Drives between gears: they must touch at their pitch circles, in one plane, at the teeth's ratio.
        for (index, drive) in scene.drives.enumerated() {
            guard let a = scene.joints.first(where: { $0.id == drive.from }), let b = scene.joints.first(where: { $0.id == drive.to }) else { continue }
            view.lines.append("drives[\(index)]: \(a.id) turns \(b.id) \(f(drive.ratio)) times a turn")
            let pa = scene.parts(named: a.part), pb = scene.parts(named: b.part)
            guard pa.count == 1, pb.count == 1, [.gear, .bevelGear].contains(pa[0].shape), [.gear, .bevelGear].contains(pb[0].shape) else { continue }
            let ga = pa[0], gb = pb[0]
            let expected = -ga.form["teeth"] / gb.form["teeth"]
            if abs(drive.ratio - expected) > 0.02 * abs(expected) {
                view.issues.append("drives[\(index)]: ratio \(f(drive.ratio)) doesn't match the teeth (\(Int(ga.form["teeth"])) to \(Int(gb.form["teeth"])) gives \(f(expected)); meshing gears turn opposite ways), so the teeth would slip")
            }
            guard ga.shape == .gear, gb.shape == .gear else { continue }
            if degrees(a.axis, b.axis) > 3 {
                view.issues.append("drives[\(index)]: \(ga.id) and \(gb.id) turn about axes \(degrees(a.axis, b.axis))° apart; spur gears mesh on parallel axes (bevel gears for an angle)")
                continue
            }
            let delta = gb.position - ga.position
            let axial = simd_dot(delta, a.axis)
            let apart = simd_length(delta - a.axis * axial)
            let pitch = ga.form["radius"] + gb.form["radius"]
            let tolerance = (CookieScene.gearRadii(ga.form).module + CookieScene.gearRadii(gb.form).module) / 4
            if apart - pitch > tolerance {
                view.issues.append("drives[\(index)]: \(ga.id) and \(gb.id) don't touch: their centres are \(f(apart)) apart but their radii add to \(f(pitch)), a gap of \(f(apart - pitch)); put them \(f(pitch)) apart so the teeth mesh")
            } else if pitch - apart > tolerance {
                view.issues.append("drives[\(index)]: \(ga.id) and \(gb.id) overlap by \(f(pitch - apart)): their centres are \(f(apart)) apart but their radii add to \(f(pitch)); put them \(f(pitch)) apart")
            }
            if abs(axial) > (ga.form["thickness"] + gb.form["thickness"]) / 2 {
                view.issues.append("drives[\(index)]: \(ga.id) and \(gb.id) sit \(f(abs(axial))) apart along their axis, so their teeth miss; put them in one plane")
            }
        }

        // Slider-cranks: a whole turn of the crank, in 36 steps.
        let samples = 36
        for link in scene.links {
            if Date() > deadline { view.lines.append("motion check cut short at two seconds"); return view }
            guard let joint = scene.joints.first(where: { $0.id == link.joint }), let piston = byID[link.piston] else { continue }
            let solved = (0..<samples).map { CookieSceneMotion.solve(link, axis: joint.axis, pivot: joint.pivot, turns: Float($0) / Float(samples)) }
            let travels = solved.map(\.travel)
            let stroke = (travels.max() ?? 0) - (travels.min() ?? 0)
            view.lines.append("link \(link.crank) → \(link.rod) → \(link.piston): the piston strokes \(f(stroke)) along \(v(link.direction))")
            let own = piston.orientation.act(SIMD3<Float>(0, 1, 0))
            if [.piston, .cylinder].contains(piston.shape), degrees(own, link.direction) > 8 {
                view.issues.append("motion: \(piston.id)'s own axis is \(degrees(own, link.direction))° off the line it slides on \(v(link.direction)); turn it to slide along its length")
            }
            let exclude: Set<String> = [link.crank, link.rod, link.piston]
            let start = solved[0].wrist
            func bore(_ part: CookieScene.Part) -> (axis: SIMD3<Float>, half: Float, radius: Float)? {
                let axis = simd_normalize(part.orientation.act(SIMD3<Float>(0, 1, 0)))
                switch part.shape {
                case .tube: return (axis, part.form["length"] / 2, part.form["inner"])
                case .cylinder: return (axis, part.form["height"] / 2, part.form["radius"])
                default: return nil
                }
            }
            func radial(_ point: SIMD3<Float>, _ part: CookieScene.Part, _ axis: SIMD3<Float>) -> Float {
                let out = point - part.position
                return simd_length(out - axis * simd_dot(out, axis))
            }
            let found = link.cylinder.flatMap { byID[$0] } ?? scene.parts
                .filter { !exclude.contains($0.id) && bore($0) != nil }
                .filter { degrees(bore($0)!.axis, link.direction) < 18 && radial(start, $0, bore($0)!.axis) < bore($0)!.radius }
                .min { simd_distance($0.position, start) < simd_distance($1.position, start) }
            guard let cylinder = found, let hole = bore(cylinder) else {
                view.lines.append("no cylinder found round \(link.piston); name one in the link (\"cylinder\") to have it checked")
                continue
            }
            let pistonHalf = [.piston, .cylinder].contains(piston.shape) ? piston.form["height"] / 2 : piston.reach
            let pistonRadius = [.piston, .cylinder].contains(piston.shape) ? piston.form["radius"] : piston.reach
            if pistonRadius > hole.radius * 1.02 {
                view.issues.append("motion: \(piston.id) (radius \(f(pistonRadius))) is wider than \(cylinder.id)'s bore (\(f(hole.radius))); make the piston a little narrower than the bore")
            }
            var worst: (over: Float, degrees: Int) = (0, 0), offBore: Float = 0
            for (k, sample) in solved.enumerated() {
                let along = simd_dot(sample.wrist - cylinder.position, hole.axis)
                let over = abs(along) + pistonHalf - hole.half
                if over > worst.over { worst = (over, k * 360 / samples) }
                offBore = max(offBore, radial(sample.wrist, cylinder, hole.axis) + min(pistonRadius, hole.radius) - hole.radius)
            }
            let tolerance = max(0.001, hole.half * 0.02)
            if worst.over > tolerance {
                view.issues.append("motion: \(piston.id) leaves \(cylinder.id) by up to \(f(worst.over)) near crank angle \(worst.degrees)°; the stroke is \(f(stroke)) plus the piston's \(f(pistonHalf * 2)), so lengthen or move \(cylinder.id)")
            } else if offBore > tolerance {
                view.issues.append("motion: \(piston.id) runs off \(cylinder.id)'s bore by \(f(offBore)); line \(cylinder.id) up with the stroke \(v(link.direction))")
            } else {
                view.lines.append("\(link.piston) stays inside \(cylinder.id) over the whole turn")
            }
        }

        // A cycle of the slowest free joint, in twelve steps: moving parts stay in view.
        if scene.moves {
            let driven = Set(scene.drives.map(\.to))
            let slowest = scene.joints.filter { !driven.contains($0.id) }.map { abs($0.rate) }.min() ?? CookieScene.defaultRate
            let period = min(10, 1 / max(0.01, slowest))
            let frame = CGRect(origin: .zero, size: CookieSceneCamera.viewport).insetBy(dx: -2, dy: -2)
            var gone: [String] = []
            for k in 0..<12 {
                if Date() > deadline { view.lines.append("motion check cut short at two seconds"); return view }
                let pose = CookieSceneMotion.pose(scene, turns: CookieSceneMotion.turns(scene, time: Float(k) / 12 * period))
                for p in place(scene, exploded: false, pose: pose) where pose[p.part.id] != nil && !frame.contains(p.box) && !gone.contains(p.part.id) {
                    gone.append(p.part.id)
                }
            }
            if !gone.isEmpty { view.issues.append("motion: while it runs, \(gone.joined(separator: ", ")) leave\(gone.count == 1 ? "s" : "") the view; make the model smaller or the travel shorter") }
        }

        // Flows: the route each runs, and how many beads it gets.
        let paths = scene.flows.map { CookieSceneMotion.path(scene, $0, explosion: 0) }
        let counts = CookieSceneMotion.beadCounts(scene, lengths: paths.map(\.length))
        for (index, flow) in scene.flows.enumerated() {
            view.lines.append("flow \(flow.id): \(flow.through.joined(separator: " → "))\(flow.loop ? " and round again" : ""), \(f(paths[index].length)) long, \(counts[index]) beads at \(f(flow.speed)) a second\(flow.on ? "" : ", off until [VISUAL:flow:\(flow.id):on]"); an illustration of the route, not a simulation")
        }
        return view
    }

    /// b fits inside a's own shape, not just its box: a tube or bearing has a bore, an extrude may have holes,
    /// a pipe or sweep is a path; those don't seal what sits in them.
    private static func encloses(_ a: Placed, _ b: Placed) -> Bool {
        switch a.part.shape {
        case .tube, .bearing, .torus, .pipe, .sweep, .spring, .wheel, .bladeRing, .propeller, .rack, .arrow, .crank, .rod: return false
        case .gear, .bevelGear: return a.part.form["bore"] <= 0
        case .extrude: return a.part.form.holes.isEmpty
        default: return true
        }
    }

    /// A label pill's rect, sized like `CookieSceneLabels` draws it (11 pt rounded, up to 130 pt wide, two lines).
    static func pill(_ label: String, at centre: CGPoint) -> CGRect {
        let text = CGFloat(label.count) * 6.2
        let lines: CGFloat = text > 130 ? 2 : 1
        let width = min(130, text) + 8, height = 15 * lines + 8
        return CGRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height)
    }
}

private extension CGRect {
    var centre: CGPoint { CGPoint(x: midX, y: midY) }
}
