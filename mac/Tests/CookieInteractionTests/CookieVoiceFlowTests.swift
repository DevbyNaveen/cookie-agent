import AppKit
import Combine

@MainActor
enum CookieVoiceFlowTests {
    static func run() async {
        await playbackOwnsTheSpeakingLifetime()
        await cancelledBeforeAVoiceIsFoundNeverSpeaks()
        await oldCallbacksCannotFinishANewReply()
        await failedCloudSpeechUsesLocalPlaybackUntilItFinishes()
        await aStreamedReplySpeaksWholeWordsAndPlacesEachTagOnce()
        await cancellingACaptureDoesNotWaitForItsDeadline()
        await inactiveSelectionNotificationsCannotCancelSpeech()
        escapeRequiresAReleaseBeforeListeningAgain()
        print("8 voice flow checks passed.")
    }

    private static func playbackOwnsTheSpeakingLifetime() async {
        let output = FakeSpeechPlayback()
        let speaker = CookieSpeaker(makeLocal: { _ in output }, sourceProvider: { nil })
        var finished = false
        var started = false
        var progress = 0.0
        let task = Task {
            await speaker.speakText("A reply", onPlaybackProgress: { progress = $0 }) { started = true }
            finished = true
        }
        await waitUntil { output.finishes == 1 }
        precondition(output.words == "A reply" && speaker.state == .preparing && !finished && !started)
        output.onProgress?(2)
        precondition(progress == 0, "Words must not animate before audio starts")
        output.onStarted?()
        precondition(speaker.isPlaying && started && !finished)
        output.onProgress?(2)
        precondition(progress == 2.0 / 7.0)
        let staleProgress = output.onProgress
        try? await Task.sleep(for: .milliseconds(30))
        precondition(!finished && speaker.state == .speaking)
        output.onFinished?()
        await task.value
        precondition(finished && speaker.state == .idle)
        staleProgress?(5)
        precondition(progress == 2.0 / 7.0, "Late progress must not change completed speech")
    }

    private static func cancelledBeforeAVoiceIsFoundNeverSpeaks() async {
        let output = FakeSpeechPlayback()
        var pending: CheckedContinuation<CookieSpeaker.Source?, Never>?
        var cloudVoices = 0
        let speaker = CookieSpeaker(makeLocal: { _ in output }, makeCloud: { _ in cloudVoices += 1; return output },
                                    sourceProvider: { await withCheckedContinuation { pending = $0 } })
        let task = Task { await speaker.speakText("Cancelled") }
        await waitUntil { pending != nil }
        task.cancel()
        await task.value
        precondition(!speaker.isActive)
        pending?.resume(returning: .personal(key: "test-only"))
        try? await Task.sleep(for: .milliseconds(20))
        precondition(cloudVoices == 0 && output.words.isEmpty && output.finishes == 0)
    }

    private static func oldCallbacksCannotFinishANewReply() async {
        let first = FakeSpeechPlayback(), second = FakeSpeechPlayback()
        var count = 0
        let speaker = CookieSpeaker(makeLocal: { _ in count += 1; return count == 1 ? first : second }, sourceProvider: { nil })
        let firstTask = Task { await speaker.speakText("First") }
        await waitUntil { first.finishes == 1 }
        let staleStart = first.onStarted, staleFinish = first.onFinished
        let secondTask = Task { await speaker.speakText("Second") }
        await waitUntil { second.finishes == 1 }
        await firstTask.value
        precondition(first.stops == 1, "A new reply stops the voice of the one before")
        staleStart?()
        staleFinish?()
        precondition(speaker.state == .preparing && second.stops == 0)
        second.onStarted?()
        staleFinish?()
        precondition(speaker.isPlaying)
        speaker.stopPlayback()
        await secondTask.value
        precondition(!speaker.isActive && second.stops == 1)
    }

    private static func failedCloudSpeechUsesLocalPlaybackUntilItFinishes() async {
        let cloud = FakeSpeechPlayback(), local = FakeSpeechPlayback()
        var resumedAt: Int?
        let speaker = CookieSpeaker(makeLocal: { resumedAt = $0; return local }, makeCloud: { _ in cloud },
                                    sourceProvider: { .personal(key: "test-only") })
        let task = Task { await speaker.speakText("Local fallback. Then more.") }
        await waitUntil { cloud.finishes == 1 }
        precondition(cloud.opens == 1, "The cloud voice is opened before its words")
        // Heard up to "fallback." when the socket failed: the Mac's voice says the rest, from there.
        cloud.onStarted?()
        cloud.onProgress?(6)
        cloud.onFailed?(6)
        precondition(cloud.stops == 1 && resumedAt == 6 && local.words == "fallback. Then more." && local.finishes == 1)
        precondition(speaker.isPlaying, "The clock carries on; the reply isn't started again")
        local.onStarted?()
        local.onProgress?(16)
        precondition(speaker.clock.spokenOffset == 16)
        local.onFinished?()
        await task.value
        precondition(!speaker.isActive)
    }

