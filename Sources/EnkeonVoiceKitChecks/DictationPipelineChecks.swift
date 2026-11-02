import AVFoundation
import Foundation
@testable import EnkeonVoiceKit

private final class FixtureAudioInput: DictationAudioInput {
    var snapshot = DictationAudioSnapshot(frames: 1600, sumSquares: 0.16, samples: 1600, peak: 0.01)
    var failStart = false
    var buffers: [AVAudioPCMBuffer] = []
    var stops = 0
    func start(receive: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        if failStart { throw AppleSpeechTranscriptionProviderError(message: "fixture start failure") }
        buffers.forEach(receive)
    }
    func stop() { stops += 1 }
}

/// Optional real-helper check. Input is a generated WAV, never a live microphone.
@MainActor
func checkLiveParakeetPipeline(wav: URL, helperURL: URL) async throws {
    let helper = SpeechHelper(helperURL: helperURL)
    defer { helper.stopForTesting() }
    let prepared = try await helper.request(["op": "parakeet.prepare"], timeout: 120)
    print("Live pipeline model: \(prepared["model"] ?? "unknown")")
    let source = try AVAudioFile(forReading: wav)
    let original = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length))!
    try source.read(into: original)
    let provider = ParakeetTranscriptionProvider(helper: helper)
    for gain: Float in [1, 0.1, 0.01, 0] {
        let audio = FixtureAudioInput()
        let count = Int(original.frameLength)
        var energy: Double = 0
        var peak: Float = 0
        for offset in stride(from: 0, to: count, by: 1024) {
            let frames = min(1024, count - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: original.format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames {
                let value = original.floatChannelData![0][offset + i] * gain
                buffer.floatChannelData![0][i] = value
                energy += Double(value) * Double(value)
                peak = max(peak, abs(value))
            }
            audio.buffers.append(buffer)
        }
        audio.snapshot = DictationAudioSnapshot(frames: count, sumSquares: energy, samples: count, peak: peak)
        let manager = BuddyDictationManager(provider: provider, audioInput: audio, permissionCheck: { true })
        var final: String?
        // Exercises the previously broken button path through conversion, IPC, real ASR and final delivery.
        await manager.startPersistentDictationFromMicrophoneButton(currentDraftText: "",
            updateDraftText: { _ in }, submitDraftText: { final = $0 })
        precondition(manager.isActivelyRecordingAudio, manager.lastErrorMessage ?? "not recording")
        let start = ContinuousClock.now
        manager.stopPersistentDictationFromMicrophoneButton()
        while manager.isDictationInProgress, start.duration(to: .now) < .seconds(15) {
            try await Task.sleep(for: .milliseconds(25))
        }
        let elapsed = start.duration(to: .now)
        if gain > 0 {
            let missing = ["send", "pricing", "maria", "friday"].filter { !(final?.lowercased().contains($0) ?? false) }
            precondition(missing.isEmpty, "gain \(gain): missing \(missing), error \(manager.lastErrorMessage ?? "none")")
        } else {
            precondition(final == nil && manager.lastErrorMessage?.contains("silent") == true,
                         "silence must produce a clear empty result, never invented words")
        }
        print("Live Parakeet pipeline: gain=\(gain), RMS=\(audio.snapshot.rms), finalCharacters=\(final?.count ?? 0), finish=\(elapsed), passed")
        try await Task.sleep(for: .milliseconds(50))
    }
}

private final class FixtureSpeechSession: BuddyStreamingTranscriptionSession {
    var finalTranscriptFallbackDelaySeconds: TimeInterval = 0.06
    var cancelled = false
    var finishes = 0
    var events: [String] = []
    var final: (String) -> Void = { _ in }
    var partial: (String) -> Void = { _ in }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) { events.append("audio:\(audioBuffer.frameLength)") }
    func requestFinalTranscript() { finishes += 1; events.append("finish") }
    func cancel() { cancelled = true }
}

private final class FixtureSpeechProvider: BuddyTranscriptionProvider {
    let displayName = "Fixture"
    let requiresSpeechRecognitionPermission = false
    let isConfigured = true
    let unavailableExplanation: String? = nil
    var sessions: [FixtureSpeechSession] = []
    var startDelay: Duration = .zero
    func startStreamingSession(keyterms: [String], onTranscriptUpdate: @escaping (String) -> Void,
                               onFinalTranscriptReady: @escaping (String) -> Void,
                               onError: @escaping (Error) -> Void) async throws -> any BuddyStreamingTranscriptionSession {
        if startDelay > .zero { try await Task.sleep(for: startDelay) }
        let session = FixtureSpeechSession()
        session.partial = onTranscriptUpdate
        session.final = onFinalTranscriptReady
        sessions.append(session)
        return session
    }
}

