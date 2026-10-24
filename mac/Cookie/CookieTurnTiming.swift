//
//  CookieTurnTiming.swift
//  Cookie
//
//  Where one turn's time goes, from the talk key to the last word heard, as
//  one log line: which stage is slow decides what to make faster. Numbers
//  only — never the words, the app or anything on the screen.
//

import QuartzCore

struct CookieTurnTiming {
    /// The stages of a turn, in the order they happen. Each is marked once, the first time.
    enum Stage: String, CaseIterable {
        /// The talk key went down (before t0; typed questions have none).
        case keyDown = "key down"
        /// The talk key came up, or a typed question was sent: t0.
        case release
        case transcript = "transcript"
        /// Every picture taken and redacted (redaction's own share is `redactionSeconds`).
        case capture = "capture"
        case requestSent = "sent"
        case firstToken = "first token"
        /// The first words went to the voice.
        case firstSpeakable = "first words to voice"
        case firstAudio = "first audio"
        case done = "done"
    }

    private(set) var times: [Stage: CFTimeInterval] = [:]
    /// Tool rounds: when each began and, once the model wrote again, how long it took.
    private(set) var toolRounds: [(start: CFTimeInterval, seconds: Double?)] = []
    /// Seconds spent redacting, summed over every picture (it runs inside capture).
    var redactionSeconds = 0.0
    /// Short facts about the turn's shape: "voice", "2 screens", "1280×800". Never content.
    var notes: [String] = []

    mutating func mark(_ stage: Stage, at time: CFTimeInterval = CACurrentMediaTime()) {
        if times[stage] == nil { times[stage] = time }
    }

    mutating func toolStarted(at time: CFTimeInterval = CACurrentMediaTime()) {
        closeToolRound(at: time)
        toolRounds.append((time, nil))
    }

    /// The model wrote again, or the run ended: the open tool round is over.
    mutating func closeToolRound(at time: CFTimeInterval = CACurrentMediaTime()) {
        guard let last = toolRounds.last, last.seconds == nil else { return }
        toolRounds[toolRounds.count - 1].seconds = time - last.start
    }

    /// One line: every stage reached, in seconds after t0 (the key-up, or the send).
    /// "⏱ turn voice 2 screens 1280×800 · held 2.40 s · transcript +0.18 · capture +0.31 (redaction 0.09) · …"
    func line(outcome: String = "") -> String {
        guard let origin = times[.release] else { return "⏱ turn: no start" }
        var parts = ["⏱ turn" + (notes.isEmpty ? "" : " " + notes.joined(separator: " ")) + (outcome.isEmpty ? "" : " (\(outcome))")]
        if let down = times[.keyDown] { parts.append("held " + Self.seconds(origin - down) + " s") }
        for stage in Stage.allCases where stage != .keyDown && stage != .release {
            guard let time = times[stage] else { continue }
            var part = "\(stage.rawValue) +" + Self.seconds(time - origin)
            if stage == .capture, redactionSeconds > 0 { part += " (redaction \(Self.seconds(redactionSeconds)))" }
            parts.append(part)
        }
        if !toolRounds.isEmpty {
            let total = toolRounds.compactMap(\.seconds).reduce(0, +)
            parts.append("tools \(toolRounds.count) (\(Self.seconds(total)) s)")
        }
        return parts.joined(separator: " · ")
    }

    private static func seconds(_ value: Double) -> String { String(format: "%.2f", value) }
}
