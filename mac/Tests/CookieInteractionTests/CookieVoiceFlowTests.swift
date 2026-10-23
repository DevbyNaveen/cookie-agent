import AppKit
import Combine

@MainActor
enum CookieVoiceFlowTests {
    static func run() async {
        await playbackOwnsTheSpeakingLifetime()
        await cancelledDownloadNeverStartsFallbackSpeech()
        await oldCallbacksCannotFinishANewReply()
        await failedCloudSpeechUsesLocalPlaybackUntilItFinishes()
        await cancellingACaptureDoesNotWaitForItsDeadline()
        await inactiveSelectionNotificationsCannotCancelSpeech()
        escapeRequiresAReleaseBeforeListeningAgain()
        print("7 voice flow checks passed.")
    }

    private static func playbackOwnsTheSpeakingLifetime() async {
        let output = FakeSpeechPlayback()
        let speaker = CookieSpeaker(makePlayback: { output }, keyProvider: { nil })
        var finished = false
        var started = false
        var progress = 0.0
        let task = Task {
            await speaker.speakText("A reply", onPlaybackProgress: { progress = $0 }) { started = true }
            finished = true
        }
        await waitUntil { output.localStarts == 1 }
        precondition(speaker.state == .preparing && !finished && !started)
        output.onProgress?(1, 0.4)
        precondition(progress == 0, "Words must not animate before audio starts")
        output.onStarted?()
        precondition(speaker.isPlaying && started && !finished)
        output.onProgress?(1, 0.4)
        precondition(progress == 0.4)
        let staleProgress = output.onProgress
        try? await Task.sleep(for: .milliseconds(30))
        precondition(!finished && speaker.state == .speaking)
        output.onFinished?()
        await task.value
        precondition(finished && speaker.state == .idle)
        staleProgress?(2, 0.9)
        precondition(progress == 0.4, "Late progress must not change completed speech")
    }

    private static func cancelledDownloadNeverStartsFallbackSpeech() async {
        let output = FakeSpeechPlayback()
        var pending: CheckedContinuation<CookieSpeechAudio, Error>?
        let speaker = CookieSpeaker(makePlayback: { output }, keyProvider: { "test-only" }, fetchAudio: { _, _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        })
        let task = Task { await speaker.speakText("Cancelled") }
        await waitUntil { pending != nil }
        task.cancel()
        await task.value
        precondition(!speaker.isActive && output.stops == 1)
        pending?.resume(throwing: URLError(.cancelled))
        try? await Task.sleep(for: .milliseconds(20))
        precondition(output.localStarts == 0 && output.audioStarts == 0)
    }

    private static func oldCallbacksCannotFinishANewReply() async {
        let first = FakeSpeechPlayback(), second = FakeSpeechPlayback()
        var count = 0
        let speaker = CookieSpeaker(makePlayback: { count += 1; return count == 1 ? first : second }, keyProvider: { nil })
        let firstTask = Task { await speaker.speakText("First") }
        await waitUntil { first.localStarts == 1 }
        let staleStart = first.onStarted, staleFinish = first.onFinished
        let secondTask = Task { await speaker.speakText("Second") }
        await waitUntil { second.localStarts == 1 }
        await firstTask.value
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
        let output = FakeSpeechPlayback()
        let speaker = CookieSpeaker(makePlayback: { output }, keyProvider: { "test-only" }, fetchAudio: { _, _ in
            throw URLError(.notConnectedToInternet)
        })
        let task = Task { await speaker.speakText("Local fallback") }
        await waitUntil { output.localStarts == 1 }
        precondition(speaker.state == .preparing)
        output.onStarted?()
        precondition(speaker.isPlaying)
        output.onFinished?()
        await task.value
        precondition(!speaker.isActive)
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
        let speaker = CookieSpeaker(makePlayback: { output }, keyProvider: { nil })
        var cancellations = 0
        selection.onCancel = { cancellations += 1; speaker.stopPlayback() }
        let speech = Task { await speaker.speakText("Keep speaking after the talk keys are released") }
        await waitUntil { output.localStarts == 1 }
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
    var onProgress: ((_ spokenOffset: Int, _ progress: Double) -> Void)?
    var onFinished: (() -> Void)?
    var localStarts = 0
    var audioStarts = 0
    var stops = 0
    func speakLocally(_ text: String) { localStarts += 1 }
    func playAudio(_ audio: CookieSpeechAudio, text: String) throws { audioStarts += 1; onStarted?() }
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
