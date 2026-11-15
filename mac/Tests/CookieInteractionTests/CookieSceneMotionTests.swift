import CoreGraphics
import Foundation
import RealityKit
import simd

/// Motion, flow and the camera: joints, drives, links and flows read forgivingly (each repair and
/// error named); the slider-crank is exact at every angle; beads follow a smooth path through the
/// named parts and stay capped; the camera spring keeps its speed when retargeted and gives way to
/// the person; the new [VISUAL:…] verbs parse and drive the stage from a real reply; Reduce Motion
/// holds a still pose with arrows and cuts the camera; build_model samples the cycle and names gears
/// that don't touch and a piston that leaves its cylinder; and the prompt's jet engine spins and flows.
@MainActor
enum CookieSceneMotionTests {
    private static var count = 0
    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        count += 1
    }

    private static func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-4) -> Bool { simd_distance(a, b) < tolerance }

    static let gears = #"""
    {"title":"Gear pair","parts":[
    {"id":"big","label":"driver","shape":"gear","radius":0.3,"teeth":24,"thickness":0.06,"color":"brass"},
    {"id":"small","label":"pinion","shape":"gear","radius":0.15,"teeth":12,"thickness":0.06,"position":[0.45,0,0],"color":"steel"}],
    "joints":[{"id":"drive","kind":"spin","part":"big","axis":[0,1,0],"rate":0.5}],
    "drives":[{"from":"drive","to":"small"}]}
    """#

    /// A single-cylinder engine: the crank turns about z under a piston in a cut tube.
    static func engine(cylinderLength: Float = 0.6) -> String {
        #"""
        {"title":"One cylinder","parts":[
        {"id":"crank","label":"crank","shape":"crank","throw":0.15,"radius":0.05,"thickness":0.05,"rotation":[90,0,0],"color":"graphite"},
        {"id":"rod","label":"rod","shape":"rod","length":0.5,"radius":0.05,"small":0.035,"thickness":0.04,"color":"steel"},
        {"id":"piston","label":"piston","shape":"piston","radius":0.1,"height":0.15,"position":[0,0.5,0],"color":"steel"},
        {"id":"bore","shape":"tube","radius":0.13,"inner":0.105,"length":\#(cylinderLength),"position":[0,0.5,0],"color":"glass","cut":true}],
        "joints":[{"id":"shaft","kind":"crank","part":"crank","axis":[0,0,1],"rate":0.5}],
        "links":[{"crank":"crank","rod":"rod","piston":"piston","cylinder":"bore"}]}
        """#
    }

    static func run() async {
        count = 0
        reading()
        kinematics()
        flows()
        camera()
        verbs()
        stage()
        stillness()
        await checks()
        example()
        print("\(count) scene motion checks passed.")
    }

    // MARK: Reading

    private static func reading() {
        let pair = CookieScene.read(gears)
        let scene = pair.scene!
        check(scene.joints.count == 2 && scene.drives == [.init(from: "drive", to: "small", ratio: -2)],
              "a gear with no joint, driven, gets one; the ratio comes from the teeth: \(scene.joints.map(\.id)) \(scene.drives)")
        check(pair.repairs.contains { $0.contains("drives[0].to: small had no joint") } && pair.repairs.contains { $0.contains("used -2 from the teeth") },
              "and both repairs are said: \(pair.repairs)")
        check(pair.errors.isEmpty, "with nothing left out: \(pair.errors)")

        let loose = CookieScene.read(#"""
        {"title":"T","parts":[{"id":"Fan","shape":"bladeRing","rotation":[0,0,90],"color":"steel"},{"id":"b","shape":"box","color":"steel"},
        {"id":"c","shape":"box","position":[1,0,0],"color":"steel"}],
        "joints":[{"part":"fan","kind":"rotate","rate":9},{"id":"j2","kind":"wobble","part":"b"},{"id":"j3","part":"nothing"},
        {"id":"j4","part":"c","kind":"spin","axis":[0,0,0]},{"id":"j5","part":"Fan","kind":"spin"},{"id":"j6","part":"c","kind":"slide","axis":[1,0,0],"rate":0}],
        "drives":[{"from":"j6","to":"joint1","ratio":0},{"from":"joint1","to":"joint1"}],
        "flows":[{"through":["Fan","ghost"]},{"id":"f2","through":["Fan","c"],"speed":99}]}
        """#)
        let s = loose.scene!
        check(s.joints.map(\.id) == ["joint1", "j6"] && s.joints[0].part == "Fan" && s.joints[0].kind == .spin && s.joints[0].rate == 3,
              "a loose joint is repaired (id named, part read, kind alias, rate clamped): \(s.joints)")
        check(close(s.joints[0].axis, [-1, 0, 0]) && loose.repairs.contains { $0.contains("joints.joint1.axis: missing; used Fan's own axis") },
              "a missing axis is the part's own, and said: \(s.joints[0].axis)")
        check(s.joints[1].rate == CookieScene.defaultRate && loose.repairs.contains { $0.contains("joints.j6.rate: 0 doesn't move") }, "a rate of 0 is repaired")
        for expected in ["joints.j2.kind: \"wobble\" isn't spin, slide or crank", "joints.j3.part: \"nothing\" isn't a part or group",
                         "joints.j4.axis: zero length", "joints.j5.part: Fan is already moved by joint1",
                         "drives[0].ratio: 0 never turns", "drives[1]: joint1 can't drive itself",
                         "flows.flow1.through: needs at least two parts"] {
            check(loose.errors.contains { $0.contains(expected) }, "named and left out: \(expected) in \(loose.errors)")
        }
        check(s.flows.map(\.id) == ["f2"] && s.flows[0].speed == 3 && loose.repairs.contains { $0.contains("flows.flow1.through[1]: \"ghost\" isn't a part") },
              "a flow drops a name it can't find and clamps its speed")

        // A loop of drives, and a joint driven twice, are refused.
        let looped = CookieScene.read(#"""
        {"parts":[{"id":"a","shape":"wheel","color":"steel"},{"id":"b","shape":"wheel","position":[1,0,0],"color":"steel"},{"id":"c","shape":"wheel","position":[2,0,0],"color":"steel"}],
        "joints":[{"id":"ja","part":"a","kind":"spin"},{"id":"jb","part":"b","kind":"spin"},{"id":"jc","part":"c","kind":"spin"}],
        "drives":[{"from":"ja","to":"jb","ratio":1},{"from":"jb","to":"jc","ratio":1},{"from":"jc","to":"ja","ratio":1},{"from":"ja","to":"jc","ratio":2}]}
        """#)
        check(looped.errors.contains { $0.contains("jc → ja closes a loop") } && looped.errors.contains { $0.contains("jc is already driven by jb") }
              && looped.scene!.drives.count == 2, "cycles and second drivers are named: \(looped.errors)")

        // Links: a rod too short to clear the throw, a crank with no joint.
        let short = CookieScene.read(engine().replacingOccurrences(of: #""length":0.5,"radius":0.05,"small""#, with: #""length":0.12,"radius":0.05,"small""#))
        check(short.errors.contains { $0.contains("links[0].rod: rod is 0.12") && $0.contains("can't turn") } && short.scene!.links.isEmpty,
              "a rod shorter than the throw can't work and says so: \(short.errors)")
        let unjointed = CookieScene.read(engine().replacingOccurrences(of: #""joints":[{"id":"shaft","kind":"crank","part":"crank","axis":[0,0,1],"rate":0.5}],"#, with: ""))
        check(unjointed.errors.contains { $0.contains("links[0].crank: crank isn't turned by a joint") }, "a link needs its crank turned: \(unjointed.errors)")
        check(CookieScene.read(engine()).errors.isEmpty && CookieScene.read(engine()).repairs.isEmpty, "the engine reads cleanly: \(CookieScene.read(engine()).repairs)")
    }

    // MARK: Kinematics

    private static func kinematics() {
        let scene = CookieScene.read(gears).scene!
        let quarter = CookieSceneMotion.turns(scene, time: 0.5) // 0.5 turns a second for half a second
        check(abs(quarter["drive"]! - 0.25) < 1e-6 && abs(quarter["small"]! + 0.5) < 1e-6, "the pinion turns twice as fast the other way: \(quarter)")
        let pose = CookieSceneMotion.pose(scene, turns: quarter)
        check(close(pose["small"]!.position, [0.45, 0, 0]) && close(pose["small"]!.orientation.act([1, 0, 0]), [-1, 0, 0]),
              "a gear turns about its own middle: \(pose["small"]!)")

        let engine = CookieScene.read(engine()).scene!
        let link = engine.links[0], joint = engine.joints[0]
        var travels: [Float] = []
        for k in 0..<72 {
            let turns = Float(k) / 72
            let solved = CookieSceneMotion.solve(link, axis: joint.axis, pivot: joint.pivot, turns: turns)
            travels.append(solved.travel)
            let pose = CookieSceneMotion.pose(engine, turns: ["shaft": turns])
            let rod = pose["rod"]!, piston = pose["piston"]!
            // The rod's own eyes (big end at −y, small at +y) land on the pin and the piston pin.
            let big = rod.position + rod.orientation.act([0, -link.length / 2, 0]), small = rod.position + rod.orientation.act([0, link.length / 2, 0])
            precondition(close(big, solved.pin, 1e-4) && close(small, piston.position, 1e-4), "rod ends on the pin and piston at \(k)")
            precondition(abs(piston.position.x) < 1e-5 && abs(piston.position.z) < 1e-5, "the piston stays on its line at \(k)")
            let crank = pose["crank"]!
            precondition(close(crank.position + crank.orientation.act([0.15, 0.0625, 0]), solved.pin, 1e-4), "the pin turns with the crank at \(k)")
        }
        check(true, "over a whole turn the rod's eyes stay exactly on the crankpin and piston pin, the piston on its line")
        let stroke = travels.max()! - travels.min()!
        check(abs(stroke - 0.3) < 0.002, "an in-line slider-crank strokes twice its throw: \(stroke)")
        check(abs(CookieSceneMotion.stepSeconds(engine) - 1 / 6) < 1e-6, "a step is a twelfth of a turn")
        let still = CookieSceneMotion.representative(engine, steps: 0)
        check(abs(still["shaft"]! - 1 / 6) < 1e-6 && abs(CookieSceneMotion.representative(engine, steps: 3)["shaft"]! - 5 / 12) < 1e-6,
              "the still pose is a sixth of a turn on, a twelfth more each step")
    }

    // MARK: Flows

    private static func flows() {
        let points: [SIMD3<Float>] = [[0, 0, 0], [1, 0, 0], [1, 1, 0], [2, 1, 0]]
        let path = CookieFlowPath(through: points, loop: false)
        check(close(path.point(at: 0), points[0]) && close(path.point(at: path.length), points[3]), "an open path runs from the first part to the last")
        check(points.allSatisfy { p in (0...200).contains { close(path.point(at: Float($0) / 200 * path.length), p, 0.03) } },
              "and through every part's middle")
        check(path.length > 3 && path.length < 3.6, "smoothly, not far round: \(path.length)")
        let loop = CookieFlowPath(through: points, loop: true)
        check(close(loop.point(at: loop.length + 0.1), loop.point(at: 0.1)) && close(loop.point(at: -0.1), loop.point(at: loop.length - 0.1)),
              "a loop wraps round")
        check(abs(simd_length(path.tangent(at: 0.5)) - 1) < 1e-4 && simd_dot(path.tangent(at: 0.2), [1, 0, 0]) > 0.9, "the tangent runs the way it goes")

        // Beads: density along the length, at least four, capped per flow and in all.
        let many = CookieScene.read(#"""
        {"parts":[{"id":"a","shape":"sphere","color":"sky"},{"id":"b","shape":"sphere","position":[9,0,0],"color":"sky"}],
        "flows":[{"id":"f1","through":["a","b"],"density":40},{"id":"f2","through":["a","b"],"density":40},{"id":"f3","through":["b","a"],"density":40},{"id":"short","through":["a","b"],"density":1}]}
        """#).scene!
        let lengths = many.flows.map { CookieSceneMotion.path(many, $0, explosion: 0).length }
        let counts = CookieSceneMotion.beadCounts(many, lengths: lengths)
        check(counts.reduce(0, +) <= CookieScene.maxBeads && counts.allSatisfy { $0 <= CookieScene.maxBeadsPerFlow && $0 >= 2 }, "beads are capped: \(counts)")
        let flow = many.flows[0], one = CookieSceneMotion.path(many, flow, explosion: 0)
        let a = CookieSceneMotion.bead(0, of: 10, flow: flow, path: one, time: 0), b = CookieSceneMotion.bead(0, of: 10, flow: flow, path: one, time: 1)
        check(abs((b.s - a.s) - flow.speed) < 1e-4 && a.fade < 0.05, "a bead moves at the flow's speed and fades in at the start")
    }

    // MARK: Camera

    private static func camera() {
        var spring = CookieSpring3D(position: .zero, duration: 0.6)
        spring.target = [1, 0, 0]
        for _ in 0..<12 { spring.step(seconds: 1.0 / 60) }
        let before = spring.velocity
        spring.target = [1, 1, 0]
        check(spring.velocity == before && before.x > 0, "retargeting keeps the speed it had")
        var mid = spring
        mid.step(seconds: 1.0 / 60)
        check(mid.velocity.x > 0 && simd_length(mid.velocity - before) < simd_length(before), "and bends toward the new shot instead of restarting")
        for _ in 0..<240 { spring.step(seconds: 1.0 / 120) }
        check(spring.isSettled && simd_distance(spring.position, [1, 1, 0]) < 1e-3, "then settles there")
        var halves = CookieSpring3D(position: .zero), whole = CookieSpring3D(position: .zero)
        halves.target = [1, 2, 3]; whole.target = [1, 2, 3]
        for _ in 0..<12 { halves.step(seconds: 1.0 / 120) }
        for _ in 0..<6 { whole.step(seconds: 1.0 / 60) }
        check(simd_distance(halves.position, whole.position) < 1e-9, "120 Hz and 60 Hz take the same path")

        let turn = CookieSceneCamera.turn
        var rig = CookieSceneCameraRig(overview: 4)
        check(close(rig.eye(), CookieSceneCamera.eye(radius: 4 * sin(CookieSceneCamera.fieldOfView / 2 * .pi / 180) / 1.12), 1e-4),
              "the overview is the default camera the build check sees through: \(rig.eye())")
        rig.show(.side, turn: turn, overview: 4, instantly: false)
        rig.step(1.0 / 60, turn: turn)
        check(!rig.isSettled && simd_length(rig.eye()) > 3.9, "a preset view swings round, keeping its distance")
        for _ in 0..<300 { rig.step(1.0 / 60, turn: turn) }
        let side = simd_normalize(rig.eye())
        check(simd_dot(side, simd_normalize(turn.act([1, 0.12, 0]))) > 0.999, "side looks from the model's own +x: \(side)")
        rig.show(.top, turn: turn, overview: 4, instantly: true)
        check(rig.isSettled && simd_normalize(rig.eye()).y > 0.98, "top looks from above, a cut when asked")
        var back = CookieSceneCameraRig(overview: 4)
        back.frame(nil, turn: turn, yaw: 3.0, instantly: true)
        back.frame(nil, turn: turn, yaw: -3.0, instantly: false)
        check(abs(back.orbit.target.x - (2 * .pi - 3.0)) < 1e-6, "a yaw goes the short way round")
        var held = CookieSceneCameraRig(overview: 4)
        held.frame([1, 0, 0], turn: turn, distance: 1, instantly: false)
        for _ in 0..<10 { held.step(1.0 / 60, turn: turn) }
        let grabbed = held.eye()
        held.hold()
        for _ in 0..<60 { held.step(1.0 / 60, turn: turn) }
        check(close(held.eye(), grabbed) && held.subject == nil, "when the person takes over the camera stops where it is")
    }

    // MARK: Verbs

    private static func verbs() {
        let bodies: [(String, CookieVisualCommand?)] = [
            ("run", .run), ("slow", .slow), ("stop", .stop), ("step", .step), ("focus:Fan", .focus("fan")),
            ("flow:air:on", .flow("air", on: true)), ("flow:air:off", .flow("air", on: false)), ("view:side", .view(.side)),
            ("view:overview", .view(.overview)), ("cut:case:on", .cut("case", on: true)), ("cut:case:off", .cut("case", on: false)),
            ("view:inside", nil), ("flow:air", nil), ("cut:case:maybe", nil), ("focus:", nil), ("stop-spin", .spin(.stop)),
        ]
        for (body, expected) in bodies {
            check(CookieVisualCommand(tag: CookieReplyTag(kind: "VISUAL", body: body, offset: 0)) == expected, "VISUAL:\(body)")
        }
        let spoken: [(String, CookieVisualCommand?)] = [
            ("run it", .run), ("show me it working", .run), ("slow motion", .slow), ("stop the machine", .stop),
            ("show me the side view", .view(.side)), ("look at it from the top", .view(.top)), ("show the whole thing", .view(.overview)),
            ("step it on", .step), ("stop", nil), ("slow it down", .spin(.slower)),
        ]
        for (text, expected) in spoken { check(CookieLessonVoice.command(text) == expected, "spoken \"\(text)\" → \(String(describing: expected))") }
        check(CookieLessonVoice.note(.run, rateBefore: 0, rateAfter: 0, spinning: false, reduceMotion: false, labelled: 0) == "This model has no moving parts."
              && CookieLessonVoice.note(.run, rateBefore: 0, rateAfter: 0, spinning: false, reduceMotion: true, labelled: 0, moving: true).contains("Reduce Motion"),
              "what Cookie says is true to what the model can do")
    }

    // MARK: Stage

    private static func stage() {
        let scene = CookieScene.read(engine()).scene!
        let stage = CookieSceneStage(scene: scene, reduceMotion: false)
        let start = stage.placement(of: "piston")!.position
        stage.step(0.5)
        check(close(stage.placement(of: "piston")!.position, start), "a machine starts still")
        stage.apply(.run)
        stage.step(0.25)
        let turned = stage.placement(of: "piston")!.position
        let expected = CookieSceneMotion.placed(scene, scene.parts[2], pose: CookieSceneMotion.pose(scene, turns: CookieSceneMotion.turns(scene, time: 0.25)), explosion: 0).position
        check(stage.playing && close(turned, expected) && !close(turned, start), "[VISUAL:run] sets it working, the parts where the motion has them")
        stage.apply(.slow)
        stage.step(0.4)
        check(stage.slowMotion && abs(stage.motionTime - 0.35) < 1e-5, "slow motion runs a quarter as fast: \(stage.motionTime)")
        stage.apply(.stop)
        stage.step(1)
        check(!stage.playing && abs(stage.motionTime - 0.35) < 1e-5, "stop holds it")
        stage.apply(.step)
        check(abs(stage.motionTime - (0.35 + 1.0 / 6)) < 1e-5, "a step moves it a twelfth of a turn")

        // Cut, isolate, focus, view, shadow.
        stage.apply(.cut("PISTON", on: true))
        check(stage.cutParts.contains("piston") && stage.root.children.first { $0.components[ModelComponent.self] != nil && $0.children.contains { $0.name == "rim" } } != nil,
              "a cut part goes see-through with a lit edge")
        stage.apply(.cut("piston", on: false))
        check(!stage.cutParts.contains("piston") && stage.cutParts == ["bore"], "and back, leaving the cylinder cut")
        stage.focus("piston", hand: false)
        stage.apply(.isolate)
        stage.step(0.5)
        check(stage.isFaded("bore") && !stage.isFaded("piston") && stage.root.children.allSatisfy(\.isEnabled), "isolate fades the rest rather than hiding them")
        stage.apply(.showAll)
        let overview = stage.cameraShot
        stage.apply(.focus("rod"))
        check(stage.activePart == "rod", "[VISUAL:focus:rod] lights the rod")
        for _ in 0..<180 { stage.step(1.0 / 60) }
        let framed = stage.cameraShot
        check(simd_distance(framed.eye, framed.target) < simd_distance(overview.eye, overview.target) * 0.8
              && simd_distance(framed.target, stage.root.orientation.act(stage.placement(of: "rod")!.position)) < 0.2,
              "and the camera flies in to frame it: \(framed)")
        stage.drag(CGSize(width: 40, height: 0))
        let grabbed = stage.cameraShot.eye
        for _ in 0..<30 { stage.step(1.0 / 60) }
        stage.endDrag()
        check(close(stage.cameraShot.eye, grabbed), "the person's drag wins: the camera holds")
        stage.apply(.view(.overview))
        for _ in 0..<240 { stage.step(1.0 / 60) }
        check(abs(simd_distance(stage.cameraShot.eye, stage.cameraShot.target) - simd_distance(overview.eye, overview.target)) < 0.01, "and the next beat takes it back to the overview")
        let shadow = stage.shadowPlacement
        let lowest = scene.parts.map { part -> Float in
            let placed = stage.placement(of: part.id)!, box = part.form.bounds
            return (0..<8).map { corner -> Float in
                let q = SIMD3<Float>(corner & 1 == 0 ? box.min.x : box.max.x, corner & 2 == 0 ? box.min.y : box.max.y, corner & 4 == 0 ? box.min.z : box.max.z)
                return stage.root.orientation.act(placed.position + placed.orientation.act(q)).y
            }.min()!
        }.min()!
        check(shadow.centre.y < lowest && shadow.centre.y > lowest - 0.1 && shadow.scale.x > 0.2, "the soft shadow lies just under the model: \(shadow) vs \(lowest)")
        stage.apply(.reset)
        check(!stage.playing && stage.motionTime == 0 && stage.cutParts == ["bore"], "reset puts the machine back as it was built")
        stage.release()
    }

    private static func stillness() {
        let scene = CookieScene.read(CookieBuildModelTests.exampleScene(jetLine)).scene!
        let still = CookieSceneStage(scene: scene, reduceMotion: true)
        let pose = still.placement(of: "fan")!.orientation
        still.apply(.run)
        still.step(1)
        check(still.placement(of: "fan")!.orientation == pose && still.motionTime == 0, "with Reduce Motion the machine holds its pose")
        let representative = CookieSceneMotion.placed(scene, scene.parts[1], pose: CookieSceneMotion.pose(scene, turns: CookieSceneMotion.representative(scene)), explosion: 0)
        check(abs(simd_dot(pose.vector, representative.orientation.vector)) > 0.9999, "a sixth of a turn round, not its built pose")
        let arrows = still.markerPositions("air")
        check(arrows.count >= 3 && arrows.count <= 10 && still.flowLayer.children.count == arrows.count, "the flow is still arrows along its route: \(arrows.count)")
        still.step(1)
        check(still.markerPositions("air") == arrows, "that don't move")
        still.apply(.view(.side))
        check(still.cameraShot.settled, "and the camera cuts")
        still.apply(.flow("air", on: false))
        check(still.markerPositions("air").isEmpty, "[VISUAL:flow:air:off] hides it")
        still.release()

        let moving = CookieSceneStage(scene: scene, reduceMotion: false)
        moving.apply(.run)
        let first = moving.markerPositions("air")
        moving.step(0.1)
        check(first.count > 10 && first.count <= CookieScene.maxBeadsPerFlow && moving.markerPositions("air") != first, "with motion the beads run along it")
        moving.release()
    }

    // MARK: The check

    private static func decode(_ output: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] ?? [:]
    }

    private static func checks() async {
        func build(_ scene: String) async -> (issues: [String], motion: [String]) {
            let json = decode(await CookieModelShelf().build(["scene": scene]).output)
            return (json["issues"] as? [String] ?? ["<none>"], (json["render"] as? [String: Any])?["motion"] as? [String] ?? [])
        }
        let meshed = await build(gears)
        check(meshed.issues.isEmpty && meshed.motion.contains { $0.hasPrefix("drive: spins about [0, 1, 0]") }, "a meshed pair is fine: \(meshed)")
        let apart = await build(gears.replacingOccurrences(of: "[0.45,0,0]", with: "[0.7,0,0]"))
        check(apart.issues.contains { $0.contains("big and small don't touch") && $0.contains("put them 0.45 apart") }, "gears that don't touch are named: \(apart.issues)")
        let wrong = await build(gears.replacingOccurrences(of: #"{"from":"drive","to":"small"}"#, with: #"{"from":"drive","to":"small","ratio":2}"#))
        check(wrong.issues.contains { $0.contains("ratio 2 doesn't match the teeth") }, "a ratio the teeth can't give is named: \(wrong.issues)")
        let tumble = await build(gears.replacingOccurrences(of: #""axis":[0,1,0]"#, with: #""axis":[1,0,0]"#))
        check(tumble.issues.contains { $0.contains("big turns about [1, 0, 0], 90° off its own axis") }, "a wheel turned about the wrong axis tumbles: \(tumble.issues)")

        let fits = await build(engine())
        check(fits.issues.isEmpty && fits.motion.contains { $0.contains("strokes 0.3") } && fits.motion.contains("piston stays inside bore over the whole turn"),
              "a piston in a long enough cylinder stays in: \(fits)")
        let leaves = await build(engine(cylinderLength: 0.3))
        check(leaves.issues.contains { $0.contains("piston leaves bore by up to") && $0.contains("crank angle") }, "one that leaves its cylinder is caught over the cycle: \(leaves.issues)")
    }

    // MARK: The prompt's example

    static var jetLine: String {
        CompanionManager.companionVoiceResponseSystemPrompt.components(separatedBy: "\n").first { $0.contains("build_model with scene {\"title\":\"inside a jet engine\"") }!
    }

    private static func example() {
        let reading = CookieScene.read(CookieBuildModelTests.exampleScene(jetLine))
        let scene = reading.scene!
        check(reading.errors.isEmpty && reading.repairs.isEmpty, "the jet engine reads cleanly: \(reading.repairs) \(reading.errors)")
        check(scene.joints.first?.members.sorted() == ["comp", "fan", "shaft", "turb"] && scene.flows.first?.through == ["fan", "comp", "burn", "turb", "nozzle"],
              "its spool spins fan, compressor, turbine and shaft, and the air runs fan to nozzle")
        let prompt = CompanionManager.companionVoiceResponseSystemPrompt
        check(prompt.contains("Cookie doesn't simulate airflow, fluids or forces") && prompt.contains("[VISUAL:flow:id:on]") && prompt.contains("[VISUAL:view:side]"),
              "the prompt says flows are illustrations and lists the new verbs")

        // The reply's [VISUAL:run] drives the model built for it.
        let reply = String(jetLine[jetLine.range(of: "the reply says \"")!.upperBound...].dropLast())
        let tags = CookieReplyTags.split(reply).tags
        let stage = CookieSceneStage(scene: scene, reduceMotion: false)
        let fan = stage.placement(of: "fan")!.orientation
        for command in tags.compactMap(CookieVisualCommand.init(tag:)) { stage.apply(command) }
        stage.step(0.2)
        check(stage.playing && abs(simd_dot(stage.placement(of: "fan")!.orientation.vector, fan.vector)) < 0.999
              && close(stage.placement(of: "fan")!.position, CookieSceneMotion.placed(scene, scene.parts[1], pose: [:], explosion: 0).position, 1e-3),
              "its [VISUAL:run] spins the fan in place")
        check(CookieScenePresenter.teachingContext(stage).contains("Motion: running") && CookieScenePresenter.teachingContext(stage).contains("Flows: air on"),
              "and the follow-up knows it's running")
        stage.release()
    }
}
