//
//  AppleSpeechTranscriptionProvider.swift
//  EnkeonVoiceKit (from Cookie, cookie-harness 8ffefde)
//
//  On-device transcription with Apple's Speech framework. On macOS 26 and later
//  it is SpeechAnalyzer in the enkeon-sense helper (volatile results while the
//  person talks, finalized when the key comes up, in ~0.15 s); on macOS 15, a
//  language without an installed model, or no helper, SFSpeechRecognizer on
//  this Mac. Either way the voice never leaves the Mac.
//

import AVFoundation
import Foundation
import Speech

struct AppleSpeechTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class AppleSpeechTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Apple Speech"
    let requiresSpeechRecognitionPermission = true
    let isConfigured = true
    let unavailableExplanation: String? = nil

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        if let session = await SpeechHelperTranscriptionSession.start(onTranscriptUpdate: onTranscriptUpdate,
                                                                    onFinalTranscriptReady: onFinalTranscriptReady,
                                                                    onError: onError) {
            return session
        }
        guard let speechRecognizer = Self.makeBestAvailableSpeechRecognizer() else {
            throw AppleSpeechTranscriptionProviderError(message: "dictation is not available on this mac.")
        }

        return try AppleSpeechTranscriptionSession(
            speechRecognizer: speechRecognizer,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }

    private static func makeBestAvailableSpeechRecognizer() -> SFSpeechRecognizer? {
        let preferredLocales = [
            Locale.autoupdatingCurrent,
            Locale(identifier: "en-US")
        ]

        for preferredLocale in preferredLocales {
            if let speechRecognizer = SFSpeechRecognizer(locale: preferredLocale) {
                return speechRecognizer
            }
        }

        return SFSpeechRecognizer()
    }
}

private final class AppleSpeechTranscriptionSession: NSObject, BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 1.8

    private let recognitionRequest: SFSpeechAudioBufferRecognitionRequest
    private var recognitionTask: SFSpeechRecognitionTask?
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private var latestRecognizedText = ""
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false

    init(
        speechRecognizer: SFSpeechRecognizer,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        self.recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        super.init()

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
        recognitionRequest.addsPunctuation = true
        recognitionRequest.contextualStrings = Array(keyterms.prefix(100))

        // Your voice never leaves the Mac: no on-device model, no listening.
        guard speechRecognizer.supportsOnDeviceRecognition else {
            throw NSError(domain: "EnkeonSpeech", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "On-device speech isn't available for this language, so Enkeon won't send your voice anywhere. Type instead.",
            ])
        }
        recognitionRequest.requiresOnDeviceRecognition = true

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            self?.handleRecognitionEvent(result: result, error: error)
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard !hasRequestedFinalTranscript else { return }
        recognitionRequest.append(audioBuffer)
    }

    func requestFinalTranscript() {
        guard !hasRequestedFinalTranscript else { return }
        hasRequestedFinalTranscript = true
        recognitionRequest.endAudio()
    }

    func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func handleRecognitionEvent(
        result: SFSpeechRecognitionResult?,
        error: Error?
    ) {
        if let result {
            latestRecognizedText = result.bestTranscription.formattedString
            onTranscriptUpdate(latestRecognizedText)

            if result.isFinal {
                deliverFinalTranscriptIfNeeded(latestRecognizedText)
                return
            }
        }

        guard let error else { return }

        // An interrupted recognition result is not a confirmed transcript.
        onError(error)
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        cancel()
    }
}

/// SpeechAnalyzer in the enkeon-sense helper. Cookie keeps the microphone: each buffer is turned
/// into 16 kHz mono 16-bit samples here and sent; the helper answers with the text so far as the
/// person talks, and the final text after the key comes up.
final class SpeechHelperTranscriptionSession: BuddyStreamingTranscriptionSession {
    /// Wait for a confirmed final; never promote a partial when the helper times out.
    var finalTranscriptFallbackDelaySeconds: TimeInterval { engine == "parakeet" ? 12 : 4 }

