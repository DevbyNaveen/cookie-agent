//
//  BuddyTranscriptionProvider.swift
//  EnkeonVoiceKit (from Cookie, cookie-harness 8ffefde)
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    var requiresConfirmedFinal: Bool { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

extension BuddyStreamingTranscriptionSession {
    var requiresConfirmedFinal: Bool { true }
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {
    private enum PreferredProvider: String {
        case openAI = "openai"
        case appleSpeech = "apple"
        case parakeet = "parakeet"
    }

    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    /// Apple Speech, on this Mac, unless OpenAI was explicitly chosen and has a key. Unlike Cookie,
    /// a key being present is not consent: voice leaves the Mac only when the person picked it.
    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "VoiceTranscriptionProvider")?
            .lowercased()
        let preferredProvider = preferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))
        if preferredProvider == .parakeet { return ParakeetTranscriptionProvider() }
        if preferredProvider == .openAI {
            return OpenAIAudioTranscriptionProvider()
        }
        return AppleSpeechTranscriptionProvider()
    }
}
