import Foundation
import RealityKit
import simd

/// Real-looking models: build_model takes {"asset":{"url"|"path"}}, fetches only https .usdz links within the
/// size cap, keeps them by the link's SHA-256 and lets the oldest go past the cache limit, opens only model files
/// inside the home folder, turns the file's named nodes into parts (pieces explode on their own), checks the
/// result like any model, and says plainly when it can't load one or can't point at its parts. No network:
/// the files are small .usda texts written here.
@MainActor
enum CookieModelAssetTests {
    private static var count = 0
    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        count += 1
    }

    private static func decode(_ output: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] ?? [:]
    }

    private static func failure(_ work: () throws -> Void) -> CookieModelAsset.Failure? {
        do { try work(); return nil } catch { return error as? CookieModelAsset.Failure }
    }

    /// A lamp: a base, an arm holding a shade and an unnamed rod, and a stand with a second shade.
    static let lamp = """
    #usda 1.0
    (
        defaultPrim = "Lamp"
        metersPerUnit = 1
        upAxis = "Y"
    )
    def Xform "Lamp"
    {
        def Cube "Base"
        {
            double size = 2
            double3 xformOp:translate = (0, -1, 0)
            float3 xformOp:scale = (1, 0.1, 1)
            uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:scale"]
        }
        def Xform "Arm"
        {
            double3 xformOp:translate = (0, 1, 0)
            uniform token[] xformOpOrder = ["xformOp:translate"]
            def Sphere "Shade"
            {
                double radius = 0.5
                double3 xformOp:translate = (0, 1, 0)
                uniform token[] xformOpOrder = ["xformOp:translate"]
            }
            def Cylinder "Mesh_0"
            {
                double radius = 0.1
                double height = 2
            }
        }
        def Xform "Stand"
        {
            double3 xformOp:translate = (1.5, 0, 0)
            uniform token[] xformOpOrder = ["xformOp:translate"]
            def Sphere "Shade"
            {
                double radius = 0.3
            }
        }
    }
    """

    /// Two pieces with exporter names only.
    static let blob = """
    #usda 1.0
    (
        defaultPrim = "Root"
    )
    def Xform "Root"
    {
        def Cube "Mesh_0"
        {
            double size = 1
        }
        def Sphere "Object_12"
        {
            double radius = 0.4
            double3 xformOp:translate = (2, 0, 0)
            uniform token[] xformOpOrder = ["xformOp:translate"]
        }
    }
    """

    static func run() async {
        count = 0
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cookie-model-asset-checks-\(UUID().uuidString)", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let outside = base.appendingPathComponent("elsewhere", isDirectory: true)
        let models = base.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: home.appendingPathComponent("Models"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let savedHome = CookieModelAsset.home, savedFolder = CookieModelAsset.folder
        CookieModelAsset.home = home
        CookieModelAsset.folder = models
        defer {
            CookieModelAsset.home = savedHome
            CookieModelAsset.folder = savedFolder
            try? FileManager.default.removeItem(at: base)
        }
        try? lamp.write(to: home.appendingPathComponent("Models/lamp.usda"), atomically: true, encoding: .utf8)
        try? blob.write(to: home.appendingPathComponent("blob.usda"), atomically: true, encoding: .utf8)

        addresses()
        paths(home: home, outside: outside)
        downloads()
        await cache(models)
        await timing()
        await discovery(home)
        await builds(home)
        await stage()
        prompt()
        print("\(count) real model checks passed.")
    }

    // MARK: Where a model may come from

    private static func addresses() {
        let good = try? CookieModelAsset.source(["url": "https://developer.apple.com/augmented-reality/quick-look/models/biplane/toy_biplane_idle.usdz"])
        check(good.map { if case .web = $0 { return true } else { return false } } == true, "an https .usdz link is fetched")
        check(failure { _ = try CookieModelAsset.source(["url": "http://example.com/a.usdz"]) }?.kind == .address, "plain http is refused")
        check(failure { _ = try CookieModelAsset.source(["url": "ftp://example.com/a.usdz"]) }?.message.contains("only https") == true, "so is any other scheme, by name")
        check(failure { _ = try CookieModelAsset.source(["url": "https://example.com/viewer.html"]) }?.kind == .notModel, "a page that shows a model isn't one")
        check(failure { _ = try CookieModelAsset.source(["url": "https://example.com/model.glb"]) }?.kind == .notModel, "only .usdz comes from the web")
        check(failure { _ = try CookieModelAsset.source(["url": "https://me:secret@example.com/a.usdz"]) }?.kind == .address, "a link carrying a password isn't fetched")
        check(failure { _ = try CookieModelAsset.source(["url": "not a link"]) }?.kind == .address, "words aren't a link")
        check(failure { _ = try CookieModelAsset.source([String: Any]()) }?.kind == .address && failure { _ = try CookieModelAsset.source("x") } != nil,
              "an asset needs a url or a path")
        check(CookieModelAsset.allowsRedirect(to: URL(string: "https://cdn.example.com/a.usdz")) && !CookieModelAsset.allowsRedirect(to: URL(string: "http://cdn.example.com/a.usdz"))
              && !CookieModelAsset.allowsRedirect(to: nil), "a redirect is followed only to https")
    }

    private static func paths(home: URL, outside: URL) {
        let file = try? CookieModelAsset.source(["path": "~/Models/lamp.usda"])
        check(file == .file(home.appendingPathComponent("Models/lamp.usda").standardizedFileURL.resolvingSymlinksInPath()), "a model file in the home folder opens: \(String(describing: file))")
        try? "x".write(to: outside.appendingPathComponent("away.usdz"), atomically: true, encoding: .utf8)
        check(failure { _ = try CookieModelAsset.source(["path": outside.appendingPathComponent("away.usdz").path]) }?.message.contains("home folder") == true,
              "a file outside the home folder isn't opened")
        check(failure { _ = try CookieModelAsset.source(["path": "~/../elsewhere/away.usdz"]) }?.kind == .address, "nor one reached by climbing out of it")
        try? FileManager.default.createSymbolicLink(at: home.appendingPathComponent("link.usdz"), withDestinationURL: outside.appendingPathComponent("away.usdz"))
        check(failure { _ = try CookieModelAsset.source(["path": "~/link.usdz"]) }?.kind == .address, "nor one linked from inside it")
        check(failure { _ = try CookieModelAsset.source(["path": "~/missing.usdz"]) }?.message.contains("no file") == true, "a missing file says so")
        try? "notes".write(to: home.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        check(failure { _ = try CookieModelAsset.source(["path": "~/notes.txt"]) }?.kind == .notModel, "a file that isn't a model isn't opened")
        try? FileManager.default.createDirectory(at: home.appendingPathComponent("folder.usdz"), withIntermediateDirectories: true)
        check(failure { _ = try CookieModelAsset.source(["path": "~/folder.usdz"]) }?.kind == .address, "a folder isn't a model file")
        check(failure { _ = try CookieModelAsset.source(["path": "Models/lamp.usda"]) }?.kind == .address, "a path is given whole")
    }

    // MARK: Fetching

    private static func downloads() {
        check(!CookieModelAsset.acceptable(contentType: "text/html; charset=utf-8") && !CookieModelAsset.acceptable(contentType: "application/json")
              && !CookieModelAsset.acceptable(contentType: "image/png"), "a page, JSON or a picture isn't a model")
        check(CookieModelAsset.acceptable(contentType: "model/vnd.usdz+zip") && CookieModelAsset.acceptable(contentType: "application/octet-stream")
              && CookieModelAsset.acceptable(contentType: nil), "a model, plain bytes or no type at all goes on to be checked")
        let receiver = CookieModelAsset.Receiver()
        check(failure { try receiver.begin(status: 404, contentType: nil, expected: -1) }?.kind == .network, "a 404 fetches nothing")
        check(failure { try receiver.begin(status: 200, contentType: "text/html", expected: 1000) }?.kind == .notModel, "a page is refused before its body")
        check(failure { try receiver.begin(status: 200, contentType: nil, expected: Int64(CookieModelAsset.maxBytes) + 1) }?.kind == .tooBig,
              "a file announced past 50 MB isn't started")
        check(failure { try receiver.begin(status: 200, contentType: "model/vnd.usdz+zip", expected: -1) } == nil, "a model of unknown size starts")
        var small = CookieModelAsset.Receiver(limit: 10)
        check(failure { try small.add(Data([0x50, 0x4B, 0x03, 0x04, 0, 0])) } == nil && failure { try small.add(Data([1, 2, 3, 4])) } == nil, "chunks within the cap come in")
        check(failure { try small.finish() } == nil, "a zip's first bytes read as a USDZ")
        check(failure { try small.add(Data([5])) }?.kind == .tooBig && small.received == 11, "the chunk that passes the cap stops it")
        var page = CookieModelAsset.Receiver()
        _ = failure { try page.add(Data("<html>".utf8)) }
        check(failure { try page.finish() }?.kind == .notModel, "bytes that aren't a USDZ aren't kept")
        check(failure { try CookieModelAsset.Receiver().finish() }?.kind == .notModel, "nor is an empty file")
        check(CookieModelDownload.failure(URLError(.notConnectedToInternet)).message.contains("offline")
              && CookieModelDownload.failure(URLError(.timedOut)).kind == .timeout
              && CookieModelDownload.failure(URLError(.cancelled)).kind == .cancelled, "network errors say what happened")
    }

    private static func cache(_ folder: URL) async {
        let link = URL(string: "https://example.com/models/lamp.usdz")!
        let file = CookieModelAsset.cacheFile(for: link, in: folder)
        check(file == CookieModelAsset.cacheFile(for: link, in: folder) && file != CookieModelAsset.cacheFile(for: URL(string: "https://example.com/models/lamp2.usdz")!, in: folder),
              "a link has one file, its own")
        check(file.deletingPathExtension().lastPathComponent.count == 64 && file.pathExtension == "usdz" && file.deletingLastPathComponent() == folder,
              "named by the link's SHA-256, in the models folder")
        // Asked again: the kept copy, no fetch (there's no network here), marked as just used.
        try? Data([0x50, 0x4B, 0x03, 0x04, 9, 9]).write(to: file)
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: file.path)
        let again = try? await CookieModelAsset.fetch(link, into: folder)
        check(again?.reused == true && again?.file == file && again?.bytes == 6, "the second ask reuses the kept file")
        let used = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        check(Date().timeIntervalSince(used) < 60, "and it counts as used just now")

        // Eviction: oldest first, until under the limit, never the one just kept.
        let names = ["a", "b", "c", "d"].map { folder.appendingPathComponent($0).appendingPathExtension("usdz") }
        for (index, name) in names.enumerated() {
            try? Data(count: 400).write(to: name)
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index - 10) * 3600)], ofItemAtPath: name.path)
        }
        try? FileManager.default.removeItem(at: file)
        CookieModelAsset.evict(folder, limit: 1000, keeping: names[0])
        let left = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".usdz") })
        check(left == ["a.usdz", "d.usdz"], "the oldest go first until it fits, but not the file just fetched: \(left.sorted())")
        CookieModelAsset.evict(folder, limit: 10_000, keeping: nil)
        check(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".usdz") }.count == 2, "under the limit nothing goes")
        check(CookieModelAsset.cacheLimit == 500 * 1024 * 1024 && CookieModelAsset.maxBytes == 50 * 1024 * 1024 && CookieModelAsset.timeout == 20,
              "the limits are 500 MB kept, 50 MB a file, 20 s")
    }

    private static func timing() async {
        let started = Date()
        do {
            _ = try await CookieModelAsset.within(0.05, .init(.timeout, "too slow")) {
                try await Task.sleep(for: .seconds(5))
                return 1
            }
            check(false, "slow work times out")
        } catch {
            check((error as? CookieModelAsset.Failure)?.kind == .timeout && Date().timeIntervalSince(started) < 2, "slow work stops at its deadline")
        }
        let quick = try? await CookieModelAsset.within(1, .init(.timeout, "too slow")) { 7 }
        check(quick == 7, "quick work comes back")
    }

    // MARK: Reading the file

    private static func discovery(_ home: URL) async {
        let lampFile = home.appendingPathComponent("Models/lamp.usda")
        guard let prototype = try? await CookieModelAssets.shared.prototype(lampFile), let found = CookieModelAsset.discover(prototype) else {
            return check(false, "the lamp opens and has parts")
        }
        let ids = found.nodes.map(\.id)
        check(found.pieces.map(\.id) == ["base", "arm", "stand"], "the pieces are the children of the first node that branches: \(ids)")
        check(ids.contains("shade") && ids.contains("shade-2") && !ids.contains { $0.contains("mesh") }, "named nodes become parts, deduplicated; exporter names don't: \(ids)")
        check(found.nodes.first { $0.id == "shade" }?.piece == "arm" && found.nodes.first { $0.id == "shade-2" }?.piece == "stand", "each part belongs to its piece")
        let low = found.nodes.map { $0.centre - $0.size / 2 }.reduce(SIMD3<Float>(repeating: 9), simd_min)
        let high = found.nodes.map { $0.centre + $0.size / 2 }.reduce(SIMD3<Float>(repeating: -9), simd_max)
        check(abs(simd_length(high - low) / 2 - CookieModelAsset.radius) < 0.01 && simd_length((low + high) / 2) < 0.01,
              "the model is scaled to the scene's size and centred: \(low) \(high)")
        check(CookieModelAsset.meaningful("Front_Wheel") && !CookieModelAsset.meaningful("Mesh_0") && !CookieModelAsset.meaningful("polySurface12")
              && !CookieModelAsset.meaningful("Object_3") && !CookieModelAsset.meaningful("x"), "a name counts when it says what the part is")
        let blob = try? await CookieModelAssets.shared.prototype(home.appendingPathComponent("blob.usda"))
        let pieces = blob.flatMap(CookieModelAsset.discover)
        check(pieces?.nodes.map(\.id) == ["piece-1", "piece-2"] && pieces?.named.isEmpty == true, "unnamed pieces still explode, under Cookie's names: \(pieces?.nodes.map(\.id) ?? [])")
        let copy = CookieModelAssets.shared.copy(lampFile)
        check(copy != nil && copy !== prototype && CookieModelAsset.entity(at: found.nodes[1].path, in: copy!)?.name == "Arm", "a stage gets its own copy, with the same paths")
    }

    // MARK: build_model

    private static func builds(_ home: URL) async {
        let shelf = CookieModelShelf()
        let scene = """
        {"title":"desk lamp","asset":{"path":"~/Models/lamp.usda"},"labels":{"Shade":"lamp shade","base":"weighted base","Nope":"x"},
         "explode":true,"parts":[{"id":"x"}],"beats":[{"at":"the shade","do":["focus:shade"]},{"at":"the base","do":["focus:nowhere"]}]}
        """
        let result = await shelf.build(["scene": scene])
        let json = decode(result.output)
        check(!result.isError && json["ok"] as? Bool == true && json["id"] as? String == "desk-lamp" && json["show"] as? String == "[SCENE:#desk-lamp]",
              "a file in the home folder builds under its title's id: \(result.output.prefix(400))")
        check(json["can_point"] as? Bool == true && (json["parts"] as? [String])?.starts(with: ["base", "arm", "stand"]) == true, "its parts and whether Cookie can point at them")
        check(json["credit"] as? String == "your file lamp.usda", "it says whose it is")
        let repairs = json["repairs"] as? [String] ?? [], errors = json["errors"] as? [String] ?? []
        check(repairs.contains { $0.hasPrefix("scene.parts:") } && repairs.contains { $0.hasPrefix("labels.Nope:") }, "parts written anyway and a label for nothing are noted: \(repairs)")
        check(errors.contains { $0.contains("nowhere") }, "a beat focusing a part the file doesn't have is named: \(errors)")
        let render = json["render"] as? [String: Any] ?? [:]
        let assembled = render["assembled"] as? [String] ?? []
        check(assembled.contains { $0.hasPrefix("shade (\"lamp shade\"): x ") } && assembled.contains { $0.hasPrefix("arm: x ") }, "the render lists each part's projected box: \(assembled.prefix(4))")
        check(!assembled.contains { $0.contains("sits inside") } && !(json["issues"] as? [String] ?? []).contains { $0.contains("sealed") || $0.contains("hidden behind arm") },
              "a node inside its piece isn't sealed in it or hidden by it: \(json["issues"] ?? "")")
        check((render["asset"] as? [String])?.contains { $0.contains("named in the file") && $0.contains("shade") } == true && render["exploded"] != nil,
              "and what the file gave: \(render["asset"] ?? "")")

        // The reply's tag shows it.
        let tags = CookieReplyTags.split("here's the lamp [SCENE:#desk-lamp] and its shade").tags
        let shown = tags.lazy.compactMap(shelf.scene).first
        check(shown?.asset != nil && shown?.labelled.map(\.id) == ["base", "shade"] && shown?.beats.count == 1, "[SCENE:#id] shows the real model, labelled and directed")
        check(!shelf.loadFailed(tags) && CompanionManager.pictureFailureNote(tags, scene: true, cards: false, loadFailed: false) == nil, "a shown model needs no apology")
        check(CookieScene.read(#"{"title":"x","asset":{"url":"https://example.com/a.usdz"}}"#).errors.first?.contains("build_model") == true,
              "an inline scene can't fetch a model; it says to use build_model")

        // No names to point at.
        let plain = decode(await shelf.build(["scene": #"{"asset":{"path":"~/blob.usda"}}"#]).output)
        check(plain["ok"] as? Bool == true && plain["id"] as? String == "blob" && plain["can_point"] as? Bool == false, "an unnamed file still loads: \(plain["errors"] ?? "")")
        check((plain["issues"] as? [String])?.contains { $0.contains("can't point") } == true
              && ((plain["render"] as? [String: Any])?["asset"] as? [String])?.contains { $0.contains("can't point at its parts") } == true,
              "and the report says Cookie can't point at its parts")

        // Failures, plainly, and the reply says it couldn't load it.
        let insecure = await shelf.build(["scene": #"{"title":"biplane","asset":{"url":"http://example.com/biplane.usdz"}}"#])
        check(insecure.isError && decode(insecure.output)["errors"].map { "\($0)" }?.contains("only https") == true, "a bad link is refused plainly: \(insecure.output)")
        let failedTags = CookieReplyTags.split("the biplane [SCENE:#biplane] flies").tags
        check(shelf.loadFailed(failedTags) && shelf.reading(failedTags[0])?.errors.first?.contains("I couldn't load that model") == true,
              "showing it anyway reads as a model that couldn't be loaded")
        check(CompanionManager.pictureFailureNote(failedTags, scene: false, cards: false, loadFailed: shelf.loadFailed(failedTags)) == "I couldn't load that model.",
              "and the reply says so in one line")
        let fresh = CookieModelShelf()
        try? Data("not a model at all".utf8).write(to: home.appendingPathComponent("broken.usdz"))
        let broken = await fresh.build(["scene": #"{"title":"broken","asset":{"path":"~/broken.usdz"}}"#])
        check(broken.isError && decode(broken.output)["errors"].map { "\($0)" }?.contains("asset (load)") == true, "a file RealityKit can't open says so: \(broken.output)")
        let away = await fresh.build(["scene": #"{"title":"away","asset":{"path":"/etc/hosts.usdz"}}"#])
        check(away.isError && fresh.failedLoads["away"]?.contains("home folder") == true, "a path outside the home folder is refused by name")
        fresh.beginRun()
        check(fresh.failedLoads.isEmpty, "a new turn forgets last turn's failures")
    }

    // MARK: On stage

    private static func stage() async {
        let shelf = CookieModelShelf()
        _ = await shelf.build(["scene": #"{"title":"lamp","asset":{"path":"~/Models/lamp.usda"},"labels":{"Shade":"shade"}}"#])
        guard let scene = shelf.models["lamp"]?.scene else { return check(false, "the lamp is on the shelf") }
        let stage = CookieSceneStage(scene: scene, reduceMotion: true)
        check(stage.assetShown, "a file opened this turn shows at once")
        guard let base = stage.root.findEntity(named: "Base"), let shade = stage.root.findEntity(named: "Shade") else { return check(false, "the file's nodes are on stage") }
        let before = base.position(relativeTo: nil)
        stage.apply(.explode)
        stage.step(0.016)
        check(simd_distance(before, base.position(relativeTo: nil)) > 0.01, "exploding moves each piece out")
        stage.apply(.assemble)
        stage.step(0.016)
        check(simd_distance(before, base.position(relativeTo: nil)) < 0.001, "and assembling brings it back")
        stage.apply(.focus("shade"))
        check(stage.activePart == "shade", "a [VISUAL:focus:part] on a named node lights it")
        stage.apply(.cut("arm", on: true))
        stage.step(0.016)
        let opacity = (shade as? ModelEntity)?.components[OpacityComponent.self]?.opacity
            ?? shade.children.compactMap { $0.components[OpacityComponent.self]?.opacity }.first
        check(opacity == CookieSceneStage.cutOpacity, "cutting a piece makes its meshes see-through: \(String(describing: opacity))")
        check(CookieScenePresenter.teachingContext(stage).contains("focus:id") && CookieScenePresenter.teachingContext(stage).contains("shade"),
              "the next turn hears which parts it can point at")
        stage.release()
    }

    private static func prompt() {
        let prompt = CompanionManager.companionVoiceResponseSystemPrompt
        check(prompt.contains("\"asset\":{\"url\":\"https://...usdz\"}") && prompt.contains("never one you made up") && prompt.contains("parts teach best and stay the default"),
              "the voice prompt offers a real model only when wanted, from a link it found")
        check(CookieModelShelf.tool.description.contains("\"asset\""), "and build_model says how to pass one")
    }
}