    private let helper: SpeechHelper
    private let id: String
    private let engine: String
    private let converter = BuddyPCM16AudioConverter(targetSampleRate: 16_000)
    private let lock = NSLock()
    private let audioQueue = DispatchQueue(label: "com.enkeon.speech.audio", qos: .userInitiated)
    private var conversionFailed = false
    private var finishing = false
    private var delivered = false

    private init(id: String, engine: String, helper: SpeechHelper) {
        self.helper = helper
        self.id = id
        self.engine = engine
    }

    /// A session, or nil when the helper can't transcribe here (no helper, macOS 15, no model for
    /// the language yet — it is then being installed for next time).
    static func start(engine: String = "speech", helper: SpeechHelper = .shared, onTranscriptUpdate: @escaping (String) -> Void,
                      onFinalTranscriptReady: @escaping (String) -> Void,
                      onError: @escaping (Error) -> Void) async -> SpeechHelperTranscriptionSession? {
        let sense = helper
        guard let hello = try? await sense.request(["op": "hello"], timeout: 5), hello[engine] as? Bool == true else { return nil }
        let session = SpeechHelperTranscriptionSession(id: sense.nextID(), engine: engine, helper: helper)
        sense.listen(session.id) { [weak session] event in
            guard let session else { return }
            switch event["event"] as? String {
            case "volatile":
                if let text = event["text"] as? String { onTranscriptUpdate(text) }
            case "final":
                print("🎙️ \(engine) \(session.id): final arrived (\((event["text"] as? String ?? "").count) characters) at \(Date().timeIntervalSince1970)")
                guard session.markDelivered() else { return print("🎙️ \(engine) \(session.id): final dropped, session already closed") }
                sense.stopListening(session.id)
                onFinalTranscriptReady(event["text"] as? String ?? "")
            default:
                guard session.markDelivered() else { return }
                sense.stopListening(session.id)
                onError(AppleSpeechTranscriptionProviderError(message: event["message"] as? String ?? "transcription stopped"))
            }
        }
        do {
            _ = try await sense.request(["op": "\(engine).start", "id": session.id, "locale": Locale.current.identifier], timeout: 4)
            return session
        } catch {
            sense.stopListening(session.id)
            sense.post(["op": "\(engine).cancel", "id": session.id])
            return nil
        }
    }

    private func markDelivered() -> Bool {
        lock.withLock {
            guard !delivered else { return false }
            delivered = true
            return true
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !finishing, !delivered else { return }
            // The engine reuses tap buffers. Own the samples before leaving its callback,
            // then do resampling and pipe writes off the real-time audio thread.
            guard let copy = audioBuffer.dictationCopy() else { conversionFailed = true; return }
            audioQueue.async { [self] in
                guard !lock.withLock({ delivered }) else { return }
                guard let samples = converter.convertToPCM16Data(from: copy) else {
                    lock.withLock { conversionFailed = true }
                    return
                }
                guard !samples.isEmpty else { return }
                helper.post(["op": "\(engine).audio", "id": id], payload: samples)
            }
        }
    }

    func requestFinalTranscript() {
        lock.withLock {
            guard !finishing, !delivered else { return }
            finishing = true
            // Enqueued under the same lock as audio: finish cannot overtake the last buffer.
            audioQueue.async { [self] in
                guard !lock.withLock({ delivered }) else { return }
                if lock.withLock({ conversionFailed }) {
                    // A conversion failure must not become an apparently successful partial.
                    helper.post(["op": "\(engine).cancel", "id": id])
                    helper.deliverAudioFailure(id: id)
                } else {
                    helper.post(["op": "\(engine).finish", "id": id])
                }
            }
        }
    }

    func cancel() {
        lock.withLock {
            finishing = true; delivered = true
            helper.stopListening(id)
            audioQueue.async { [self] in
                helper.post(["op": "\(engine).cancel", "id": id])
            }
        }
    }
}