@MainActor
func checkDictationPipeline() async throws {
    var expired = false
    let cancelledTimer = DictationController.finalTranscriptWatchdog(seconds: 0.01) { expired = true }
    cancelledTimer.cancel()
    await cancelledTimer.value
    precondition(!expired, "a final transcript cancelling the timer must not trigger No speech heard")
    let realTimer = DictationController.finalTranscriptWatchdog(seconds: 0.01) { expired = true }
    await realTimer.value
    precondition(expired)

    let delayedProvider = FixtureSpeechProvider()
    let delayed = BuddyDictationManager(provider: delayedProvider, audioInput: FixtureAudioInput(), permissionCheck: {
        try? await Task.sleep(for: .milliseconds(30))
        return true
    })
    let preparing = Task { @MainActor in
        await delayed.startPersistentDictationFromMicrophoneButton(currentDraftText: "",
            updateDraftText: { _ in }, submitDraftText: { _ in preconditionFailure("cancelled startup submitted") })
    }
    try await Task.sleep(for: .milliseconds(5))
    delayed.stopPersistentDictationFromMicrophoneButton()
    await preparing.value
    precondition(!delayed.isDictationInProgress && delayedProvider.sessions.isEmpty)
    precondition(delayed.lastErrorMessage?.contains("wasn't ready") == true)

    // First audio must survive a slow recognizer, even if the key is released before it opens.
    let slowProvider = FixtureSpeechProvider()
    slowProvider.startDelay = .milliseconds(150)
    let earlyAudio = FixtureAudioInput()
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let earlyBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    earlyBuffer.frameLength = 1024
    earlyBuffer.floatChannelData![0].initialize(repeating: 0.01, count: 1024)
    earlyAudio.buffers = [earlyBuffer, earlyBuffer]
    let earlyManager = BuddyDictationManager(provider: slowProvider, audioInput: earlyAudio, permissionCheck: { true })
    var earlyResult: String?
    let opening = Task { @MainActor in
        await earlyManager.startPushToTalkFromKeyboardShortcut(currentDraftText: "",
            updateDraftText: { _ in }, submitDraftText: { earlyResult = $0 })
    }
    try await Task.sleep(for: .milliseconds(30))
    precondition(earlyManager.isMicrophoneReady && slowProvider.sessions.isEmpty,
                 "capture must start before the delayed recognizer opens")
    earlyManager.stopPushToTalkFromKeyboardShortcut()
    await opening.value
    let earlySession = slowProvider.sessions.last!
    precondition(earlySession.events == ["audio:1024", "audio:1024", "finish"],
                 "release during recognizer startup must deliver every buffered frame before finish")
    earlySession.final("First words preserved.")
    try await Task.sleep(for: .milliseconds(20))
    precondition(earlyResult == "First words preserved." && !earlyManager.isDictationInProgress)

    let cancelledAudio = PendingDictationAudio()
    cancelledAudio.append(earlyBuffer)
    cancelledAudio.cancel()
    do { try cancelledAudio.attach(FixtureSpeechSession()); preconditionFailure("cancelled audio attached") }
    catch is CancellationError {} catch { preconditionFailure("wrong cancellation error") }

    let boundedAudio = PendingDictationAudio()
    for _ in 0..<100 { boundedAudio.append(earlyBuffer) }
    let rejectedSession = FixtureSpeechSession()
    do { try boundedAudio.attach(rejectedSession); preconditionFailure("overflow silently truncated the beginning") }
    catch { precondition(rejectedSession.events.isEmpty) }

    let provider = FixtureSpeechProvider()
    let audio = FixtureAudioInput()
    let manager = BuddyDictationManager(provider: provider, audioInput: audio, permissionCheck: { true })
    var submitted: [String] = []
    var drafts: [String] = []
    // Button recording must submit its confirmed final even when no partial ever arrived.
    await manager.startPersistentDictationFromMicrophoneButton(currentDraftText: "",
        updateDraftText: { drafts.append($0) }, submitDraftText: { submitted.append($0) })
    manager.stopPersistentDictationFromMicrophoneButton()
    let first = provider.sessions.last!
    first.final("Quiet speech arrived.")
    first.partial("stale partial")
    try await Task.sleep(for: .milliseconds(20))
    precondition(submitted == ["Quiet speech arrived."] && !manager.isDictationInProgress)
    precondition(!drafts.contains("stale partial"))
    first.final("duplicate")
    // Start another session before the first one's deadline: stale callbacks cannot affect it.
    await manager.startPushToTalkFromKeyboardShortcut(currentDraftText: "",
        updateDraftText: { drafts.append($0) }, submitDraftText: { submitted.append($0) })
    try await Task.sleep(for: .milliseconds(80))
    precondition(manager.isActivelyRecordingAudio && manager.lastErrorMessage == nil)
    first.final("old recording")
    let second = provider.sessions.last!
    manager.stopPushToTalkFromKeyboardShortcut()
    second.final("Keyboard recording.")
    try await Task.sleep(for: .milliseconds(20))
    precondition(submitted == ["Quiet speech arrived.", "Keyboard recording."])

    // An empty final distinguishes failed capture from an actual empty recognition result.
    audio.snapshot = DictationAudioSnapshot()
    await manager.startPushToTalkFromKeyboardShortcut(currentDraftText: "", updateDraftText: { _ in }, submitDraftText: { submitted.append($0) })
    manager.stopPushToTalkFromKeyboardShortcut()
    provider.sessions.last!.final("")
    try await Task.sleep(for: .milliseconds(20))
    precondition(manager.lastErrorMessage?.contains("supplied no audio") == true)
    precondition(!manager.isDictationInProgress && submitted.count == 2)

    // A partial cannot be pasted when the recognizer misses its confirmed-final deadline.
    audio.snapshot.frames = 1600
    await manager.startPushToTalkFromKeyboardShortcut(currentDraftText: "", updateDraftText: { _ in }, submitDraftText: { submitted.append($0) })
    provider.sessions.last!.partial("unfinished words")
    manager.stopPushToTalkFromKeyboardShortcut()
    try await Task.sleep(for: .milliseconds(100))
    precondition(manager.lastErrorMessage?.contains("timed out") == true && submitted.count == 2)

    audio.failStart = true
    await manager.startPushToTalkFromKeyboardShortcut(currentDraftText: "", updateDraftText: { _ in }, submitDraftText: { _ in })
    precondition(provider.sessions.last!.cancelled && !manager.isDictationInProgress,
                 "microphone startup failure must release the provider for the next attempt")
    audio.failStart = false
    audio.snapshot = DictationAudioSnapshot()
    await manager.startPushToTalkFromKeyboardShortcut(currentDraftText: "", updateDraftText: { _ in }, submitDraftText: { submitted.append($0) })
    try await Task.sleep(for: .milliseconds(2150))
    precondition(!manager.isDictationInProgress && manager.lastErrorMessage?.contains("supplied no audio") == true,
                 "a running engine with no tap callbacks must not pretend it is hearing speech")
    precondition(provider.sessions.last!.cancelled && submitted.count == 2)
    precondition(DictationAudioSnapshot(frames: 10).emptyTranscriptMessage.contains("silent"))
    precondition(DictationAudioSnapshot(frames: 10, peak: 0.0001).emptyTranscriptMessage.contains("wasn't recognized"),
                 "quiet audio must not be classified as no microphone data")
    checkQuietAudioConversion()
    print("Dictation pipeline checks passed (cancellation, button, keyboard, stale events, empty input, timeout, start failure, quiet PCM)")
}

