import AppKit
import RealityKit
import simd

/// The parts library and the forgiving scene reader: every shape draws a closed, outward-wound mesh
/// with unit normals and in-range texture coordinates inside the box it promises (and the analytic
/// volume where there is one); meshes are cached by their numbers and warmed off the main thread;
/// the reader repairs plain slips (and says so), names what it can't read by part and field, never
/// drops anything silently; groups explode and isolate together; the voice prompt's example and the
/// lesson planner's examples parse cleanly; and a workspace scene is held to the same errors.
@MainActor
enum CookieScenePartsTests {
    private static var count = 0
    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        count += 1
    }

    /// One part of every shape, written the way the model would write it.
    static let everyShape = #"""
    {"title":"Every part","parts":[
    {"id":"box","shape":"box","width":0.4,"height":0.3,"depth":0.2,"corner":0.03,"color":"amber"},
    {"id":"sharp","shape":"box","size":[0.4,0.3,0.2],"corner":0,"color":"cream"},
    {"id":"sphere","shape":"sphere","radius":0.25,"color":"sky"},
    {"id":"cylinder","shape":"cylinder","radius":0.2,"height":0.5,"color":"mint"},
    {"id":"cone","shape":"cone","radius":0.2,"height":0.4,"color":"rose"},
    {"id":"capsule","shape":"capsule","radius":0.1,"height":0.5,"color":"steel"},
    {"id":"torus","shape":"torus","radius":0.3,"tube":0.07,"color":"glass"},
    {"id":"gear","shape":"gear","radius":0.3,"thickness":0.06,"teeth":24,"bore":0.05,"color":"brass","finish":"polished"},
    {"id":"solidgear","shape":"gear","radius":0.2,"teeth":12,"color":"brass"},
    {"id":"bevel","shape":"bevelGear","radius":0.25,"thickness":0.08,"teeth":18,"bore":0.04,"cone":50,"color":"copper"},
    {"id":"rack","shape":"rack","length":0.8,"height":0.1,"thickness":0.05,"teeth":14,"color":"steel"},
    {"id":"shaft","shape":"shaft","radius":0.05,"length":0.6,"steps":[[0.035,0.2],[0.025,0.1]],"color":"steel"},
    {"id":"bearing","shape":"bearing","radius":0.2,"inner":0.1,"width":0.07,"color":"steel"},
    {"id":"fan","shape":"bladeRing","tip":0.5,"hub":0.14,"thickness":0.1,"blades":18,"twist":35,"color":"graphite"},
    {"id":"spring","shape":"spring","radius":0.1,"length":0.5,"wire":0.012,"coils":7,"color":"steel"},
    {"id":"pipe","shape":"pipe","points":[[0,0,0],[0.4,0,0],[0.4,0.4,0],[0.4,0.4,0.4]],"radius":0.04,"color":"copper"},
    {"id":"tube","shape":"tube","radius":0.3,"inner":0.25,"length":0.6,"color":"steel","cut":true},
    {"id":"piston","shape":"piston","radius":0.15,"height":0.2,"color":"steel"},
    {"id":"crank","shape":"crank","throw":0.15,"radius":0.05,"thickness":0.05,"color":"graphite"},
    {"id":"rod","shape":"rod","length":0.5,"radius":0.07,"small":0.045,"thickness":0.04,"color":"steel"},
    {"id":"valve","shape":"valve","radius":0.08,"length":0.5,"stem":0.012,"color":"steel"},
    {"id":"wheel","shape":"wheel","radius":0.35,"width":0.12,"hub":0.08,"spokes":6,"color":"rubber"},
    {"id":"disc","shape":"wheel","radius":0.3,"width":0.1,"hub":0.06,"spokes":0,"color":"rubber","finish":"matte"},
    {"id":"prop","shape":"propeller","radius":0.4,"blades":3,"pitch":25,"hub":0.06,"color":"carbon"},
    {"id":"screw","shape":"screw","radius":0.03,"length":0.25,"pitch":0.012,"head":0.05,"color":"steel"},
    {"id":"lathe","shape":"lathe","profile":[[0.2,-0.2],[0.25,0],[0.1,0.2]],"color":"plastic-white"},
    {"id":"plate","shape":"extrude","outline":[[-0.2,-0.2],[0.2,-0.2],[0.2,0.2],[-0.2,0.2]],"holes":[[[-0.1,-0.1],[-0.1,0.1],[0.1,0.1],[0.1,-0.1]]],"depth":0.05,"color":"steel"},
    {"id":"bracket","shape":"extrude","outline":[[0,0],[0.4,0],[0.4,0.1],[0.1,0.1],[0.1,0.4],[0,0.4]],"depth":0.06,"color":"graphite"},
    {"id":"hose","shape":"sweep","path":[[0,0,0],[0,0.3,0],[0.3,0.3,0]],"radius":0.03,"color":"rubber"},
    {"id":"bar","shape":"sweep","path":[[0,0,0],[0.3,0,0],[0.3,0,0.3]],"width":0.06,"height":0.02,"color":"steel"},
    {"id":"arrow","shape":"arrow","length":0.6,"radius":0.03,"color":"amber"}
    ]}
    """#

    static func run() async {
        count = 0
        meshes()
        await resources()
        reading()
        groups()
        prompts()
        print("\(count) scene part checks passed.")
    }

    // MARK: Meshes

    private static func meshes() {
        let reading = CookieScene.read(everyShape)
        check(reading.errors.isEmpty && reading.repairs.isEmpty, "every shape reads cleanly: \(reading.errors) \(reading.repairs)")
        let scene = reading.scene!
        check(Set(scene.parts.map(\.shape)) == Set(CookieScene.Shape.allCases), "the example covers every shape")
        for part in scene.parts {
            let g = CookieMeshes.build(part.form)
            let name = part.id
            check(g.triangleCount > 0 && g.normals.count == g.positions.count && g.uvs.count == g.positions.count
                  && g.indices.allSatisfy { Int($0) < g.positions.count }, "\(name): a well-formed mesh")
            check(g.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
                  && g.normals.allSatisfy { abs(simd_length($0) - 1) < 1e-3 }
                  && g.uvs.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }, "\(name): finite points, unit normals, uvs in 0…1")
            // Winding: each face's own normal agrees with its vertices' normals, and the volume is positive.
            var agree = 0, volume: Float = 0
            for t in stride(from: 0, to: g.indices.count, by: 3) {
                let a = Int(g.indices[t]), b = Int(g.indices[t + 1]), c = Int(g.indices[t + 2])
                let face = simd_cross(g.positions[b] - g.positions[a], g.positions[c] - g.positions[a])
                if simd_dot(face, g.normals[a] + g.normals[b] + g.normals[c]) > 0 { agree += 1 }
                volume += simd_dot(g.positions[a], simd_cross(g.positions[b], g.positions[c])) / 6
            }
            check(Float(agree) >= Float(g.triangleCount) * 0.98, "\(name): faces wound outward (\(agree)/\(g.triangleCount))")
            check(volume > 0, "\(name): encloses a positive volume (\(volume))")
            check(closed(g), "\(name): a closed surface, every edge shared both ways")
            let promised = part.form.bounds, drawn = g.bounds
            let slack = part.form.reach * 0.01 + 1e-5
            check(simd_reduce_min(drawn.min - promised.min) >= -slack && simd_reduce_max(drawn.max - promised.max) <= slack,
                  "\(name): inside its promised bounds (\(drawn) vs \(promised))")
            let fill = (drawn.max - drawn.min) / simd_max(promised.max - promised.min, SIMD3(repeating: 1e-6))
            check(simd_reduce_min(fill) > 0.7, "\(name): fills its promised bounds (\(fill))")
        }
        // Volumes where the shape has a formula: proof the surfaces are whole and wound one way.
        func volume(_ form: CookieScene.Form) -> Float {
            let g = CookieMeshes.build(form)
            return stride(from: 0, to: g.indices.count, by: 3).reduce(0) { sum, t in
                sum + simd_dot(g.positions[Int(g.indices[t])], simd_cross(g.positions[Int(g.indices[t + 1])], g.positions[Int(g.indices[t + 2])])) / 6
            }
        }
        func near(_ a: Float, _ b: Float, _ tolerance: Float) -> Bool { abs(a - b) <= b * tolerance }
        check(near(volume(.init(.box, ["width": 0.4, "height": 0.3, "depth": 0.2, "corner": 0])), 0.024, 1e-4), "a sharp box's volume")
        check(near(volume(.init(.sphere, ["radius": 0.25])), 4 / 3 * .pi * pow(0.25, 3), 0.02), "a sphere's volume")
        check(near(volume(.init(.cylinder, ["radius": 0.2, "height": 0.5])), .pi * 0.04 * 0.5, 0.01), "a cylinder's volume")
        check(near(volume(.init(.torus, ["radius": 0.3, "tube": 0.07])), 2 * .pi * .pi * 0.3 * 0.07 * 0.07, 0.02), "a torus's volume")
        check(near(volume(.init(.tube, ["radius": 0.3, "inner": 0.25, "length": 0.6])), .pi * (0.09 - 0.0625) * 0.6, 0.01), "a tube's volume, bore and all")
        check(near(volume(.init(.extrude, ["depth": 0.05], points: [[-0.2, -0.2, 0], [0.2, -0.2, 0], [0.2, 0.2, 0], [-0.2, 0.2, 0]],
                                holes: [[[-0.1, -0.1, 0], [-0.1, 0.1, 0], [0.1, 0.1, 0], [0.1, -0.1, 0]]])), (0.16 - 0.04) * 0.05, 1e-3),
              "an extruded plate's volume, hole taken out")
        let teeth = [12, 24, 60].map { CookieMeshes.build(.init(.gear, ["radius": 0.3, "thickness": 0.05, "teeth": Float($0), "bore": 0.05])).positions.count }
        check(teeth[0] < teeth[1] && teeth[1] < teeth[2], "more teeth, more detail")
        // A clockwise outline and a profile written top-down still face out.
        let backwards = CookieMeshes.build(.init(.extrude, ["depth": 0.1], points: [[0, 0, 0], [0, 0.3, 0], [0.3, 0.3, 0], [0.3, 0, 0]]))
        check(closed(backwards) && signedVolume(backwards) > 0, "a clockwise outline is turned round, not drawn inside out")
        let downward = CookieMeshes.build(.init(.lathe, [:], points: [[0.1, 0.2, 0], [0.25, 0, 0], [0.2, -0.2, 0]]))
        check(closed(downward) && signedVolume(downward) > 0, "a profile written top to bottom is turned round too")
        let rounded = CookieMeshes.rounded([[0, 0, 0], [1, 0, 0], [1, 1, 0]], bend: 0.2)
        check(rounded.count > 3 && rounded.allSatisfy { $0.x <= 1 + 1e-5 && $0.y >= -1e-5 }, "a pipe's corner bends inside its legs")
    }

    static func signedVolume(_ g: CookieGeometry) -> Float {
        stride(from: 0, to: g.indices.count, by: 3).reduce(0) { sum, t in
            sum + simd_dot(g.positions[Int(g.indices[t])], simd_cross(g.positions[Int(g.indices[t + 1])], g.positions[Int(g.indices[t + 2])])) / 6
        }
    }

    /// Welded by position, every edge one way is matched by the same edge the other way: no holes, no
    /// flipped faces (parts may overlap each other, each one closed).
    static func closed(_ g: CookieGeometry) -> Bool {
        var ids: [SIMD3<Int32>: Int] = [:]
        let welded = g.positions.map { p -> Int in
            let key = SIMD3<Int32>(p * 1e5, rounding: .toNearestOrAwayFromZero)
            if let id = ids[key] { return id }
            ids[key] = ids.count
            return ids.count - 1
        }
        var edges: [Int64: Int] = [:]
        for t in stride(from: 0, to: g.indices.count, by: 3) {
            let corners = [welded[Int(g.indices[t])], welded[Int(g.indices[t + 1])], welded[Int(g.indices[t + 2])]]
            for k in 0..<3 where corners[k] != corners[(k + 1) % 3] {
                edges[Int64(corners[k]) << 32 | Int64(corners[(k + 1) % 3]), default: 0] += 1
            }
        }
        return edges.allSatisfy { key, n in edges[(key & 0xFFFF_FFFF) << 32 | key >> 32] == n }
    }

    // MARK: Cache and RealityKit

    private static func resources() async {
        let fresh = CookieScene.Form(.gear, ["radius": 0.21, "thickness": 0.04, "teeth": 31, "bore": 0])
        let before = CookieMeshes.builds
        let first = CookieMeshes.geometry(fresh), second = CookieMeshes.geometry(fresh)
        check(CookieMeshes.builds == before + 1 && first.positions == second.positions, "a shape is drawn once per set of numbers")
        let mesh = CookieMeshResources.mesh(fresh)
        check(mesh === CookieMeshResources.mesh(fresh), "and RealityKit's mesh is made once too")
        let uploaded = mesh.contents.models.first?.parts.first
        // RealityKit may re-pack shared vertices, so what must survive is every triangle and the shape's extent.
        let uploadedTriangles = mesh.contents.models.reduce(0) { $0 + $1.parts.reduce(0) { $0 + ($1.triangleIndices?.count ?? 0) } }
        check(uploaded != nil && uploadedTriangles == first.indices.count
              && simd_distance(mesh.bounds.extents, first.bounds.max - first.bounds.min) < 1e-4,
              "RealityKit gets every triangle at the right size (\(uploadedTriangles) of \(first.indices.count), \(mesh.bounds.extents))")
        // Warming draws and uploads off the main thread, so showing the scene doesn't wait.
        let warmScene = CookieScene(title: "Warm", parts: [CookieScene.Part(id: "w", label: nil, form: .init(.spring, ["radius": 0.11, "length": 0.4, "wire": 0.01, "coils": 9]),
                                                                       position: .zero, rotation: .zero, tint: .steel, cut: false)], explode: false, spin: false)
        check(CookieMeshResources.cached(warmScene.parts[0].form) == nil, "not drawn before warming")
        await CookieMeshResources.warm(warmScene).value
        check(CookieMeshResources.cached(warmScene.parts[0].form) != nil, "warming leaves the mesh ready")
        // A stage builds every shape in the library.
        let all = CookieScene.read(everyShape).scene!
        let stage = CookieSceneStage(scene: all, reduceMotion: true)
        check(stage.root.children.count == all.parts.count && stage.root.children.allSatisfy { ($0 as? ModelEntity)?.model != nil },
              "a stage holds one drawn entity per part")
        stage.release()
        let steel = CookieSceneStage.surface(.steel)
        check(CookieSceneStage.finished(.steel, .polished).roughness < steel.roughness && CookieSceneStage.finished(.steel, .matte).roughness > steel.roughness
              && CookieSceneStage.finished(.rubber, nil).roughness > 0.8 && CookieSceneStage.surface(.brass).metallic == 1,
              "finishes and tints set real roughness and metal")
    }

    // MARK: Reading

    private static func reading() {
        // The old format still reads exactly, with nothing to repair.
        let legacy = #"{"title":"Inside a jet engine","parts":[{"id":"case","shape":"cylinder","size":[0.55,2.3],"position":[0,0,0],"rotation":[0,0,90],"color":"steel","cut":true},{"id":"fan","label":"Fan","shape":"cylinder","size":[0.5,0.08],"position":[-1,0,0],"rotation":[0,0,90],"color":"sky"}],"spin":false}"#
        let old = CookieScene.read(legacy)
        check(old.errors.isEmpty && old.repairs.isEmpty && old.scene?.parts[1].form == .init(.cylinder, size: [0.5, 0.08]), "the old size form reads unchanged")

        func one(_ part: String) -> CookieScene.Reading { CookieScene.read(#"{"title":"T","parts":["# + part + "]}") }
        let short = one(#"{"id":"c","shape":"capsule","radius":0.2,"height":0.3,"color":"steel"}"#)
        check(short.scene?.parts[0].shape == .cylinder && short.repairs.contains { $0.hasPrefix("c.shape:") && $0.contains("cylinder") },
              "a capsule too short becomes a cylinder, and says so")
        let big = one(#"{"id":"b","shape":"sphere","radius":30,"color":"steel"}"#)
        check(big.scene?.parts[0].form["radius"] == 10 && big.repairs.contains { $0.hasPrefix("b.radius:") }, "a number past the limit is clamped and noted")
        let red = one(#"{"id":"r","shape":"box","color":"red"}"#), hex = one(##"{"id":"h","shape":"box","color":"#B87333"}"##)
        check(red.scene?.parts[0].tint == .rose && hex.scene?.parts[0].tint == .copper && red.repairs.contains { $0.contains("rose") },
              "colours become the nearest palette tint")
        let unknown = one(#"{"id":"u","shape":"box","color":"steel","weight":3,"teeth":9}"#)
        check(unknown.errors.isEmpty && unknown.repairs.contains("u.weight: not a part field; ignored")
              && unknown.repairs.contains("u.teeth: a box doesn't take teeth; ignored"), "unknown fields are ignored, each noted")
        let text = one(#"{"id":"t","shape":"cylinder","radius":"0.2","height":0.4,"color":"steel"}"#)
        check(text.scene?.parts[0].form["radius"] == 0.2 && text.repairs.contains { $0.hasPrefix("t.radius:") }, "a number written as text is read")
        let aliases = one(#"{"id":"f","shape":"Blade_Ring","tip":0.4,"hub":0.5,"blades":12.4,"color":"Plastic White"}"#)
        let fan = aliases.scene?.parts[0]
        check(fan?.shape == .bladeRing && fan?.form["blades"] == 12 && abs((fan?.form["hub"] ?? 0) - 0.12) < 1e-6 && fan?.tint == .plasticWhite
              && aliases.repairs.count == 4, "a shape spelled differently, a fractional count and a hub past the tip are each repaired")
        let twice = CookieScene.read(#"{"parts":[/* two parts */{"shape":"box","color":"steel"},{"id":"part1","shape":"cog","color":"brass"},]}"#)
        check(twice.scene?.title == "Model" && twice.scene?.parts.map(\.id) == ["part1", "part1-2"] && twice.scene?.parts[1].shape == .gear
              && twice.repairs.contains { $0.contains("relaxed JSON") }, "a missing title, a missing id, a repeat and a comment in the JSON are all repaired")

        // What can't be read is named by part and field, and only that part is left out.
        let blob = CookieScene.read(#"{"title":"T","parts":[{"id":"x","shape":"blob","color":"steel"},{"id":"y","shape":"box","color":"steel"}]}"#)
        check(blob.scene?.parts.map(\.id) == ["y"] && blob.errors.count == 1 && blob.errors[0].hasPrefix("x.shape: \"blob\" isn't a shape"),
              "an unknown shape is an exact error; the rest of the model stays")
        check(CookieScene.leftOutNote(blob)?.contains("x.shape") == true && CookieScene.leftOutNote(old) == nil,
              "a model shown without a part says so in one line")
        let crossed = one(#"{"id":"z","shape":"extrude","outline":[[0,0],[3,0],[3,1],[1,-1],[0,1]],"color":"steel"}"#)
        check(crossed.scene == nil && crossed.errors.first?.contains("z.outline: crosses itself") == true, "a self-crossing outline is refused, exactly")
        let words = one(#"{"id":"w","shape":"label","color":"steel"}"#)
        check(words.errors.first?.contains("label") == true, "3D text is refused with the reason")
        let badPosition = one(#"{"id":"p","shape":"box","position":["left",0,0],"color":"steel"}"#)
        check(badPosition.errors == ["p.position[0]: must be a number", "scene: no part could be built, so there is nothing to show"], "a field that isn't a number is named")
        let broken = CookieScene.read(#"{"title": "#)
        check(broken.scene == nil && broken.errors.first?.contains("not valid JSON") == true, "broken JSON is an error, not silence")
        let many = CookieScene.read(#"{"title":"Many","parts":["# + (0..<70).map { #"{"id":"p\#($0)","shape":"sphere","radius":0.05,"color":"sky"}"# }.joined(separator: ",") + "]}")
        check(many.scene?.parts.count == CookieScene.maxParts && many.errors.first?.contains("left out") == true, "past 64 parts, the rest are left out and said to be")
        check(CookieScene(tag: CookieReplyTag(kind: "SCENE", body: legacy, offset: 9))?.offset == 9 && CookieScene.read(tag: CookieReplyTag(kind: "CARD", body: "{}", offset: 0)) == nil,
              "a SCENE tag is read at its place; other tags aren't scenes")

        // The workspace holds a scene to the same errors.
        var content = CookieArtifact.Content()
        content.body = #"{"title":"T","parts":[{"id":"x","shape":"blob","color":"steel"}]}"#
        do {
            try CookieWorkspaceStore.validateBounds(content, kind: .scene)
            preconditionFailure("a broken scene was accepted")
        } catch {
            check(error.localizedDescription.contains("x.shape: \"blob\""), "the workspace names the broken field")
        }
        content.body = #"{"title":"T","parts":[{"id":"y","shape":"gear","teeth":7.6,"color":"gold"}]}"#
        check((try? CookieWorkspaceStore.validateBounds(content, kind: .scene)) != nil, "and accepts what it can repair")
    }

    // MARK: Groups

    private static func groups() {
        let scene = CookieScene.read(#"{"title":"Spool","parts":[{"id":"a","label":"A","shape":"sphere","radius":0.1,"position":[-1,0,0],"color":"sky","group":"spool"},{"id":"b","shape":"sphere","radius":0.1,"position":[-0.6,0,0],"color":"sky","group":"spool"},{"id":"c","label":"C","shape":"sphere","radius":0.1,"position":[1,0,0],"color":"amber"}]}"#).scene!
        let a = scene.parts[0], b = scene.parts[1], c = scene.parts[2]
        check(simd_distance(scene.place(of: a, exploded: true) - scene.place(of: b, exploded: true), a.position - b.position) < 1e-5,
              "a group explodes as one, its parts keeping their spacing")
        check(simd_distance(scene.place(of: c, exploded: true), scene.place(of: c, exploded: false) * CookieScene.explodeSpread) < 1e-5,
              "a part on its own spreads out as before")
        check(scene.members(of: "a") == ["a", "b"] && scene.members(of: "c") == ["c"], "a part's group is its members")
        let stage = CookieSceneStage(scene: scene, reduceMotion: true)
        stage.focus("a", hand: false)
        stage.apply(.isolate)
        check(stage.root.children.filter(\.isEnabled).count == 2, "isolating a part keeps its whole group")
        stage.apply(.showAll)
        stage.release()
    }

    // MARK: Prompts

    private static func prompts() {
        // The voice prompt's example is what the model copies: it must read with nothing to repair.
        let prompt = CompanionManager.companionVoiceResponseSystemPrompt
        let example = prompt.components(separatedBy: "\n").first { $0.contains("build_model with scene {\"title\":\"inside a jet engine\"") }!
        let engine = CookieScene.read(CookieBuildModelTests.exampleScene(example))
        check(engine.errors.isEmpty && engine.repairs.isEmpty, "the jet engine example reads cleanly: \(engine.errors) \(engine.repairs)")
        let parts = engine.scene!.parts
        check(parts.filter { $0.shape == .bladeRing }.count == 3 && parts.contains { $0.shape == .tube && $0.cut } && engine.scene!.members(of: "fan").count == 4,
              "it shows blade rings for fan, compressor and turbine on one spool inside a cut tube")
        check(engine.scene!.labelled.compactMap(\.label) == ["fan", "compressor", "combustor", "turbine", "nozzle"], "named in the order the sentence says them")
        // The shape list in the prompt is the real library.
        check(CookieScene.Shape.allCases.allSatisfy { prompt.contains(" " + $0.rawValue + " ") || prompt.contains(" " + $0.rawValue + ",") },
              "the prompt names every shape")
        check(CookieScene.Tint.allCases.allSatisfy { prompt.contains($0.rawValue) } && prompt.contains("up to 64 parts"), "and every colour, and the real limit")
        // The lesson planner's examples read cleanly too.
        for line in CookieLessonFromScreen.instruction(.pointer, pictured: true).components(separatedBy: "\n") where line.hasPrefix("Example") {
            for tag in CookieReplyTags.split(line).tags where tag.kind == "SCENE" {
                let read = CookieScene.read(tag: tag)!
                check(read.errors.isEmpty && read.repairs.isEmpty, "the lesson planner's scene reads cleanly: \(read.repairs)")
            }
        }
    }
}
