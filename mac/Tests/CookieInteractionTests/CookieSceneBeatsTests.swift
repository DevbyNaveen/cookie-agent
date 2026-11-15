import CoreGraphics
import Foundation
import simd

/// The director: a scene's beats read forgivingly (every repair and error named, an unknown part or
/// action never silent); their words are found in the spoken reply, folded as a reader would, and a
/// beat whose words aren't there falls evenly after the one before and is written down; build_model
/// lists the beats and flags those that do nothing or focus a hidden part; a beat moves the camera,
/// light, hand, labels and motion together; and the prompt's jet engine, built through build_model
/// and shown by its reply, runs each beat as the voice reaches its words, holding still once stopped.
@MainActor
enum CookieSceneBeatsTests {
    private static var count = 0
    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        count += 1
    }

    private static func decode(_ output: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] ?? [:]
    }

    /// A pump: a casing round an impeller on a spinning shaft, water flowing through.
    static func pump(_ beats: String) -> String {
        #"""
        {"title":"Pump","parts":[
        {"id":"casing","label":"casing","shape":"box","width":1,"height":1,"depth":1,"color":"steel"},
        {"id":"impeller","label":"impeller","shape":"bladeRing","tip":0.3,"hub":0.08,"blades":6,"color":"amber","group":"rotor"},
        {"id":"inlet","label":"inlet","shape":"cylinder","radius":0.08,"height":0.4,"position":[-0.9,0,0],"rotation":[0,0,90],"color":"sky"},
        {"id":"outlet","shape":"cylinder","radius":0.08,"height":0.4,"position":[0.9,0,0],"rotation":[0,0,90],"color":"sky"}],
        "joints":[{"id":"spin","kind":"spin","part":"rotor","axis":[0,1,0],"rate":0.5}],
        "flows":[{"id":"water","through":["inlet","impeller","outlet"],"color":"sky"}],
        "beats":\#(beats)}
        """#
    }

    static func run() async {
        count = 0
        reading()
        timeline()
        checks()
        stage()
        await example()
        print("\(count) scene beat checks passed.")
    }

    // MARK: Reading

    private static func reading() {
        let clean = CookieScene.read(pump(#"[{"at":"water comes in","do":["focus:inlet","flow:water:on"]},{"at":"the impeller flings it","do":["isolate:rotor","run","label:impeller"]},{"at":"and out it goes","do":["show-all","view:side","cut:casing:on","stop"]}]"#))
        let scene = clean.scene!
        check(clean.errors.isEmpty && clean.repairs.isEmpty, "a scene's beats read cleanly: \(clean.errors) \(clean.repairs)")
        check(scene.beats.map(\.at) == ["water comes in", "the impeller flings it", "and out it goes"]
              && scene.beats[0].actions == [.command(.focus("inlet")), .command(.flow("water", on: true))]
              && scene.beats[1].actions == [.isolate("rotor"), .command(.run), .label("impeller")]
              && scene.beats[2].actions == [.command(.showAll), .command(.view(.side)), .command(.cut("casing", on: true)), .command(.stop)],
              "each beat keeps its words and its actions in order: \(scene.beats)")
        check(scene.beats[1].text == "\"the impeller flings it\": isolate:rotor, run, label:impeller", "and reads back as the model wrote it")

        // Forgiving in: loose names, a single action, aliases, a missing toggle or phrase.
        let loose = CookieScene.read(pump(#"[{"say":"first","action":"Focus:IMPELLER"},{"do":["play","flow:Water","view:above","Show-All"]},{"at":"x","do":"slow-motion","colour":1}]"#))
        check(loose.errors.isEmpty && loose.scene!.beats.count == 3, "loose beats still read: \(loose.errors)")
        check(loose.scene!.beats[0].actions == [.command(.focus("impeller"))] && loose.scene!.beats[1].actions == [.command(.run), .command(.flow("water", on: true)), .command(.view(.top)), .command(.showAll)]
              && loose.scene!.beats[2].actions == [.command(.slow)], "each read as what it plainly means: \(loose.scene!.beats)")
        for repair in ["beats[0].say: read as at", "beats[0].action: read as do", "beats[0].do: one action, not a list", "beats[0].do[0]: \"IMPELLER\" read as impeller",
                       "beats[1].at: missing; it falls evenly", "beats[1].do[0]: \"play\" read as run", "beats[1].do[1]: \"flow:Water\" has no on or off; read as on",
                       "beats[1].do[1]: \"Water\" read as water", "beats[1].do[2]: \"view:above\" read as view:top", "beats[2].colour: not a beat field", "beats[2].do[0]: \"slow-motion\" read as slow"] {
            check(loose.repairs.contains { $0.hasPrefix(repair) }, "the repair is written down: \(repair) in \(loose.repairs)")
        }

        // Strict out: what can't be done is named, never silently dropped.
        let wrong = CookieScene.read(pump(#"[{"at":"a","do":["focus:blade","wiggle","flow:steam:on","label:outlet","cut:casing:maybe","view:back"]},{"at":"b","do":["focus:inlet"]},{"at":"c","do":[]},{"at":"d"}]"#))
        let errors = wrong.errors
        check(errors.contains { $0.hasPrefix("beats[0].do[0]: \"blade\" isn't a part or group (parts: casing, impeller, inlet, outlet; groups: rotor)") }, "an unknown part names what there is: \(errors)")
        check(errors.contains { $0.hasPrefix("beats[0].do[1]: \"wiggle\" isn't an action; one of focus:") }, "an unknown action lists the actions")
        check(errors.contains { $0 == "beats[0].do[2]: \"steam\" isn't a flow (flows: water)" }, "an unknown flow names the flows")
        check(errors.contains { $0.hasPrefix("beats[0].do[3]: outlet has no label") }, "a label for an unlabelled part is an error")
        check(errors.contains { $0.hasPrefix("beats[0].do[4]: \"maybe\"") } && errors.contains { $0.hasPrefix("beats[0].do[5]: \"back\" isn't a view") }, "so are a bad toggle and a bad view")
        check(errors.contains { $0.hasPrefix("beats[2]: no action could be read") } && errors.contains { $0.hasPrefix("beats[3].do: missing") },
              "a beat with nothing to do is left out and said so")
        check(wrong.scene!.beats.map(\.at) == ["b"], "the readable beat stays: \(wrong.scene!.beats)")
        check(CookieScene.leftOutNote(wrong) == "One of the model's steps couldn't be followed: \(errors[0]) (and \(errors.count - 1) more).",
              "and the person hears it as a step, not a missing part")
        let still = CookieScene.read(#"{"title":"Block","parts":[{"id":"a","shape":"box","color":"steel"}],"beats":[{"at":"go","do":["run"]}]}"#)
        check(still.errors.first?.hasPrefix("beats[0].do[0]: run: nothing in the model moves") == true, "a model that can't move can't run: \(still.errors)")
        let notList = CookieScene.read(#"{"title":"Block","parts":[{"id":"a","shape":"box","color":"steel"}],"beats":{"at":"go"}}"#)
        check(notList.errors.first?.hasPrefix("scene.beats: must be a list") == true && notList.scene?.beats.isEmpty == true, "beats that aren't a list are named")
    }

    // MARK: Timeline

    private static func timeline() {
        var scene = CookieScene.read(pump(#"[{"at":"Water comes in,","do":["focus:inlet"]},{"at":"the impeller","do":["focus:impeller"]},{"at":"never said","do":["run"]},{"at":"out it goes","do":["stop"]}]"#)).scene!
        let spoken = "here's a pump. water comes in, the impeller \u{2014} spinning \u{2014} flings it, and out it goes."
        scene.offset = 15
        let placed = scene.timeline(in: spoken)
        let text = spoken as NSString
        let water = text.range(of: "water").location, impeller = text.range(of: "the impeller").location, out = text.range(of: "out it goes").location
        check(placed.offsets[0] == water && placed.offsets[1] == impeller && placed.offsets[3] == out, "each beat waits for its words, case and punctuation aside: \(placed.offsets)")
        check(placed.found == [true, true, false, true] && placed.offsets[2] == impeller + (out - impeller) / 2,
              "words never said fall evenly between the beats either side: \(placed.offsets)")
        check(placed.notes == ["beats[2] \"never said\": not in the spoken words after the beat before it; placed evenly after that"], "and that is written down")

        // Only after the tag, in order, and whole words.
        scene.offset = 0
        let early = CookieScene(title: "T", parts: scene.parts, explode: false, spin: false, offset: 20,
                                beats: [.init(at: "fan", actions: [.command(.focus("inlet"))]), .init(at: "the fan", actions: [.command(.focus("impeller"))]), .init(at: "", actions: [.command(.showAll)])])
        let words = "the fan is first. a fantastic one. now the fan again."
        let order = early.timeline(in: words)
        let again = (words as NSString).range(of: "the fan again").location
        check(order.offsets[0] == again + 4 && order.found[0], "a phrase said before the tag waits for the next time, never inside another word: \(order.offsets)")
        check(!order.found[1] && order.offsets[1] > order.offsets[0] && order.offsets[2] > order.offsets[1] && order.offsets[2] <= words.utf16.count,
              "a phrase already passed, and an empty one, spread evenly to the end: \(order.offsets)")
        check(order.notes.count == 2 && order.notes[1] == "beats[2]: no words given; placed evenly after the beat before it", "both noted")
    }

    // MARK: build_model's check

    private static func checks() {
        func issues(_ json: String) -> [String] { CookieSceneCheck.report(CookieScene.read(json).scene!, until: .distantFuture).issues }
        let idle = issues(pump(#"[{"at":"a","do":["view:overview","focus:inlet"]},{"at":"b","do":["focus:inlet","flow:water:on","stop"]},{"at":"c","do":["run","run","explode","explode","show-all","label:inlet","cut:casing:off"]}]"#))
        for expected in ["beats[0] \"a\": view:overview does nothing; the camera is already on the overview view",
                         "beats[1] \"b\": focus:inlet does nothing; inlet is already focused",
                         "beats[1] \"b\": flow:water:on does nothing; water is already on",
                         "beats[1] \"b\": stop does nothing; it isn't running",
                         "beats[2] \"c\": run does nothing; it's already running",
                         "beats[2] \"c\": explode does nothing; the model is already exploded",
                         "beats[2] \"c\": show-all does nothing; nothing is isolated",
                         "beats[2] \"c\": label:inlet does nothing; inlet's label is already showing",
                         "beats[2] \"c\": cut:casing:off does nothing; casing is already solid"] {
            check(idle.contains(expected), "a beat that does nothing is flagged: \(expected) in \(idle)")
        }
        check(idle.filter { $0.hasPrefix("beats[2] \"c\": run does nothing") }.count == 1 && !idle.contains { $0.hasPrefix("beats[0] \"a\": focus") },
              "but the first of each isn't")
        let hidden = issues(pump(#"[{"at":"a","do":["focus:impeller"]},{"at":"b","do":["view:side"]},{"at":"c","do":["cut:casing:on","focus:impeller"]}]"#))
        check(hidden.contains("beats[0] \"a\": focus:impeller frames impeller while it's sealed inside casing, which is opaque; add cut:casing:on (or explode) before it")
              && !hidden.contains { $0.hasPrefix("beats[1]") || $0.hasPrefix("beats[2]") }, "a focus on a part sealed inside an opaque one is caught, and fine once it's cut: \(hidden)")
        let isolated = issues(pump(#"[{"at":"a","do":["isolate:rotor","focus:impeller"]}]"#))
        check(!isolated.contains { $0.hasPrefix("beats[") }, "a faded casing doesn't hide what's in it: \(isolated)")
        let report = CookieSceneCheck.report(CookieScene.read(pump(#"[{"at":"a","do":["focus:inlet","run"]}]"#)).scene!, until: .distantFuture)
        check(report.beats?.lines == ["beats[0] \"a\": focus:inlet, run"], "the render lists each beat with its actions: \(report.beats?.lines ?? [])")
        check(CookieSceneCheck.report(CookieScene.read(pump("[]")).scene!, until: .distantFuture).beats == nil, "and says nothing of beats a model doesn't have")
    }

    // MARK: The stage

    private static func stage() {
        let scene = CookieScene.read(pump(#"[{"at":"a","do":["focus:inlet","flow:water:off"]},{"at":"b","do":["isolate:rotor","run","label:casing"]},{"at":"c","do":["explode","focus:inlet"]}]"#)).scene!
        let stage = CookieSceneStage(scene: scene, reduceMotion: false)
        let overview = stage.cameraShot
        stage.perform(scene.beats[0])
        for _ in 0..<180 { stage.step(1.0 / 60) }
        let framed = stage.cameraShot
        check(stage.activePart == "inlet" && stage.shownLabelIDs == ["inlet"] && !stage.flowsOn.contains("water"),
              "one beat lights the part, shows its label and turns the flow off together")
        check(simd_distance(framed.eye, framed.target) < simd_distance(overview.eye, overview.target) * 0.8
              && simd_distance(framed.target, stage.root.orientation.act(stage.placement(of: "inlet")!.position)) < 0.2,
              "while the camera flies in to frame it: \(framed)")
        stage.perform(scene.beats[1])
        check(stage.isFaded("casing") && !stage.isFaded("impeller") && stage.activePart == "impeller" && stage.playing
              && stage.shownLabelIDs == ["inlet", "impeller", "casing"] && stage.shownLabelled.map(\.id) == ["casing", "impeller", "inlet"],
              "the next isolates the rotor, sets it working and shows a label out of order, kept on its rail")
        stage.drag(CGSize(width: 50, height: 0))
        let held = stage.cameraShot.eye
        for _ in 0..<30 { stage.step(1.0 / 60) }
        stage.endDrag()
        check(simd_distance(stage.cameraShot.eye, held) < 1e-4, "the person's drag holds the camera between beats")
        stage.perform(scene.beats[2])
        for _ in 0..<240 { stage.step(1.0 / 60) }
        let target = CookieSceneMotion.placed(scene, scene.parts[2], pose: [:], explosion: 1).position
        check(stage.exploded && simd_distance(stage.cameraShot.target, stage.root.orientation.act(target)) < 0.12,
              "and the next beat takes the camera back, framing where the exploding part ends up: \(stage.cameraShot.target)")
        stage.pauseTeaching()
        check(stage.activePart == nil && stage.exploded && stage.playing && stage.isFaded("casing"), "an interruption leaves the model as the beats left it, and the hand lets go")
        stage.release()
    }

    // MARK: The prompt's example, end to end

    private static func example() async {
        let line = CookieSceneMotionTests.jetLine
        let reply = String(line[line.range(of: "the reply says \"")!.upperBound...].dropLast())
        check(!reply.contains("[VISUAL:"), "the prompt's planned explanation uses beats, not scattered tags")
        let shelf = CookieModelShelf()
        let built = decode(await shelf.build(["scene": CookieBuildModelTests.exampleScene(line)]).output)
        check(built["ok"] as? Bool == true && (built["issues"] as? [String])?.isEmpty == true && (built["errors"] as? [String])?.isEmpty == true,
              "the example builds with nothing to fix: \(built["issues"] ?? "") \(built["errors"] ?? "")")
        let beatLines = (built["render"] as? [String: Any])?["beats"] as? [String] ?? []
        check(beatLines.count == 6 && beatLines[0] == "beats[0] \"air comes in through the fan\": flow:air:on, focus:fan", "and lists its beats: \(beatLines)")

        // The reply shows the built model; every beat's words are in what is said, in order.
        let split = CookieReplyTags.split(reply)
        let scene = shelf.scene(split.tags.first { $0.kind == "SCENE" }!)!
        let placed = scene.timeline(in: split.spoken)
        check(placed.found.allSatisfy { $0 } && placed.notes.isEmpty, "the example's phrases match its sentence exactly: \(placed.notes)")
        let text = split.spoken as NSString
        check(zip(scene.beats, placed.offsets).allSatisfy { text.range(of: $0.at).location == $1 }, "each beat at its words")

        // On the speech clock: nothing runs before its words; each beat runs once as the voice reaches them.
        let clock = CookieSpeechClock()
        let stage = CookieSceneStage(scene: scene, reduceMotion: false)
        let director = CookieSceneDirector()
        var beats = 0
        director.onBeat = { beats += 1 }
        clock.begin(text: String(split.spoken.prefix(80)))
        director.schedule(scene, on: stage, clock: clock)
        clock.setText(split.spoken)
        clock.advance(toOffset: placed.offsets[0] - 1, progress: 0.1)
        check(beats == 0 && stage.activePart == nil && !stage.flowsOn.contains("air"), "nothing before the first words")
        clock.advance(toOffset: placed.offsets[0], progress: 0.2)
        check(beats == 1 && stage.activePart == "fan" && stage.flowsOn.contains("air") && stage.shownLabelIDs == ["fan"],
              "at \"air comes in through the fan\" the air flows and the fan is framed, lit and labelled")
        clock.advance(toOffset: placed.offsets[1], progress: 0.3)
        check(beats == 1, "the streamed words so far only placed the beats they hold")
        director.finish(spoken: split.spoken)
        director.schedule(scene, on: stage, clock: clock)
        check(beats == 2 && stage.activePart == "comp", "once the reply is whole the rest go on, without running the first again")
        clock.advance(toOffset: placed.offsets[4], progress: 0.7)
        check(beats == 5 && stage.activePart == "nozzle" && !stage.playing && stage.shownLabels == 5, "each part in turn as it's named")
        clock.stop()
        clock.begin(text: split.spoken)
        clock.advance(toOffset: placed.offsets[5] + 5, progress: 0.9)
        check(beats == 5 && !stage.playing && stage.activePart == "nozzle", "interrupted, the timeline holds where it was")
        director.schedule(scene, on: stage, clock: clock)
        check(beats == 6 && stage.playing && stage.activePart == "fan", "picked up again, \"share one shaft\" lights the spool and sets it working")
        stage.step(0.2)
        check(CookieScenePresenter.teachingContext(stage).contains("Motion: running") && CookieScenePresenter.teachingContext(stage).contains("Flows: air on"),
              "the follow-up knows it's running")
        clock.stop()
        stage.release()

        let prompt = CompanionManager.companionVoiceResponseSystemPrompt
        check(prompt.contains("direct the explanation with beats") && prompt.contains(CookieScene.beatActions.components(separatedBy: ",")[0].replacingOccurrences(of: "<part or group>", with: "part"))
              && prompt.contains("plan a new explanation with the model's beats instead"), "the prompt teaches beats and keeps inline verbs for follow-ups")
    }
}