    private static func aStreamedReplySpeaksWholeWordsAndPlacesEachTagOnce() async {
        let output = FakeSpeechPlayback()
        let speaker = CookieSpeaker(makeLocal: { _ in output }, sourceProvider: { nil })
        var settled: [CookieReplyTag] = []
        var firstWords = 0
        speaker.beginReply(onFirstWords: { firstWords += 1 }, onTags: { settled += $0 })
        // A tool round before any words: a short acknowledgement, aside from the reply.
        speaker.toolStarted()
        await waitUntil { output.asides == [CookieSpeaker.acknowledgement + " "] }
        speaker.update("Open the share menu [POINT:880,24:Share] up th")
        precondition(output.words == "Open the share menu up ", output.words)
        precondition(output.flushes == [false], "a short first piece waits for the voice's buffer")
        precondition(settled.map(\.kind) == ["POINT"] && settled[0].offset == 20 && firstWords == 1)
        speaker.update("Open the share menu [POINT:880,24:Share] up there, then pick copy link [DR")
        precondition(output.words == "Open the share menu up there, then pick copy ", output.words)
        precondition(output.flushes == [false, true], "the first clause is flushed")
        speaker.toolStarted()
        precondition(output.flushes.last == true && output.asides.count == 1, "a tool after words flushes, never acknowledges")
        speaker.finishReply("Open the share menu [POINT:880,24:Share] up there, then pick copy link [DRAW:number:#9:2].")
        precondition(output.words == "Open the share menu up there, then pick copy link.", output.words)
        precondition(settled.map(\.kind) == ["POINT", "DRAW"] && settled[1].offset == 49 && output.finishes == 1)
        precondition(speaker.spokenText == "Open the share menu up there, then pick copy link.")
        speaker.stopPlayback()
    }

    private static func cancellingACaptureDoesNotWaitForItsDeadline() async {
        let gate = SuspendedCapture()
        let task = Task { await withDeadline(seconds: 5) { await gate.wait() } }
        try? await Task.sleep(for: .milliseconds(20))
        let cancelledAt = Date()
        task.cancel()
        let result = await task.value
        precondition(result == nil && Date().timeIntervalSince(cancelledAt) < 0.3)
        await gate.finish()
    }

    private static func escapeRequiresAReleaseBeforeListeningAgain() {
        let monitor = GlobalPushToTalkShortcutMonitor()
        var starts = 0, cancellations = 0
        let transitions = monitor.shortcutTransitionPublisher.sink { if $0 == .pressed { starts += 1 } }
        let cancellation = monitor.cancellationPublisher.sink { cancellations += 1 }
        func flags(_ held: Bool) {
            let event = CGEvent(source: nil)!
            event.flags = held ? [.maskControl, .maskAlternate] : []
            _ = monitor.handleGlobalEventTap(eventType: .flagsChanged, event: event)
        }
        flags(true)
        precondition(starts == 1 && monitor.isShortcutCurrentlyPressed)
        let escape = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!
        escape.flags = [.maskControl, .maskAlternate]
        _ = monitor.handleGlobalEventTap(eventType: .keyDown, event: escape)
        precondition(cancellations == 1 && !monitor.isShortcutCurrentlyPressed)
        flags(true)
        precondition(starts == 1)
        flags(false)
        flags(true)
        precondition(starts == 2)
        withExtendedLifetime((transitions, cancellation)) {}
    }

    private static func inactiveSelectionNotificationsCannotCancelSpeech() async {
        let selection = CircleSelectController()
        let output = FakeSpeechPlayback()
        let speaker = CookieSpeaker(makeLocal: { _ in output }, sourceProvider: { nil })
        var cancellations = 0
        selection.onCancel = { cancellations += 1; speaker.stopPlayback() }
        let speech = Task { await speaker.speakText("Keep speaking after the talk keys are released") }
        await waitUntil { output.finishes == 1 }
        output.onStarted?()

        // macOS reports an intentional tap disable asynchronously after key-up.
        // Those notifications belong to the finished selection, not the reply.
        selection.cancel()
        let event = CGEvent(source: nil)!
        for eventType in [CGEventType.tapDisabledByUserInput, .tapDisabledByTimeout] {
            for _ in 0..<3 {
                precondition(!selection.handle(type: eventType, event: event))
            }
        }
        try? await Task.sleep(for: .milliseconds(30))
        precondition(cancellations == 0 && speaker.isPlaying && output.stops == 0,
                     "An inactive selection cancelled the voice interaction")
        output.onFinished?()
        await speech.value
        selection.tearDown()
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Voice test did not reach the expected state")
    }
}

@MainActor
private final class FakeSpeechPlayback: CookieSpeechPlayback {
    var onStarted: (() -> Void)?
    var onProgress: ((_ spokenOffset: Int) -> Void)?
    var onFinished: (() -> Void)?
    var onFailed: ((_ resumeFrom: Int) -> Void)?
    var words = ""
    var flushes: [Bool] = []
    var asides: [String] = []
    var opens = 0
    var finishes = 0
    var stops = 0
    func open() { opens += 1 }
    func speakAside(_ words: String) { asides.append(words) }
    func speak(_ words: String, flush: Bool) { self.words += words; flushes.append(flush) }
    func finish() { finishes += 1 }
    func stop() { stops += 1 }
}

private actor SuspendedCapture {
    private var continuation: CheckedContinuation<Int, Never>?
    private var finished = false
    func wait() async -> Int {
        if finished { return 1 }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        finished = true
        continuation?.resume(returning: 1)
        continuation = nil
    }
}
