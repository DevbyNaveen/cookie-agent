//
//  BuddyTranscriptionProvider.swift
//  EnkeonVoiceKit (from Cookie, cookie-harness 8ffefde)
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

public protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    var requiresConfirmedFinal: Bool { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

extension BuddyStreamingTranscriptionSession {
    public var requiresConfirmedFinal: Bool { true }
}

public protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    /// Live words while the person speaks (Cookie's conversation mode ends turns on them).
    var supportsPartialTranscripts: Bool { get }
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

extension BuddyTranscriptionProvider {
    public var supportsPartialTranscripts: Bool { false }
}

public enum BuddyTranscriptionProviderFactory {
    private enum PreferredProvider: String {
        case openAI = "openai"
        case appleSpeech = "apple"
        case parakeet = "parakeet"
    }

    public static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    /// Settings → Voice → Speech engine ("apple", "parakeet", "openai"). Read at launch.
    public static let speechProviderKey = "enkeon.speech.provider"

    /// Settings' choice, else the bundle's `VoiceTranscriptionProvider`, else Apple. Unknown means Apple.
    static func preferredName() -> String {
        preferredName(defaults: .standard, bundleValue: AppBundleConfiguration.stringValue(forKey: "VoiceTranscriptionProvider"))
    }
    public static func preferredName(defaults: UserDefaults, bundleValue: String?) -> String {
        let chosen = (defaults.string(forKey: speechProviderKey) ?? bundleValue)?.lowercased()
        return chosen.flatMap(PreferredProvider.init(rawValue:))?.rawValue ?? PreferredProvider.appleSpeech.rawValue
    }

    /// Apple Speech, on this Mac, unless OpenAI was explicitly chosen and has a key. Unlike Cookie,
    /// a key being present is not consent: voice leaves the Mac only when the person picked it.
    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        let preferredProvider = PreferredProvider(rawValue: preferredName())
        if preferredProvider == .parakeet { return ParakeetTranscriptionProvider() }
        if preferredProvider == .openAI {
            return OpenAIAudioTranscriptionProvider()
        }
        return AppleSpeechTranscriptionProvider()
    }
}
