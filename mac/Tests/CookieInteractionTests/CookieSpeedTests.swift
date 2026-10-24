import AppKit

/// The pure parts of a fast, correct turn: timing, streaming speech, pictures, the pointer.
@MainActor
enum CookieSpeedTests {
    static func run() {
        var passed = 0
        func check(_ name: String, _ body: () -> Void) {
            body()
            passed += 1
            print("PASS \(name)")
        }
        check("aTurnLogsEveryStageItReachedAndNothingElse", aTurnLogsEveryStageItReachedAndNothingElse)
        check("aHalfWrittenTagNeverReachesTheVoice", aHalfWrittenTagNeverReachesTheVoice)
        check("theFirstClauseIsFlushedOnceItIsLongEnough", theFirstClauseIsFlushedOnceItIsLongEnough)
        check("alignmentFindsEachCharacterInTheSentText", alignmentFindsEachCharacterInTheSentText)
        check("chunkTimesBecomeAbsoluteAcrossGaps", chunkTimesBecomeAbsoluteAcrossGaps)
        print("\(passed) speed checks passed.")
    }

    static func aTurnLogsEveryStageItReachedAndNothingElse() {
        var timing = CookieTurnTiming()
        timing.mark(.keyDown, at: 10)
        timing.mark(.release, at: 12.4)
        timing.mark(.release, at: 99) // marked once: the first time wins
        timing.mark(.transcript, at: 12.58)
        timing.notes = ["voice", "1 screen"]
        timing.redactionSeconds = 0.09
        timing.mark(.capture, at: 12.71)
        timing.mark(.requestSent, at: 12.75)
        timing.toolStarted(at: 13.0)
        timing.closeToolRound(at: 14.5)
        timing.mark(.firstToken, at: 13.9)
        timing.mark(.done, at: 20.4)
        let line = timing.line()
        precondition(line == "⏱ turn voice 1 screen · held 2.40 s · transcript +0.18 · capture +0.31 (redaction 0.09) · sent +0.35 · first token +1.50 · done +8.00 · tools 1 (1.50 s)", line)
        precondition(CookieTurnTiming().line() == "⏱ turn: no start")
    }

    static func aHalfWrittenTagNeverReachesTheVoice() {
        var stream = CookieSpokenStream()
        // A lone "[" may start a tag: nothing from it on is spoken until it is decided.
        var step = stream.update("see the [")
        precondition(step.words == "see " && step.tags.isEmpty, step.words)
        step = stream.update("see the [POINT:12,40:Sa")
        precondition(step.words.isEmpty && step.tags.isEmpty)
        step = stream.update("see the [POINT:12,40:Save] button and")
        precondition(step.words == "the button " && step.tags.map(\.offset) == [8], step.words)
        // A "[" that is not a tag is spoken once its "]" shows it isn't one.
        step = stream.update("see the [POINT:12,40:Save] button and [this] one")
        precondition(step.words == "and [this] " && step.tags.isEmpty, step.words)
        // A tag at the very end settles only with the reply: trimming could still move it.
        step = stream.update("see the [POINT:12,40:Save] button and [this] one [NEXT:show me]")
        precondition(step.tags.isEmpty)
        step = stream.update("see the [POINT:12,40:Save] button and [this] one [NEXT:show me]", final: true)
        precondition(step.words == "one" && step.tags.map(\.kind) == ["NEXT"] && step.tags[0].offset == stream.spoken.utf16.count)
        precondition(stream.update("more", final: true).words.isEmpty, "a finished stream takes nothing more")
    }

    static func theFirstClauseIsFlushedOnceItIsLongEnough() {
        precondition(!CookieSpokenStream.holdsFirstClause("Sure, "), "too short to sound like speech")
        precondition(CookieSpokenStream.holdsFirstClause("The share menu is up top, "))
        precondition(!CookieSpokenStream.holdsFirstClause("The share menu is up top,and"))
        precondition(CookieSpokenStream.holdsFirstClause(String(repeating: "word ", count: 16)))
    }

    static func alignmentFindsEachCharacterInTheSentText() {
        var mapper = CookieAlignmentMapper()
        mapper.sent("Hi é\n")
        mapper.sent("you 👋 ")
        // The voice reports the newline as a space, skips the wave, and adds a trailing space.
        let offsets = mapper.map(["H", "i", " ", "é", " ", "y", "o", "u", " ", " "])
        precondition(offsets == [0, 1, 2, 3, 4, 5, 6, 7, 8, nil], "\(offsets)")
        // A character the voice made up is skipped; the next real one is found a few ahead.
        var second = CookieAlignmentMapper()
        second.sent("a-b c")
        precondition(second.map(["a", "x", "b", "c"]) == [0, nil, 2, 4])
        precondition(second.alignedThrough == 5 && second.sentLength == 5)
    }

    static func chunkTimesBecomeAbsoluteAcrossGaps() {
        var timeline = CookieAudioTimeline()
        precondition(timeline.schedule(frames: 24_000, playerSample: nil) == 0)
        // The player ran dry at 1 s and kept counting; the next chunk came at 1.5 s.
        precondition(timeline.schedule(frames: 12_000, playerSample: 36_000) == 24_000)
        precondition(timeline.gaps == 12_000)
        precondition(timeline.heard(playerSample: 30_000) == 24_000, "silence is not audio")
        precondition(timeline.heard(playerSample: 42_000) == 30_000)
        precondition(timeline.heard(playerSample: 99_000) == 36_000, "never past what was scheduled")
        // A chunk scheduled while the player still has audio adds no gap.
        _ = timeline.schedule(frames: 100, playerSample: 40_000)
        precondition(timeline.gaps == 12_000)

        var times = CookieCharacterTimes()
        times.add(offset: 0, seconds: 0)
        times.add(offset: 5, seconds: 0.4)
        times.add(offset: 3, seconds: 0.5) // out of order: ignored
        times.add(offset: 9, seconds: 1.1)
        precondition(times.offset(at: -0.1) == nil && times.offset(at: 0.39) == 0 && times.offset(at: 0.4) == 5 && times.offset(at: 5) == 9)
    }
}
