import Foundation

final class ParakeetTranscriptionProvider: BuddyTranscriptionProvider {
    private let helper: SpeechHelper
    init(helper: SpeechHelper = .shared) { self.helper = helper }

    let displayName = "Parakeet · on device"
    let requiresSpeechRecognitionPermission = false
    var isConfigured: Bool { helper.isBundled }
    var unavailableExplanation: String? { isConfigured ? nil : "The speech helper is missing. Rebuild or reinstall Enkeon." }

    func startStreamingSession(keyterms: [String], onTranscriptUpdate: @escaping (String) -> Void,
                               onFinalTranscriptReady: @escaping (String) -> Void,
                               onError: @escaping (Error) -> Void) async throws -> any BuddyStreamingTranscriptionSession {
        guard let session = await SpeechHelperTranscriptionSession.start(engine: "parakeet", helper: helper, onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady, onError: onError) else {
            throw AppleSpeechTranscriptionProviderError(message: "Parakeet is not ready. Check Speech in Settings. No other model was used.")
        }
        return session
    }
}
