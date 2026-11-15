//
//  CookieSceneBeats.swift
//  Cookie
//
//  The director: a scene's beats put the explanation on one timeline. Each
//  beat names the exact words it belongs to and what happens there: the camera
//  frames a part (which lights up while Cookie's hand follows it), the model
//  comes apart or goes back together, a part is isolated, cut away or
//  labelled, the machine runs, slows or stops, a flow shows or hides, the
//  camera takes a preset view. When the reply is spoken each beat's words are
//  found in what is said (folded as a reader would, like `CookieLabelMatch`)
//  and the beat waits on the speech clock for them; a phrase that isn't there
//  falls evenly after the beat before it, and that is written down.
//
//  Beats are read with the scene's forgiving reader: an action naming a part,
//  group or flow the model doesn't have is an error that names what it does
//  have, never a silent no-op. build_model plays the beats through in order
//  and says which do nothing and which focus a part hidden at that moment.
//

import Foundation
import simd

extension CookieScene {
    struct Beat: Equatable {
        enum Action: Equatable {
            /// One of the stage's verbs: focus (camera, light and hand), explode, assemble, show-all,
            /// run, slow, stop, flow, cut, view.
            case command(CookieVisualCommand)
            /// Keeps a part or group bright (lit, with the hand on it) and fades the rest.
            case isolate(String)
            /// Shows a labelled part's label (every labelled part of a group).
            case label(String)

            /// As the model writes it.
            var text: String {
                switch self {
                case .isolate(let name): return "isolate:\(name)"
                case .label(let name): return "label:\(name)"
                case .command(let command):
                    switch command {
                    case .focus(let name): return "focus:\(name)"
                    case .explode: return "explode"
                    case .assemble: return "assemble"
                    case .showAll: return "show-all"
                    case .run: return "run"
                    case .slow: return "slow"
                    case .stop: return "stop"
                    case .flow(let id, let on): return "flow:\(id):\(on ? "on" : "off")"
                    case .cut(let name, let on): return "cut:\(name):\(on ? "on" : "off")"
                    case .view(let view): return "view:\(view.rawValue)"
                    default: return "\(command)"
                    }
                }
            }
        }

        /// The spoken words it belongs to, as written (empty: none given).
        let at: String
        /// Done in this order.
        let actions: [Action]

        var text: String { "\"\(at)\": " + actions.map(\.text).joined(separator: ", ") }
    }

    static let maxBeats = 24
    static let maxBeatActions = 8
    static let beatPhraseLength = 200
    static let beatActions = "focus:<part or group>, explode, assemble, isolate:<part or group>, show-all, run, slow, stop, flow:<id>:on|off, label:<part>, cut:<part>:on|off, view:front|side|top|overview"

    /// Where each beat falls on the speech clock, and what had to be guessed.
    struct Timeline: Equatable {
        /// UTF-16 offsets in the spoken text, one per beat, never going back.
        let offsets: [Int]
        /// Whether each beat's words were found (false: placed evenly after the beat before it).
        let found: [Bool]
        /// One line per beat that was placed evenly.
        let notes: [String]
    }

    /// The beats placed against the spoken text: each beat at the first place its words are said
    /// after the scene's tag and after the beat before it (whole words, folded as a reader would:
    /// case, runs of white space, curly quotes and dashes, and punctuation at the phrase's ends
    /// don't matter). A beat whose words aren't there falls evenly between the beat before it and
    /// the next one found (or the end of the words).
    func timeline(in spoken: String) -> Timeline {
        let length = spoken.utf16.count
        let start = min(max(0, offset), length)
        let folded = Folded([spoken])
        let characters = folded.characters
        let starts = folded.origins.map { $0.range.lowerBound.utf16Offset(in: spoken) }
        let ends = folded.origins.map { $0.range.upperBound.utf16Offset(in: spoken) }
        func wordy(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        var cursor = start
        var places: [Int?] = []
        for beat in beats {
            let needle = Folded([beat.at.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))]).characters
            let match = needle.isEmpty ? nil : folded.ranges(of: needle).first { range in
                starts[range.lowerBound] >= cursor
                    && (range.lowerBound == 0 || !wordy(needle[0]) || !wordy(characters[range.lowerBound - 1]))
                    && (range.upperBound == characters.count || !wordy(needle[needle.count - 1]) || !wordy(characters[range.upperBound]))
            }
            if let match {
                places.append(starts[match.lowerBound])
                cursor = ends[match.upperBound - 1]
            } else {
                places.append(nil)
            }
        }
        var offsets: [Int] = [], notes: [String] = []
        var index = 0
        while index < places.count {
            if let place = places[index] { offsets.append(place); index += 1; continue }
            // A run of beats whose words weren't found: spread evenly up to the next one found.
            let previous = offsets.last ?? start
            var end = index
            while end < places.count, places[end] == nil { end += 1 }
            let next = end < places.count ? places[end]! : length
            for k in index..<end {
                offsets.append(previous + (next - previous) * (k - index + 1) / (end - index + 1))
                notes.append(beats[k].at.isEmpty ? "beats[\(k)]: no words given; placed evenly after the beat before it"
                             : "beats[\(k)] \"\(beats[k].at)\": not in the spoken words after the beat before it; placed evenly after that")
            }
            index = end
        }
        return Timeline(offsets: offsets, found: places.map { $0 != nil }, notes: notes)
    }
}