private func checkQuietAudioConversion() {
    for rate in [16_000.0, 44_100.0, 48_000.0] {
        for amplitude: Float in [0.1, 0.001] {
            let converter = BuddyPCM16AudioConverter(targetSampleRate: 16_000)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
            var pcm = Data()
            for chunk in 0..<20 {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
                buffer.frameLength = 1024
                for i in 0..<1024 { buffer.floatChannelData![0][i] = amplitude * sin(Float(2 * Double.pi * 440 * Double(chunk * 1024 + i) / rate)) }
                let copy = buffer.dictationCopy()!
                let expected = buffer.floatChannelData![0][100]
                buffer.floatChannelData![0][100] = 0
                precondition(copy.floatChannelData![0][100] == expected, "queued audio must own the tap samples")
                guard let data = converter.convertToPCM16Data(from: copy) else { preconditionFailure("PCM conversion failed") }
                pcm.append(data)
            }
            let energy = pcm.withUnsafeBytes { raw -> Double in
                (0..<pcm.count / 2).reduce(0) { total, index in
                    let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
                    return total + sample * sample
                }
            }
            let rms = sqrt(energy / Double(pcm.count / 2))
            precondition(abs(rms - Double(amplitude) / sqrt(2)) < Double(amplitude) * 0.06,
                         "resampling must preserve quiet speech levels at \(rate) Hz")
        }
    }
}
