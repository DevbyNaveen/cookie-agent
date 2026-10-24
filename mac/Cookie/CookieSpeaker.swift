//
//  CookieSpeaker.swift
//  Cookie
//
//  Speaks Cookie's replies. Signed in to Enkeon with its voice on (GET
//  /v1/cookie/session says `speech`), the reply goes to Enkeon's speech route
//  and no key of the person's is needed; else, with an ElevenLabs key in
//  Settings, straight to ElevenLabs. Either answers with the time each
//  character is heard. Without either, the best voice installed on this Mac
//  speaks it, on this Mac. Every way, `CookieSpeechClock` knows which
//  character is being spoken now.
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
    /// the free plan too; library voices need a paid plan (HTTP 402). ElevenLabs
    /// retires its default voices on 31 December 2026; Settings lists the account's own.
    static let elevenLabsVoiceID = "cgSgspJ2msm6clMCkdW9"
    /// The voice chosen in Settings (UserDefaults; a voice id is not a secret).
    static let elevenLabsVoiceKey = "cookie.elevenlabs.voice"

    /// The chosen voice id, or Jessica. Only letters and digits: it goes into the URL path.
    static var elevenLabsVoice: String {
        let chosen = (UserDefaults.standard.string(forKey: elevenLabsVoiceKey) ?? "").trimmingCharacters(in: .whitespaces)
        return isVoiceID(chosen) ? chosen : elevenLabsVoiceID
    }

    static func isVoiceID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 64 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Where speech is now. One per speaker, shared by every reply it speaks.
    let clock = CookieSpeechClock()

    enum State { case idle, preparing, speaking }
    private(set) var state: State = .idle
    private var playback: CookieSpeechPlayback?
    private var fetch: Task<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    private var activeRequestID: UUID?
    private let makePlayback: @MainActor () -> CookieSpeechPlayback
    private let sourceProvider: () async -> Source?
    private let fetchAudio: (String, Source) async throws -> CookieSpeechAudio

    /// Where a cloud voice comes from; nil = this Mac's voice.
    enum Source: Equatable {
        case enkeon
        case personal(key: String)
    }

    init(makePlayback: @escaping @MainActor () -> CookieSpeechPlayback = { NativeCookieSpeechPlayback() },
         sourceProvider: @escaping () async -> Source? = { await CookieSpeaker.source() },
         fetchAudio: @escaping (String, Source) async throws -> CookieSpeechAudio = { try await CookieSpeaker.audio($0, from: $1) }) {
        self.makePlayback = makePlayback
        self.sourceProvider = sourceProvider
        self.fetchAudio = fetchAudio
    }

    /// Enkeon's voice when signed in and it's set up there, else the person's key, else none.
    static func source() async -> Source? {
        if CookieAccount.shared.isSignedIn, await CookieAPI.shared.loadSession()?.speech == true { return .enkeon }
        return CookieModelSettings.value(CookieModelSettings.elevenLabsField).map { .personal(key: $0) }
    }

    /// The voice chosen in Settings, only when one was chosen: Enkeon then uses
    /// its own default rather than the app's.
    static var chosenVoice: String? {
        let chosen = (UserDefaults.standard.string(forKey: elevenLabsVoiceKey) ?? "").trimmingCharacters(in: .whitespaces)
        return isVoiceID(chosen) ? chosen : nil
    }

    static func audio(_ text: String, from source: Source) async throws -> CookieSpeechAudio {
        switch source {
        case .personal(let key): return try await elevenLabs(text, key: key)
        case .enkeon: return try await enkeon(text)
        }
    }

    /// Enkeon takes at most 2,000 characters a request: a longer reply is
    /// asked for in pieces split after a sentence, and the MP3s are played as
    /// one, each piece's character times moved by the length of those before.
    static let enkeonLimit = 2_000

    private static func enkeon(_ text: String) async throws -> CookieSpeechAudio {
        var audio = Data()
        var starts: [CookieSpeechAudio.CharacterStart] = []
        var elapsed = 0.0
        for (offset, piece) in pieces(text, limit: enkeonLimit) {
            let part = try decodeTimestampedSpeech(try await CookieAPI.shared.speech(piece, voice: chosenVoice))
            starts += part.characterStarts.map { .init(offset: $0.offset + offset, seconds: $0.seconds + elapsed) }
            elapsed += (try? AVAudioPlayer(data: part.data).duration) ?? 0
            audio.append(part.data)
        }
        return CookieSpeechAudio(data: audio, characterStarts: starts)
    }

    /// `text` in pieces of at most `limit` UTF-16 units, cut after a sentence
    /// (else a space) where one is near; each with its UTF-16 offset.
    static func pieces(_ text: String, limit: Int) -> [(Int, String)] {
        var out: [(Int, String)] = []
        var rest = Substring(text)
        var offset = 0
        while rest.utf16.count > limit {
            var units = 0
            let head = String(rest.prefix { units += $0.utf16.count; return units <= limit })
            let cut = head.lastIndex(where: { ".!?\n".contains($0) }).map { head.index(after: $0) }
                ?? head.lastIndex(of: " ").map { head.index(after: $0) } ?? head.endIndex
            let piece = String(head[..<cut])
            out.append((offset, piece))
            offset += piece.utf16.count
            rest = rest.dropFirst(piece.count)
        }
        if !rest.isEmpty { out.append((offset, String(rest))) }
        return out
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
    /// `clock` starts on `text` just before `onPlaybackStarted`; progress is the clock's.
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
            self.clock.begin(text: text)
            onPlaybackStarted()
        }
        output.onProgress = { [weak self] spokenOffset, progress in
            guard let self, self.activeRequestID == requestID, self.state == .speaking,
                  progress.isFinite else { return }
            self.clock.advance(toOffset: spokenOffset, progress: progress)
            onPlaybackProgress(self.clock.progress)
        }
        output.onFinished = { [weak self] in
            guard let self, self.activeRequestID == requestID else { return }
            // Heard to the end: work scheduled past the last reported character runs now.
            self.clock.finish()
            self.stopPlayback()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion = continuation
                fetch = Task {
                    if let source = await sourceProvider() {
                        do {
                            let audio = try await fetchAudio(text, source)
                            try Task.checkCancellation()
                            guard activeRequestID == requestID else { return }
                            try output.playAudio(audio, text: text)
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
        clock.stop()
        let waiting = completion
        completion = nil
        waiting?.resume()
    }

    /// ElevenLabs text to speech with timestamps: the audio and, per character of
    /// `text`, when it starts (https://elevenlabs.io/docs/api-reference/text-to-speech/convert-with-timestamps).
    // ponytail: the documented streaming variant (/stream/with-timestamps) doesn't document its chunk
    // framing or whether chunk times are cumulative; switch when it does, for faster first audio.
    private static func elevenLabs(_ text: String, key: String) async throws -> CookieSpeechAudio {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(elevenLabsVoice)/with-timestamps?output_format=mp3_44100_128")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "model_id": "eleven_flash_v2_5"])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw NSError(domain: "ElevenLabs", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(String(decoding: data.prefix(200), as: UTF8.self))"])
        }
        return try decodeTimestampedSpeech(data)
    }

    /// A voice on the person's ElevenLabs account.
    struct Voice: Identifiable, Decodable, Hashable {
        let id: String
        let name: String
        private enum CodingKeys: String, CodingKey { case id = "voice_id", name }
    }

    /// The account's voices, by name (https://elevenlabs.io/docs/api-reference/voices/search).
    static func voices(key: String) async throws -> [Voice] {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v2/voices?page_size=100&sort=name&sort_direction=asc&include_total_count=false")!)
        request.timeoutInterval = 15
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw NSError(domain: "ElevenLabs", code: status, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"])
        }
        struct Page: Decodable { let voices: [Voice] }
        return try JSONDecoder().decode(Page.self, from: data).voices.filter { isVoiceID($0.id) }
    }

    /// The with-timestamps response: `audio_base64`, and `alignment` over the original text.
    private struct TimestampedSpeech: Decodable {
        struct Alignment: Decodable {
            let characters: [String]
            let character_start_times_seconds: [Double]
        }
        let audio_base64: String
        let alignment: Alignment?
    }

    static func decodeTimestampedSpeech(_ data: Data) throws -> CookieSpeechAudio {
        let speech = try JSONDecoder().decode(TimestampedSpeech.self, from: data)
        guard let audio = Data(base64Encoded: speech.audio_base64), !audio.isEmpty else {
            throw NSError(domain: "ElevenLabs", code: 0, userInfo: [NSLocalizedDescriptionKey: "No audio in the reply"])
        }
        return CookieSpeechAudio(data: audio, characterStarts: characterStarts(
            characters: speech.alignment?.characters ?? [], startTimes: speech.alignment?.character_start_times_seconds ?? []))
    }

    /// ElevenLabs counts characters as strings; the clock counts UTF-16 offsets into the spoken text.
    static func characterStarts(characters: [String], startTimes: [Double]) -> [CookieSpeechAudio.CharacterStart] {
        var offset = 0
        return zip(characters, startTimes).map { character, seconds in
            defer { offset += character.utf16.count }
            return CookieSpeechAudio.CharacterStart(offset: offset, seconds: seconds)
        }
    }
}

