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
        check("aPictureLeavesOnlyWhenEveryCheckAnswered", aPictureLeavesOnlyWhenEveryCheckAnswered)
        check("aSecretIsCoveredByEveryWordItTouches", aSecretIsCoveredByEveryWordItTouches)
        check("onlyAPictureOfOneColourHasNoTextToRead", onlyAPictureOfOneColourHasNoTextToRead)
        check("imagesAreSentAtTheSizeTheModelReads", imagesAreSentAtTheSizeTheModelReads)
        check("modelPixelsLandOnTheirDisplayPoints", modelPixelsLandOnTheirDisplayPoints)
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

    static func aPictureLeavesOnlyWhenEveryCheckAnswered() {
        func unchecked(_ read: CookieScreenRead, secrets: Bool = true, faces: Bool = true) -> Bool {
            (try? Redactor.boxes(in: read, hideSecrets: secrets, blurFaces: faces)) == nil
        }
        let line = CookieTextLine(text: "hello", box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05),
                                  words: [CookieTextWord(start: 0, end: 5, box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05))])
        precondition(!unchecked(CookieScreenRead(lines: [line], faces: [], textRuns: [1])), "text read, faces looked for: sent")
        precondition(unchecked(CookieScreenRead(lines: [line], faces: nil, textRuns: [1])), "face detection failed: not sent")
        precondition(!unchecked(CookieScreenRead(lines: [line], faces: nil, textRuns: [1]), faces: false), "blurring faces is off")
        precondition(unchecked(CookieScreenRead(faces: [], textRuns: [nil])), "text recognition failed: not sent")
        precondition(unchecked(CookieScreenRead(faces: [], textRuns: [])), "no recognizer ran: not sent")
        // Nothing read: believed only from a clean run and a second sign the picture has no text.
        precondition(unchecked(CookieScreenRead(faces: [], textRuns: [0, 0], textRectangles: 14)), "the detector sees text the reader missed")
        precondition(unchecked(CookieScreenRead(faces: [], textRuns: [0, 0], textRectangles: nil)), "and nothing says it is blank")
        precondition(!unchecked(CookieScreenRead(faces: [], textRuns: [0, 0], textRectangles: 0)), "no text anywhere")
        precondition(!unchecked(CookieScreenRead(faces: [], textRuns: [0], textRectangles: nil, nearUniform: true)), "a blank screen")
        precondition(unchecked(CookieScreenRead(faces: [], textRuns: [nil, 0], textRectangles: 0)), "accurate failed: its silence isn't trusted")
        precondition(!unchecked(CookieScreenRead(lines: [line], faces: [], textRuns: [nil, 1])), "fast read what accurate couldn't")
        precondition(!unchecked(CookieScreenRead(faces: nil, textRuns: [nil]), secrets: false, faces: false), "nothing is on")
    }

    static func aSecretIsCoveredByEveryWordItTouches() {
        // A test card (4242 4242 4242 4242 passes Luhn) and a fake key, each in a line of words.
        let text = "card 4242 4242 4242 4242 key sk-ant-TESTONLY0000000000000000 ok"
        let ranges = CookieTextLine.wordRanges(in: text)
        precondition(ranges.count == 8 && ranges[1] == 5..<9 && ranges[7] == 61..<63, "\(ranges)")
        let words = ranges.enumerated().map { index, range in
            CookieTextWord(start: range.lowerBound, end: range.upperBound, box: CGRect(x: Double(index) * 0.1, y: 0.5, width: 0.08, height: 0.02))
        }
        let line = CookieTextLine(text: text, box: CGRect(x: 0, y: 0.5, width: 0.8, height: 0.02), words: words)
        let found = try! Redactor.boxes(in: CookieScreenRead(lines: [line], faces: [], textRuns: [1]), hideSecrets: true, blurFaces: true)
        precondition(found.text.count == 2, "\(found.text)")
        let card = found.text.first { $0.minX < 0.15 }!, key = found.text.first { $0.minX > 0.55 }!
        precondition(abs(card.minX - 0.1) < 1e-9 && abs(card.maxX - 0.48) < 1e-9, "all four groups of the card: \(card)")
        precondition(abs(key.minX - 0.6) < 1e-9 && abs(key.maxX - 0.68) < 1e-9, "the key's word: \(key)")
        // A secret in a line whose words have no boxes can't be covered: not sent.
        let boxless = CookieTextLine(text: text, box: line.box, words: [])
        precondition((try? Redactor.boxes(in: CookieScreenRead(lines: [boxless], faces: [], textRuns: [1]), hideSecrets: true, blurFaces: true)) == nil)
    }

    static func onlyAPictureOfOneColourHasNoTextToRead() {
        func picture(_ draw: (CGContext) -> Void) -> CGImage {
            let context = CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.setFillColor(gray: 0.95, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
            draw(context)
            return context.makeImage()!
        }
        precondition(CookieVisionText.nearlyUniform(picture { _ in }), "one colour")
        let gradient = picture { context in
            for x in 0..<640 { context.setFillColor(gray: CGFloat(x) / 640, alpha: 1); context.fill(CGRect(x: x, y: 0, width: 1, height: 400)) }
        }
        precondition(CookieVisionText.nearlyUniform(gradient), "a gentle gradient")
        let lines = picture { context in
            context.setFillColor(gray: 0, alpha: 1)
            for row in 0..<12 { for word in 0..<9 { context.fill(CGRect(x: 20 + word * 66, y: 20 + row * 30, width: 50, height: 9)) } }
        }
        precondition(!CookieVisionText.nearlyUniform(lines), "rows of word-shaped marks")
        precondition(CookieEdges.fraction(gray: [0, 255, 0, 255], width: 2, height: 2) == 0.5)
    }

    static func imagesAreSentAtTheSizeTheModelReads() {
        // Anthropic's own examples (vision-coordinates): the token cap, not the edge, decides.
        precondition(CookieImageSize.processed(width: 1075, height: 1520) == (924, 1307))
        precondition(CookieImageSize.processed(width: 1920, height: 1080) == (1456, 819))
        precondition(CookieImageSize.processed(width: 800, height: 600) == (800, 600), "an image that fits is unchanged")
        // A 14" MacBook Pro (1512×982 pt, Retina): its own aspect, nothing stretched, under the cap.
        let laptop = CookieImageSize.screenshot(displayWidth: 1512, displayHeight: 982, backingScale: 2)
        precondition(laptop == (1280, 831) && CookieImageSize.tokens(width: 1280, height: 831) <= CookieImageSize.maxTokens)
        precondition(CookieImageSize.screenshot(displayWidth: 3840, displayHeight: 1080, backingScale: 1) == (1280, 360))
        precondition(CookieImageSize.screenshot(displayWidth: 1024, displayHeight: 768, backingScale: 1) == (1024, 768), "never up-scaled")
        let portrait = CookieImageSize.screenshot(displayWidth: 1080, displayHeight: 1920, backingScale: 1)
        precondition(portrait == (720, 1280), "\(portrait)")
        for size in [laptop, portrait, CookieImageSize.screenshot(displayWidth: 2560, displayHeight: 1440, backingScale: 2)] {
            precondition(CookieImageSize.processed(width: size.width, height: size.height) == size, "already what the model reads")
        }
    }

    static func modelPixelsLandOnTheirDisplayPoints() {
        // A second display to the left of and above the main one, 1280×831 sent for 1512×982 pt.
        let display = CGRect(x: -1512, y: 200, width: 1512, height: 982)
        let centre = CookieDrawingResolver.global(CGPoint(x: 640, y: 415.5), imageWidth: 1280, imageHeight: 831, display: display)
        precondition(abs(centre.x - -756) < 0.001 && abs(centre.y - 691) < 0.001, "\(centre)")
        // Off the image: clamped inside it, so it stays on its own display.
        let outside = CookieDrawingResolver.global(CGPoint(x: -5, y: 900), imageWidth: 1280, imageHeight: 831, display: display)
        precondition(outside == CGPoint(x: -1512, y: 200))
        let topRight = CookieDrawingResolver.global(CGPoint(x: 1280, y: 0), imageWidth: 1280, imageHeight: 831, display: display)
        precondition(topRight == CGPoint(x: 0, y: 1182))
    }
}
