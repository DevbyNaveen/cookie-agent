import CoreGraphics
import Foundation

/// build_model: a scene is read, kept by id for the run and checked from the camera the person sees;
/// the reply's [SCENE:#id] shows it at its word, an id nobody built says "I couldn't build that model",
/// a turn gets one build and two rebuilds, and the voice prompt's example builds with nothing to fix.
@MainActor
enum CookieBuildModelTests {
    private static var count = 0
    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        count += 1
    }

    /// The scene JSON the prompt's example hands to build_model.
    static func exampleScene(_ line: String) -> String {
        let start = line.range(of: "build_model with scene ")!.upperBound
        var depth = 0, index = start
        while index < line.endIndex {
            if line[index] == "{" { depth += 1 }
            if line[index] == "}" { depth -= 1; if depth == 0 { break } }
            index = line.index(after: index)
        }
        return String(line[start...index])
    }

    private static func decode(_ output: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] ?? [:]
    }

    static func run() async {
        count = 0
        tools()
        await example()
        await rebuilds()
        await errors()
        await issues()
        print("\(count) build model checks passed.")
    }

    private static func tools() {
        let mac = HarnessClient.tools(backgroundProject: false, unattended: false, workspace: false)
        let tool = mac.first { $0.name == "build_model" }
        check(tool?.effect == "read" && tool?.schema?.required == ["scene"], "build_model is a read tool the model can call")
        check(!HarnessClient.tools(backgroundProject: true, unattended: false, workspace: true).contains { $0.name == "build_model" },
              "a background project has no desktop to show a model on")
        let encoded = String(decoding: HarnessWire.encode(tool!), as: UTF8.self)
        check(encoded.contains("\"name\":\"build_model\"") && encoded.contains("[SCENE:#id]"), "it goes to the harness with its schema and the show tag")
    }

    private static func example() async {
        let prompt = CompanionManager.companionVoiceResponseSystemPrompt
        let line = prompt.components(separatedBy: "\n").first { $0.contains("build_model with scene {\"title\":\"inside a jet engine\"") }!
        let shelf = CookieModelShelf()
        let result = await shelf.build(["scene": exampleScene(line)])
        let json = decode(result.output)
        check(!result.isError && json["ok"] as? Bool == true && json["id"] as? String == "inside-a-jet-engine",
              "the example builds under the id the prompt says: \(result.output.prefix(300))")
        check((json["issues"] as? [String])?.isEmpty == true && (json["errors"] as? [String])?.isEmpty == true,
              "with nothing to fix: \(json["issues"] ?? "")")
        check(json["snapshot"] is NSNull && (json["snapshot_note"] as? String)?.contains("text only") == true, "and says why there is no picture")
        let render = json["render"] as? [String: Any]
        let assembled = render?["assembled"] as? [String] ?? []
        check(assembled.first?.hasPrefix("assembled: the model spans x") == true
              && ["case", "fan (\"fan\")", "comp (\"compressor\")", "nozzle (\"nozzle\")"].allSatisfy { id in assembled.contains { $0.hasPrefix(id + ": x ") } }
              && assembled.contains { $0.hasPrefix("labels: \"fan\" on the left") },
              "the render names every part's box and every label's place: \(assembled)")
        check((render?["view"] as? String)?.hasPrefix("520×360 pt view") == true && render?["exploded"] == nil, "from the stage's viewport; no exploded view unless asked")

        // The reply's tag shows that model at its word.
        let reply = String(line[line.range(of: "the reply says \"")!.upperBound...].dropLast())
        let split = CookieReplyTags.split(reply)
        let tag = split.tags.first { $0.kind == "SCENE" }!
        let scene = shelf.scene(tag)
        check(json["show"] as? String == "[SCENE:#inside-a-jet-engine]" && reply.contains("[SCENE:#inside-a-jet-engine]"), "the reply uses the show tag")
        check(scene?.parts.count == 7 && scene?.offset == tag.offset && tag.offset == (split.spoken as NSString).range(of: "air comes").location,
              "and the model appears at the word after it")
        check(CompanionManager.pictureFailureNote(split.tags, scene: scene != nil, cards: false) == nil, "a shown model needs no apology")
        // Inline still reads through the same shelf.
        let inline = CookieReplyTags.split("look [SCENE " + exampleScene(line) + "] here").tags[0]
        check(shelf.scene(inline)?.title == "inside a jet engine" && shelf.scene(inline)?.offset == 5, "an inline [SCENE {json}] still shows")
    }

    private static func rebuilds() async {
        let shelf = CookieModelShelf()
        let scene = #"{"title":"Pump","parts":[{"id":"rotor","label":"rotor","shape":"bladeRing","tip":0.4,"hub":0.1,"color":"brass"}]}"#
        var lefts: [Int] = []
        for _ in 0..<3 { lefts.append(decode(await shelf.build(["scene": scene]).output)["rebuilds_left"] as? Int ?? -1) }
        check(lefts == [2, 1, 0] && shelf.models.keys.sorted() == ["pump"], "a rebuild with the same title replaces the model under one id")
        let fourth = await shelf.build(["scene": scene])
        check(fourth.isError && fourth.output.contains("two rebuilds") && fourth.output.contains("[SCENE:#pump]"), "a fourth build is refused and points at the model it has")
        check(shelf.scene(CookieReplyTag(kind: "SCENE", body: "#pump", offset: 3))?.offset == 3, "which still shows")

        let named = await shelf.build(["scene": scene])
        check(named.isError, "still refused")
        shelf.beginRun()
        let gone = shelf.reading(CookieReplyTag(kind: "SCENE", body: "#pump", offset: 0))
        check(gone?.scene == nil && gone?.errors.first?.contains("#pump") == true && shelf.builds == 0, "the next run starts empty")
        let tags = CookieReplyTags.split("here [SCENE:#pump] it is.").tags
        check(CompanionManager.pictureFailureNote(tags, scene: false, cards: false) == "I couldn't build that model."
              && CompanionManager.pictureFailureNote(tags, scene: false, cards: true) == "I couldn't build that model.",
              "an id nobody built is one short line, even when a card showed")
        check(CompanionManager.pictureFailureNote(CookieReplyTags.split("[CARD {\"kind\":\"bogus\"}]").tags, scene: false, cards: false)?.hasPrefix("The picture") == true,
              "a card that failed keeps its own line")

        // The id may be given, and the scene may come as an object or as top-level fields.
        let given = decode(await shelf.build(["scene": ["title": "x", "parts": [["id": "a", "shape": "box", "color": "steel"]]], "id": "My Valve!"]).output)
        let flat = decode(await shelf.build(["title": "Flat one", "parts": [["id": "a", "shape": "sphere", "color": "sky"]]]).output)
        check(given["id"] as? String == "my-valve" && flat["id"] as? String == "flat-one", "ids are short slugs, given or from the title")
    }

    private static func errors() async {
        let shelf = CookieModelShelf()
        let partial = decode(await shelf.build(["scene": #"{"title":"T","parts":[{"id":"x","shape":"blob","color":"steel"},{"id":"y","shape":"box","color":"steel"}]}"#]).output)
        check(partial["ok"] as? Bool == true && (partial["errors"] as? [String])?.first?.contains("x.shape") == true, "a broken part is named by part and field, the rest is built")
        check(CookieScene.leftOutNote(shelf.reading(CookieReplyTag(kind: "SCENE", body: "#t", offset: 0))) != nil, "and showing it says what's missing")
        let broken = await shelf.build(["scene": #"{"title":"T","parts":[]}"#])
        check(broken.isError && decode(broken.output)["ok"] as? Bool == false && broken.output.contains("scene.parts: empty"), "nothing to build is an error the model can fix")
        let missing = await shelf.build([:])
        check(missing.isError && missing.output.contains("scene: missing"), "so is no scene")
        check(shelf.models.keys.sorted() == ["t"], "only what was built is kept")
    }

    private static func issues() async {
        func issues(_ scene: String) async -> [String] {
            decode(await CookieModelShelf().build(["scene": scene]).output)["issues"] as? [String] ?? ["<none>"]
        }
        let sealed = await issues(#"{"title":"Box","parts":[{"id":"shell","shape":"box","width":1,"height":1,"depth":1,"color":"steel"},{"id":"core","label":"core","shape":"sphere","radius":0.1,"color":"amber"}]}"#)
        check(sealed.contains { $0.contains("sealed inside shell") }, "a labelled part inside an opaque one is caught: \(sealed)")
        let cut = await issues(#"{"title":"Box","parts":[{"id":"shell","shape":"box","width":1,"height":1,"depth":1,"color":"steel","cut":true},{"id":"core","label":"core","shape":"sphere","radius":0.1,"color":"amber"}]}"#)
        check(cut.isEmpty, "and fine once the shell is cut: \(cut)")
        let hidden = await issues(#"{"title":"Wall","parts":[{"id":"wall","shape":"box","width":3,"height":3,"depth":0.1,"position":[0,0,1],"color":"steel"},{"id":"back","label":"back","shape":"sphere","radius":0.1,"position":[0,0,-1],"color":"amber"}]}"#)
        check(hidden.contains { $0.contains("back (\"back\") is hidden behind wall") }, "a labelled part behind a nearer one is caught: \(hidden)")
        let twins = await issues(#"{"title":"T","parts":[{"id":"a","shape":"gear","color":"brass"},{"id":"b","shape":"gear","color":"brass"}]}"#)
        check(twins.contains { $0.contains("a and b are the same shape in the same place") }, "two parts on top of each other are caught: \(twins)")

        // The projection: one ball in the middle of the view, a pair left and right of it.
        let one = CookieSceneCheck.place(CookieScene.read(#"{"parts":[{"id":"a","shape":"sphere","radius":0.3,"color":"sky"}]}"#).scene!, exploded: false)[0]
        check(abs(one.anchor.x - 260) < 0.5 && abs(one.anchor.y - 180) < 0.5 && one.box.contains(one.anchor) && one.box.height > 200 && one.box.maxY < 360,
              "a lone ball sits centred and fills the frame: \(one.anchor) \(one.box)")
        let pair = CookieSceneCheck.place(CookieScene.read(#"{"parts":[{"id":"l","shape":"sphere","radius":0.1,"position":[-1,0,0],"color":"sky"},{"id":"r","shape":"sphere","radius":0.1,"position":[1,0,0],"color":"sky"}]}"#).scene!, exploded: false)
        check(pair[0].anchor.x < 200 && pair[1].anchor.x > 320 && pair[0].depth > pair[1].depth,
              "left stays left, and the model's left end turns away from the camera: \(pair.map(\.anchor))")
        let exploded = decode(await CookieModelShelf().build(["scene": #"{"title":"E","explode":true,"parts":[{"id":"a","shape":"box","position":[-0.2,0,0],"color":"steel"},{"id":"b","shape":"box","position":[0.2,0,0],"color":"steel"}]}"#]).output)
        check(((exploded["render"] as? [String: Any])?["exploded"] as? [String])?.first?.hasPrefix("exploded: the model spans") == true, "an exploding model is checked apart too")
    }
}