// MARK: - Reading

extension SceneReader {
    /// The scene's beats, read against its parts, groups and flows.
    mutating func readBeats(_ raw: Any?, _ scene: Scene) -> [Scene.Beat] {
        guard let raw else { return [] }
        guard let items = raw as? [Any] else {
            errors.append("scene.beats: must be a list of {\"at\":\"words you'll say\",\"do\":[actions]}; left out"); return []
        }
        if items.count > Scene.maxBeats { errors.append("scene.beats: \(items.count) given, past the limit of \(Scene.maxBeats); the rest left out") }
        var beats: [Scene.Beat] = []
        for (index, item) in items.prefix(Scene.maxBeats).enumerated() {
            let at = "beats[\(index)]"
            guard let item = item as? [String: Any] else { errors.append("\(at): must be an object {\"at\":…,\"do\":[…]}; left out"); continue }
            for key in item.keys.sorted() where !["at", "do", "say", "when", "actions", "action"].contains(key) {
                repairs.append("\(at).\(key): not a beat field; ignored")
            }
            var phrase = ""
            if let given = item["at"] ?? item["say"] ?? item["when"] {
                if item["at"] == nil { repairs.append("\(at).\(item["say"] != nil ? "say" : "when"): read as at") }
                guard let words = text(given) else { errors.append("\(at).at: must be the words, as text; left out"); continue }
                phrase = words.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if phrase.isEmpty { repairs.append("\(at).at: missing; it falls evenly after the beat before it") }
            phrase = shortened(phrase, to: Scene.beatPhraseLength, at: "\(at).at")

            let given = item["do"] ?? item["actions"] ?? item["action"]
            if item["do"] == nil, given != nil { repairs.append("\(at).\(item["actions"] != nil ? "actions" : "action"): read as do") }
            let list: [Any]
            if let many = given as? [Any] {
                list = many
            } else if let one = text(given) {
                list = [one]
                repairs.append("\(at).do: one action, not a list; read as [\"\(one)\"]")
            } else {
                errors.append("\(at).do: missing; list what happens, such as [\"focus:\(scene.parts[0].id)\"]; left out"); continue
            }
            if list.count > Scene.maxBeatActions {
                errors.append("\(at).do: \(list.count) actions, past the limit of \(Scene.maxBeatActions); the rest left out")
            }
            var actions: [Scene.Beat.Action] = []
            for (k, raw) in list.prefix(Scene.maxBeatActions).enumerated() {
                if let action = beatAction(raw, scene, at: "\(at).do[\(k)]") { actions.append(action) }
            }
            guard !actions.isEmpty else { errors.append("\(at): no action could be read, so the beat is left out"); continue }
            beats.append(.init(at: phrase, actions: actions))
        }
        return beats
    }

    private mutating func beatAction(_ raw: Any, _ scene: Scene, at: String) -> Scene.Beat.Action? {
        guard let given = text(raw)?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty else {
            errors.append("\(at): must be an action written as text, one of \(Scene.beatActions)"); return nil
        }
        var fields = given.split(separator: ":", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let written = Scene.fold(fields.removeFirst())
        let aliases = ["showall": "show-all", "slowmotion": "slow", "play": "run", "start": "run", "pause": "stop", "camera": "view"]
        let verb = aliases[written] ?? written
        if verb != written && verb != "show-all" { repairs.append("\(at): \"\(given)\" read as \(verb)") }

        /// A verb that takes nothing after it.
        func plain(_ command: CookieVisualCommand) -> Scene.Beat.Action {
            if fields.contains(where: { !$0.isEmpty }) { repairs.append("\(at): \(verb) takes nothing after it; \"\(fields.joined(separator: ":"))\" ignored") }
            return .command(command)
        }
        /// The on or off at the end, or on (repaired) when it's left out; nil (an error) when it's something else.
        func toggle() -> Bool? {
            guard fields.count >= 2 else { repairs.append("\(at): \"\(given)\" has no on or off; read as on"); return true }
            let word = fields.removeLast().lowercased()
            if ["on", "show", "true"].contains(word) { return true }
            if ["off", "hide", "false"].contains(word) { return false }
            errors.append("\(at): \"\(word)\" in \"\(given)\" isn't on or off"); return nil
        }

        switch verb {
        case "explode": return plain(.explode)
        case "assemble": return plain(.assemble)
        case "show-all": return plain(.showAll)
        case "run", "slow", "stop":
            guard scene.hasMotion else {
                errors.append("\(at): \(verb): nothing in the model moves (no joints, links or flows); give it a joint or a flow"); return nil
            }
            return plain(verb == "run" ? .run : verb == "slow" ? .slow : .stop)
        case "focus", "isolate", "label":
            guard let name = beatTarget(fields.joined(separator: ":"), scene, verb: verb, at: at) else { return nil }
            if verb == "label" {
                guard scene.parts(named: name).contains(where: { $0.label != nil }) else {
                    errors.append("\(at): \(name) has no label to show; give it a \"label\""); return nil
                }
                return .label(name)
            }
            return verb == "focus" ? .command(.focus(name)) : .isolate(name)
        case "cut":
            guard let on = toggle(), let name = beatTarget(fields.joined(separator: ":"), scene, verb: verb, at: at) else { return nil }
            return .command(.cut(name, on: on))
        case "flow":
            guard let on = toggle() else { return nil }
            let id = fields.joined(separator: ":")
            guard !scene.flows.isEmpty else { errors.append("\(at): the model has no flows; give it one under \"flows\""); return nil }
            let ids = scene.flows.map(\.id)
            guard let flow = ids.first(where: { $0 == id }) ?? ids.first(where: { !Scene.fold(id).isEmpty && Scene.fold($0) == Scene.fold(id) }) else {
                errors.append("\(at): \"\(id)\" isn't a flow (flows: \(ids.joined(separator: ", ")))"); return nil
            }
            if flow != id { repairs.append("\(at): \"\(id)\" read as \(flow)") }
            return .command(.flow(flow, on: on))
        case "view":
            let name = Scene.fold(fields.joined())
            let near: [String: CookieSceneCameraRig.View] = ["overall": .overview, "whole": .overview, "default": .overview, "home": .overview,
                                                            "above": .top, "fromabove": .top, "profile": .side]
            guard let view = CookieSceneCameraRig.View(rawValue: name) ?? near[name] else {
                errors.append("\(at): \"\(fields.joined(separator: ":"))\" isn't a view; front, side, top or overview"); return nil
            }
            if view.rawValue != name { repairs.append("\(at): \"\(given)\" read as view:\(view.rawValue)") }
            return .command(.view(view))
        default:
            errors.append("\(at): \"\(given)\" isn't an action; one of \(Scene.beatActions)"); return nil
        }
    }

    /// A part or group by name, loosely; an error naming what the model has when there's no such thing.
    private mutating func beatTarget(_ given: String, _ scene: Scene, verb: String, at: String) -> String? {
        guard !given.isEmpty else { errors.append("\(at): \(verb) needs a part; write \(verb):<part id>"); return nil }
        guard let name = scene.resolve(given) else {
            let groups = Array(Set(scene.parts.compactMap(\.group))).sorted()
            errors.append("\(at): \"\(given)\" isn't a part or group (parts: \(scene.parts.map(\.id).prefix(12).joined(separator: ", "))"
                + (groups.isEmpty ? "" : "; groups: " + groups.joined(separator: ", ")) + ")")
            return nil
        }
        if name != given { repairs.append("\(at): \"\(given)\" read as \(name)") }
        return name
    }
}

// MARK: - The check

extension CookieSceneCheck {
    /// The beats played through in order, from the state the model appears in: each beat and what it
    /// does, and as issues every action that does nothing at that moment (a focus on the part already
    /// focused, a flow turned on that's already on) and every focus on a part hidden then (sealed
    /// inside an opaque part that isn't cut, faded or exploded away).
    static func beats(_ scene: CookieScene, until deadline: Date) -> View {
        enum Shot: Equatable { case view(CookieSceneCameraRig.View), part(Set<String>) }
        var view = View()
        var exploded = scene.explode, running = scene.run, slow = false
        var flows = Set(scene.flows.filter(\.on).map(\.id)), cut = Set(scene.parts.filter(\.cut).map(\.id))
        var isolated: Set<String>?, lit: Set<String> = [], labels: Set<String> = []
        var shot = Shot.view(.overview)
        func members(_ name: String) -> Set<String> { Set(scene.parts(named: name).map(\.id)) }
        func firstLabelled(_ name: String) -> String? { scene.parts(named: name).first { $0.label != nil }?.id }

        for (index, beat) in scene.beats.enumerated() {
            if Date() > deadline { view.lines.append("beats check cut short at two seconds"); break }
            view.lines.append("beats[\(index)] \(beat.text)")
            for action in beat.actions {
                var idle: String?
                switch action {
                case .label(let name):
                    let ids = Set(scene.parts(named: name).filter { $0.label != nil }.map(\.id))
                    if ids.isSubset(of: labels) { idle = "\(name)'s label is already showing" }
                    labels.formUnion(ids)
                case .isolate(let name):
                    let ids = members(name)
                    if isolated == ids { idle = "\(name) is already isolated" }
                    isolated = ids
                    lit = ids
                    if let id = firstLabelled(name) { labels.insert(id) }
                case .command(let command):
                    switch command {
                    case .focus(let name):
                        let ids = members(name)
                        if shot == .part(ids), lit == ids { idle = "\(name) is already focused" }
                        let faded = isolated
                        if let hidden = sealed(ids, in: scene, exploded: exploded, cut: cut, faded: { id in faded.map { !$0.contains(id) } ?? false }) {
                            view.issues.append("beats[\(index)] \"\(beat.at)\": focus:\(name) frames \(hidden.part) while it's sealed inside \(hidden.by), which is opaque; add cut:\(hidden.by):on (or explode) before it")
                        }
                        shot = .part(ids)
                        lit = ids
                        isolated?.formUnion(ids)
                        if let id = firstLabelled(name) { labels.insert(id) }
                    case .explode, .assemble:
                        if exploded == (command == .explode) { idle = "the model is already \(exploded ? "exploded" : "assembled")" }
                        exploded = command == .explode
                        shot = .view(.overview)
                    case .showAll:
                        if isolated == nil { idle = "nothing is isolated" }
                        isolated = nil
                    case .run, .slow:
                        if running, slow == (command == .slow) { idle = "it's already running\(slow ? " in slow motion" : "")" }
                        running = true
                        slow = command == .slow
                    case .stop:
                        if !running { idle = "it isn't running" }
                        running = false
                    case .flow(let id, let on):
                        if flows.contains(id) == on { idle = "\(id) is already \(on ? "on" : "off")" }
                        if on { flows.insert(id) } else { flows.remove(id) }
                    case .cut(let name, let on):
                        let ids = members(name)
                        if on ? ids.isSubset(of: cut) : ids.isDisjoint(with: cut) { idle = "\(name) is already \(on ? "cut" : "solid")" }
                        if on { cut.formUnion(ids) } else { cut.subtract(ids) }
                    case .view(let preset):
                        if shot == .view(preset) { idle = "the camera is already on the \(preset.rawValue) view" }
                        shot = .view(preset)
                    default: break
                    }
                }
                if let idle { view.issues.append("beats[\(index)] \"\(beat.at)\": \(action.text) does nothing; \(idle)") }
            }
        }
        return view
    }

    /// When every one of `ids` sits sealed inside an opaque part (not one of them, not cut, glass or
    /// faded), the first and what seals it; nil when any of them can be seen.
    static func sealed(_ ids: Set<String>, in scene: CookieScene, exploded: Bool, cut: Set<String>,
                       faded: (String) -> Bool) -> (part: String, by: String)? {
        let placed = place(scene, exploded: exploded)
        var first: (part: String, by: String)?
        for b in placed where ids.contains(b.part.id) {
            guard let a = placed.first(where: { a in
                !ids.contains(a.part.id) && !cut.contains(a.part.id) && a.part.tint != .glass && !faded(a.part.id) && a.volume > b.volume
                    && all(b.low .>= a.low - 0.001) && all(b.high .<= a.high + 0.001) && encloses(a, b)
            }) else { return nil }
            if first == nil { first = (b.part.id, a.part.id) }
        }
        return first
    }
}
