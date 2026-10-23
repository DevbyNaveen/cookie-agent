//
//  CookieSpeaker.swift
//  Cookie
//
//  Speaks Cookie's replies. With an ElevenLabs key in Settings, the reply's
//  text goes to ElevenLabs and comes back as speech; without one, the best
//  voice installed on this Mac speaks it, on this Mac.
//

import AVFoundation

@MainActor
final class CookieSpeaker {
    /// An installed voice, reduced to what choosing one needs.
    struct Candidate {
        let identifier: String
        let language: String
        /// AVSpeechSynthesisVoiceQuality: 1 default (compact), 2 enhanced, 3 premium.
        let quality: Int
    }

    /// ElevenLabs "Jessica" (playful, bright, warm): a premade voice, so it works on
    /// the free plan too; library voices need a paid plan (HTTP 402).
    static let elevenLabsVoiceID = "cgSgspJ2msm6clMCkdW9"

    enum State { case idle, preparing, speaking }
    private(set) var state: State = .idle
    private var playback: CookieSpeechPlayback?
    private var fetch: Task<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    private var activeRequestID: UUID?
    private let makePlayback: @MainActor () -> CookieSpeechPlayback
    private let keyProvider: () -> String?
    private let fetchAudio: (String, String) async throws -> Data

    init(makePlayback: @escaping @MainActor () -> CookieSpeechPlayback = { NativeCookieSpeechPlayback() },
         keyProvider: @escaping () -> String? = { CookieModelSettings.value(CookieModelSettings.elevenLabsField) },
         fetchAudio: @escaping (String, String) async throws -> Data = { try await CookieSpeaker.elevenLabs($0, key: $1) }) {
        self.makePlayback = makePlayback
        self.keyProvider = keyProvider
        self.fetchAudio = fetchAudio
    }

    /// The best enhanced or premium voice for `language` (same language family
    /// counts), nil when only compact voices exist. Siri voices are skipped:
    /// AVSpeechSynthesizer can't use them and quietly speaks the compact voice.
    static func best(_ voices: [Candidate], language: String) -> String? {
        let family = language.split(separator: "-").first.map(String.init) ?? language
        return voices
            .filter { $0.quality > 1 && !$0.identifier.contains(".siri.") && $0.language.hasPrefix(family) }
            .max { ($0.quality, $0.language == language ? 1 : 0) < ($1.quality, $1.language == language ? 1 : 0) }?
            .identifier
    }

    /// Returns only when playback finishes or is cancelled, including the audio download.
    func speakText(_ text: String, onPlaybackProgress: @escaping (Double) -> Void = { _ in },
                   onPlaybackStarted: @escaping () -> Void = {}) async {
        stopPlayback()
        guard !Task.isCancelled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let requestID = UUID()
        activeRequestID = requestID
        state = .preparing
        let output = makePlayback()
        playback = output
        output.onStarted = { [weak self] in
            guard let self, self.activeRequestID == requestID else { return }
            self.state = .speaking
            onPlaybackStarted()
        }
        output.onProgress = { [weak self] progress in
            guard let self, self.activeRequestID == requestID, self.state == .speaking,
                  progress.isFinite else { return }
            onPlaybackProgress(min(1, max(0, progress)))
        }
        output.onFinished = { [weak self] in
            guard self?.activeRequestID == requestID else { return }
            self?.stopPlayback()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion = continuation
                fetch = Task {
                    if let key = keyProvider() {
                        do {
                            let audio = try await fetchAudio(text, key)
                            try Task.checkCancellation()
                            guard activeRequestID == requestID else { return }
                            try output.playAudio(audio)
                            return
                        } catch {
                            // URLSession cancellation is a URLError, not always CancellationError.
                            guard !Task.isCancelled, activeRequestID == requestID else { return }
                            print("⚠️ Cloud speech unavailable; using this Mac's voice")
                        }
                    }
                    guard !Task.isCancelled, activeRequestID == requestID else { return }
                    output.speakLocally(text)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.activeRequestID == requestID else { return }
                self?.stopPlayback()
            }
        }
    }

    var isPlaying: Bool { state == .speaking }
    var isActive: Bool { state != .idle }

    func stopPlayback() {
        activeRequestID = nil
        state = .idle
        fetch?.cancel()
        fetch = nil
        let output = playback
        playback = nil
        output?.onStarted = nil
        output?.onProgress = nil
        output?.onFinished = nil
        output?.stop()
        let waiting = completion
        completion = nil
        waiting?.resume()
    }

    private static func elevenLabs(_ text: String, key: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(elevenLabsVoiceID)?output_format=mp3_44100_128")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "model_id": "eleven_flash_v2_5"])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw NSError(domain: "ElevenLabs", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(String(decoding: data.prefix(200), as: UTF8.self))"])
        }
        return data
    }
}


@MainActor
protocol CookieSpeechPlayback: AnyObject {
    var onStarted: (() -> Void)? { get set }
    var onProgress: ((Double) -> Void)? { get set }
    var onFinished: (() -> Void)? { get set }
    func speakLocally(_ text: String)
    func playAudio(_ data: Data) throws
    func stop()
}

/// A fresh output for each reply keeps late delegates from completing a newer reply.
@MainActor
private final class NativeCookieSpeechPlayback: NSObject, CookieSpeechPlayback, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    var onStarted: (() -> Void)?
    var onProgress: ((Double) -> Void)?
    var onFinished: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var utterance: AVSpeechUtterance?
    private var progressTask: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speakLocally(_ text: String) {
        let language = Locale.preferredLanguages.first ?? "en-US"
        let voices = AVSpeechSynthesisVoice.speechVoices().map {
            CookieSpeaker.Candidate(identifier: $0.identifier, language: $0.language, quality: $0.quality.rawValue)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = CookieSpeaker.best(voices, language: language).flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AVSpeechSynthesisVoice(language: language)
        self.utterance = utterance
        synthesizer.speak(utterance)
    }

    func playAudio(_ data: Data) throws {
        let player = try AVAudioPlayer(data: data)
        self.player = player
        player.delegate = self
        guard player.play() else { throw NSError(domain: "CookieSpeech", code: 1) }
        onStarted?()
        // Cloud audio has no word timestamps. Follow its playback position instead
        // of a free-running typewriter, so stopping audio also stops the reveal.
        progressTask = Task { @MainActor [weak self, weak player] in
            while !Task.isCancelled {
                guard let self, let player, self.player === player, player.isPlaying else { return }
                if player.duration > 0 { self.onProgress?(player.currentTime / player.duration) }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }

    func stop() {
        progressTask?.cancel()
        progressTask = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        utterance = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard self?.utterance === utterance else { return }
            self?.onStarted?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                      utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard self?.utterance === utterance, !utterance.speechString.isEmpty else { return }
            self?.onProgress?(Double(NSMaxRange(characterRange)) / Double(utterance.speechString.utf16.count))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard self?.utterance === utterance else { return }
            self?.onFinished?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard self?.utterance === utterance else { return }
            self?.onFinished?()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }
            self?.onFinished?()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }
            self?.onFinished?()
        }
    }
}