/// Spoken audio from a cloud voice, with when each character is heard.
struct CookieSpeechAudio {
    struct CharacterStart: Equatable {
        /// UTF-16 offset into the spoken text.
        let offset: Int
        let seconds: Double
    }
    let data: Data
    /// Ascending by time; empty when the voice gave no timing.
    var characterStarts: [CharacterStart] = []
}

@MainActor
protocol CookieSpeechPlayback: AnyObject {
    var onStarted: (() -> Void)? { get set }
    /// The UTF-16 offset being spoken now, and how much of the reply has been heard (0...1).
    var onProgress: ((_ spokenOffset: Int, _ progress: Double) -> Void)? { get set }
    var onFinished: (() -> Void)? { get set }
    func speakLocally(_ text: String)
    func playAudio(_ audio: CookieSpeechAudio, text: String) throws
    func stop()
}

/// A fresh output for each reply keeps late delegates from completing a newer reply.
@MainActor
private final class NativeCookieSpeechPlayback: NSObject, CookieSpeechPlayback, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    var onStarted: (() -> Void)?
    var onProgress: ((_ spokenOffset: Int, _ progress: Double) -> Void)?
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

    func playAudio(_ audio: CookieSpeechAudio, text: String) throws {
        let player = try AVAudioPlayer(data: audio.data)
        self.player = player
        player.delegate = self
        guard player.play() else { throw NSError(domain: "CookieSpeech", code: 1) }
        onStarted?()
        // Follow the playback position, so stopping audio also stops the reveal; the
        // character timings say which character that position is. ~60 Hz, the clock's resolution.
        let starts = audio.characterStarts
        let length = text.utf16.count
        var next = 0
        progressTask = Task { @MainActor [weak self, weak player] in
            while !Task.isCancelled {
                guard let self, let player, self.player === player, player.isPlaying else { return }
                if player.duration > 0 {
                    let now = player.currentTime
                    while next < starts.count && starts[next].seconds <= now { next += 1 }
                    let progress = now / player.duration
                    // ponytail: no timing from the voice → the offset is proportional to time, an estimate.
                    let offset = starts.isEmpty ? Int(Double(length) * min(1, progress))
                                                : (next == 0 ? 0 : starts[next - 1].offset)
                    self.onProgress?(offset, progress)
                }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
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
            self?.onProgress?(characterRange.location,
                              Double(NSMaxRange(characterRange)) / Double(utterance.speechString.utf16.count))
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
