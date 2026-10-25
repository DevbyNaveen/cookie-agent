//
//  AppleSpeechTranscriptionProvider.swift
//  Cookie
//
//  On-device transcription with Apple's Speech framework. On macOS 26 and later
//  it is SpeechAnalyzer in the cookie-sense helper (volatile results while the
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
        if let session = await CookieSenseTranscriptionSession.start(onTranscriptUpdate: onTranscriptUpdate,
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
            throw NSError(domain: "CookieSpeech", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "On-device speech isn't available for this language, so Cookie won't send your voice anywhere. Type instead.",
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

        if hasRequestedFinalTranscript && !latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deliverFinalTranscriptIfNeeded(latestRecognizedText)
        } else {
            onError(error)
        }
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

/// SpeechAnalyzer in the cookie-sense helper. Cookie keeps the microphone: each buffer is turned
/// into 16 kHz mono 16-bit samples here and sent; the helper answers with the text so far as the
/// person talks, and the final text after the key comes up.
final class CookieSenseTranscriptionSession: BuddyStreamingTranscriptionSession {
    /// The helper finalizes in ~0.15 s (measured); if it says nothing for a second the dictation
    /// manager takes the last text it had.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 1.0

    private let id: String
    private let converter = BuddyPCM16AudioConverter(targetSampleRate: 16_000)
    private let lock = NSLock()
    private var finishing = false
    private var delivered = false

    private init(id: String) {
        self.id = id
    }

    /// A session, or nil when the helper can't transcribe here (no helper, macOS 15, no model for
    /// the language yet — it is then being installed for next time).
    static func start(onTranscriptUpdate: @escaping (String) -> Void,
                      onFinalTranscriptReady: @escaping (String) -> Void,
                      onError: @escaping (Error) -> Void) async -> CookieSenseTranscriptionSession? {
        let sense = CookieSense.shared
        guard let hello = await sense.hello(), hello["speech"] as? Bool == true else { return nil }
        let session = CookieSenseTranscriptionSession(id: sense.nextID())
        sense.listen(session.id) { [weak session] event in
            guard let session else { return }
            switch event["event"] as? String {
            case "volatile":
                if let text = event["text"] as? String { onTranscriptUpdate(text) }
            case "final":
                guard session.markDelivered() else { return }
                sense.stopListening(session.id)
                onFinalTranscriptReady(event["text"] as? String ?? "")
            default:
                guard session.markDelivered() else { return }
                sense.stopListening(session.id)
                onError(AppleSpeechTranscriptionProviderError(message: event["message"] as? String ?? "transcription stopped"))
            }
        }
        do {
            _ = try await sense.request(["op": "speech.start", "id": session.id, "locale": Locale.current.identifier], timeout: 4)
            return session
        } catch {
            sense.stopListening(session.id)
            print("🎙️ SpeechAnalyzer unavailable, using SFSpeechRecognizer: \(error.localizedDescription)")
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
        guard !lock.withLock({ finishing }), let samples = converter.convertToPCM16Data(from: audioBuffer), !samples.isEmpty else { return }
        CookieSense.shared.post(["op": "speech.audio", "id": id], payload: samples)
    }

    func requestFinalTranscript() {
        guard lock.withLock({ () -> Bool in defer { finishing = true }; return !finishing }) else { return }
        CookieSense.shared.post(["op": "speech.finish", "id": id])
    }

    func cancel() {
        lock.withLock { finishing = true; delivered = true }
        CookieSense.shared.stopListening(id)
        CookieSense.shared.post(["op": "speech.cancel", "id": id])
    }
}
