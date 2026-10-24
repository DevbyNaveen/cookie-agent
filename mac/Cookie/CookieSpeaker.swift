//
//  CookieSpeaker.swift
//  Cookie
//
//  Speaks Cookie's replies while they are still being written. Signed in to
//  Enkeon with its voice on (GET /v1/cookie/session says `speech`), the words
//  go to Enkeon's streaming speech route and no key of the person's is
//  needed; else, with an ElevenLabs key in Settings, straight to ElevenLabs'
//  stream-input socket. Either way it is one socket per reply, fed as the
//  model writes, answering with audio and the time each character is heard.
//  Without either, or when the socket fails, the best voice installed on this
//  Mac speaks it, sentence by sentence as the sentences arrive. Every way,
//  `CookieSpeechClock` knows which character is being heard now.
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
    /// ElevenLabs' fastest model, and one its stream-input socket takes (v3 and v4 it doesn't).
    static let elevenLabsModel = "eleven_flash_v2_5"
    /// Raw PCM (no decoder priming, no MP3 frames to join), at a rate the gateway relays too.
    static let outputFormat = "pcm_24000"
    static let outputSampleRate = 24_000.0

    /// The chosen voice id, or Jessica. Only letters and digits: it goes into the URL path.
    static var elevenLabsVoice: String {
        let chosen = (UserDefaults.standard.string(forKey: elevenLabsVoiceKey) ?? "").trimmingCharacters(in: .whitespaces)
        return isVoiceID(chosen) ? chosen : elevenLabsVoiceID
    }

    static func isVoiceID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 64 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The voice chosen in Settings, only when one was chosen: Enkeon then uses
    /// its own default rather than the app's.
    static var chosenVoice: String? {
        let chosen = (UserDefaults.standard.string(forKey: elevenLabsVoiceKey) ?? "").trimmingCharacters(in: .whitespaces)
        return isVoiceID(chosen) ? chosen : nil
    }

    /// Said, in the same voice, when a tool round starts before the model has said anything.
    static let acknowledgement = "One moment."

    /// Where speech is now. One per speaker, shared by every reply it speaks.
    let clock = CookieSpeechClock()

    enum State { case idle, preparing, speaking }
    private(set) var state: State = .idle

    /// Where a cloud voice comes from; nil = this Mac's voice.
    enum Source: Equatable {
        case enkeon
        case personal(key: String)
    }

    private let makeCloud: @MainActor (Source) -> CookieSpeechPlayback
    private let makeLocal: @MainActor (_ startOffset: Int) -> CookieSpeechPlayback
    private let sourceProvider: () async -> Source?

    init(makeLocal: @escaping @MainActor (_ startOffset: Int) -> CookieSpeechPlayback = { CookieMacVoice(startOffset: $0) },
         makeCloud: @escaping @MainActor (Source) -> CookieSpeechPlayback = { CookieCloudVoice(source: $0) },
         sourceProvider: @escaping () async -> Source? = { await CookieSpeaker.source() }) {
        self.makeLocal = makeLocal
        self.makeCloud = makeCloud
        self.sourceProvider = sourceProvider
    }

    /// Enkeon's voice when signed in and it's set up there, else the person's key, else none.
    static func source() async -> Source? {
        if CookieAccount.shared.isSignedIn, await CookieAPI.shared.loadSession()?.speech == true { return .enkeon }
        return CookieModelSettings.value(CookieModelSettings.elevenLabsField).map { .personal(key: $0) }
    }

    // MARK: One reply

    /// The reply being spoken: its words as they stream, the voice speaking them, and who waits.
    private final class Reply {
        let id = UUID()
        var stream = CookieSpokenStream()
        var playback: CookieSpeechPlayback?
        /// Words released before the voice existed (the source is still being found), in order.
        var waiting: [(words: String, flush: Bool, aside: Bool)] = []
        var finished = false
        var flushedFirstClause = false
        var anyWordsSent = false
        var acknowledged = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var onPlaybackStarted: () -> Void = {}
        var onPlaybackProgress: (Double) -> Void = { _ in }
        var onFirstWords: () -> Void = {}
        var onTags: ([CookieReplyTag]) -> Void = { _ in }
    }

    private var reply: Reply?
    private var finding: Task<Void, Never>?
    /// A cloud voice opened on key-down, waiting for the reply it was opened for.
    private var prepared: (voice: CookieSpeechPlayback, source: Source, at: Date)?

    /// The talk key went down: find the voice and open its socket now, so its handshake overlaps
    /// the person's speech. Used by the next reply if it starts within a minute.
    func prepare() {
        Task { [weak self] in
            guard let self, let source = await self.sourceProvider() else { return }
            if let prepared = self.prepared, prepared.source == source, Date().timeIntervalSince(prepared.at) < 50 { return }
            self.prepared?.voice.stop()
            let voice = self.makeCloud(source)
            voice.open()
            let at = Date()
            self.prepared = (voice, source, at)
            // Unused (the person let go without a question): closed, not left open on the account.
            try? await Task.sleep(for: .seconds(60))
            if let prepared = self.prepared, prepared.at == at {
                prepared.voice.stop()
                self.prepared = nil
            }
        }
    }

    /// Starts speaking a reply whose words will arrive with `update`; stops any speech before it.
    /// `onTags` gets each tag once its place in the spoken words is final; `onFirstWords` fires
    /// when the first words go to the voice; the clock begins just before `onPlaybackStarted`.
    func beginReply(onPlaybackStarted: @escaping () -> Void = {},
                    onPlaybackProgress: @escaping (Double) -> Void = { _ in },
                    onFirstWords: @escaping () -> Void = {},
                    onTags: @escaping ([CookieReplyTag]) -> Void = { _ in }) {
        stopPlayback()
        let reply = Reply()
        reply.onPlaybackStarted = onPlaybackStarted
        reply.onPlaybackProgress = onPlaybackProgress
        reply.onFirstWords = onFirstWords
        reply.onTags = onTags
        self.reply = reply
        state = .preparing
        if let prepared, Date().timeIntervalSince(prepared.at) < 50 {
            self.prepared = nil
            attach(prepared.voice, to: reply)
            return
        }
        prepared?.voice.stop()
        prepared = nil
        finding = Task { [weak self] in
            let source = await self?.sourceProvider()
            guard let self, !Task.isCancelled, self.reply === reply else { return }
            if let source {
                let voice = self.makeCloud(source)
                voice.open()
                self.attach(voice, to: reply)
            } else {
                self.attach(self.makeLocal(0), to: reply)
            }
        }
    }

    /// The whole reply so far, tags and all.
    func update(_ text: String) {
        guard let reply else { return }
        release(reply.stream.update(text), in: reply)
    }

    /// A tool round started: what was said so far is spoken now, not held for more words; and if
    /// nothing has been said yet, a short acknowledgement fills the wait.
    func toolStarted() {
        guard let reply, !reply.finished else { return }
        if !reply.anyWordsSent && !reply.acknowledged {
            reply.acknowledged = true
            send(Self.acknowledgement + " ", flush: true, aside: true, in: reply)
        } else if reply.anyWordsSent {
            send("", flush: true, aside: false, in: reply)
        }
    }

    /// The reply is complete: its last words go, then the voice finishes what it has.
    func finishReply(_ text: String) {
        guard let reply, !reply.finished else { return }
        release(reply.stream.update(text, final: true), in: reply)
        reply.finished = true
        if let playback = reply.playback { playback.finish() } else { reply.waiting.append(("", false, false)) }
    }

    /// The reply's spoken words (tags out), as far as they have arrived.
    var spokenText: String { reply?.stream.spoken ?? "" }

    /// Returns once the reply has been heard to the end, or stopped.
    func waitUntilDone() async {
        guard let reply, state != .idle else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.reply === reply, self.state != .idle {
                    reply.waiters.append(continuation)
                } else {
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.reply === reply else { return }
                self?.stopPlayback()
            }
        }
    }

    /// Says one line and returns when it has been heard, or stopped.
    func speakText(_ text: String, onPlaybackProgress: @escaping (Double) -> Void = { _ in },
                   onPlaybackStarted: @escaping () -> Void = {}) async {
        stopPlayback()
        guard !Task.isCancelled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        beginReply(onPlaybackStarted: onPlaybackStarted, onPlaybackProgress: onPlaybackProgress)
        finishReply(text)
        await waitUntilDone()
    }

    var isPlaying: Bool { state == .speaking }
    var isActive: Bool { state != .idle }

    func stopPlayback() {
        state = .idle
        finding?.cancel()
        finding = nil
        let ending = reply
        reply = nil
        if let playback = ending?.playback { detach(playback) }
        clock.stop()
        ending?.waiters.forEach { $0.resume() }
        ending?.waiters = []
    }

    // MARK: Plumbing

    private func release(_ update: (words: String, tags: [CookieReplyTag]), in reply: Reply) {
        if !update.tags.isEmpty { reply.onTags(update.tags) }
        if clock.isSpeaking { clock.setText(reply.stream.spoken) }
        guard !update.words.isEmpty else { return }
        let releasedText = String(reply.stream.spoken.utf16.prefix(reply.stream.released)) ?? ""
        let early = !reply.flushedFirstClause && CookieSpokenStream.holdsFirstClause(releasedText)
        if early { reply.flushedFirstClause = true }
        send(update.words, flush: early, aside: false, in: reply)
    }

    private func send(_ words: String, flush: Bool, aside: Bool, in reply: Reply) {
        if !aside, !words.isEmpty, !reply.anyWordsSent {
            reply.anyWordsSent = true
            reply.onFirstWords()
        }
        guard let playback = reply.playback else {
            reply.waiting.append((words, flush, aside))
            return
        }
        if aside { playback.speakAside(words) } else { playback.speak(words, flush: flush) }
    }

    /// The voice for a reply: its callbacks answer only while it is this reply's, and what was
    /// released before it existed is said first.
    private func attach(_ playback: CookieSpeechPlayback, to reply: Reply) {
        reply.playback = playback
        playback.onStarted = { [weak self, weak reply] in
            guard let self, let reply, self.reply === reply, self.state != .speaking else { return }
            self.state = .speaking
            self.clock.begin(text: reply.stream.spoken)
            reply.onPlaybackStarted()
        }
        playback.onProgress = { [weak self, weak reply] offset in
            guard let self, let reply, self.reply === reply, self.state == .speaking else { return }
            let length = max(1, reply.stream.spoken.utf16.count)
            self.clock.advance(toOffset: offset, progress: reply.finished ? Double(offset) / Double(length) : 0)
            reply.onPlaybackProgress(self.clock.progress)
        }
        playback.onFinished = { [weak self, weak reply] in
            guard let self, let reply, self.reply === reply else { return }
            // Heard to the end: work scheduled past the last reported character runs now.
            self.clock.finish()
            self.stopPlayback()
        }
        playback.onFailed = { [weak self, weak reply, weak playback] resumeFrom in
            guard let self, let reply, let playback, self.reply === reply, reply.playback === playback else { return }
            print("⚠️ Cloud speech unavailable; using this Mac's voice")
            self.fallBack(reply, from: resumeFrom)
        }
        let waiting = reply.waiting
        reply.waiting = []
        for item in waiting {
            if item.words.isEmpty && !item.flush && !item.aside && reply.finished {
                playback.finish()
            } else if item.aside {
                playback.speakAside(item.words)
            } else {
                playback.speak(item.words, flush: item.flush)
            }
        }
    }

    /// The cloud voice failed: this Mac's voice says the rest, from the word being heard (or
    /// the start, if nothing was heard yet). The clock carries on where it was.
    private func fallBack(_ reply: Reply, from resumeFrom: Int) {
        if let failed = reply.playback { detach(failed) }
        let local = makeLocal(resumeFrom)
        reply.playback = nil
        attach(local, to: reply)
        let units = Array(reply.stream.spoken.utf16)
        let start = min(max(0, resumeFrom), reply.stream.released)
        if start < reply.stream.released {
            local.speak(String(utf16CodeUnits: Array(units[start..<reply.stream.released]), count: reply.stream.released - start), flush: false)
        }
        if reply.finished { local.finish() }
    }

    private func detach(_ playback: CookieSpeechPlayback) {
        playback.onStarted = nil
        playback.onProgress = nil
        playback.onFinished = nil
        playback.onFailed = nil
        playback.stop()
    }

    // MARK: ElevenLabs account

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
}

/// A voice speaking one reply as its words arrive. A fresh one for each reply keeps late
/// callbacks from reaching a newer reply.
@MainActor
protocol CookieSpeechPlayback: AnyObject {
    var onStarted: (() -> Void)? { get set }
    /// The UTF-16 offset in the reply's spoken words being heard now.
    var onProgress: ((_ spokenOffset: Int) -> Void)? { get set }
    var onFinished: (() -> Void)? { get set }
    /// The voice can't go on; the offset to resume the reply from (a cloud voice only).
    var onFailed: ((_ resumeFrom: Int) -> Void)? { get set }
    /// Connect ahead of the first words (a cloud voice; nothing for this Mac's).
    func open()
    /// Words that are heard but are not the reply's (the acknowledgement), before any of its words.
    func speakAside(_ words: String)
    /// The reply's next words, in order. `flush` makes the voice start on what it has now.
    func speak(_ words: String, flush: Bool)
    /// No more words: say what is left, then finish.
    func finish()
    func stop()
}

// MARK: - This Mac's voice

/// `AVSpeechSynthesizer`, a sentence at a time as sentences complete; its word callbacks feed
/// the clock, each utterance's ranges moved by where its sentence starts in the reply.
@MainActor
final class CookieMacVoice: NSObject, CookieSpeechPlayback, AVSpeechSynthesizerDelegate {
    var onStarted: (() -> Void)?
    var onProgress: ((_ spokenOffset: Int) -> Void)?
    var onFinished: (() -> Void)?
    var onFailed: ((_ resumeFrom: Int) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    /// Words received but not yet a whole sentence.
    private var pending = ""
    /// Where `pending` starts in the reply's spoken words (UTF-16).
    private var pendingOffset: Int
    /// Utterances queued and not yet finished, with their offset (nil: an aside).
    private var queued: [(utterance: AVSpeechUtterance, offset: Int?)] = []
    private var finished = false
    private var started = false

    init(startOffset: Int) {
        pendingOffset = startOffset
        let language = Locale.preferredLanguages.first ?? "en-US"
        let voices = AVSpeechSynthesisVoice.speechVoices().map {
            CookieSpeaker.Candidate(identifier: $0.identifier, language: $0.language, quality: $0.quality.rawValue)
        }
        voice = CookieSpeaker.best(voices, language: language).flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AVSpeechSynthesisVoice(language: language)
        super.init()
        synthesizer.delegate = self
    }

    func open() {}

    func speakAside(_ words: String) { enqueue(words, offset: nil) }

    func speak(_ words: String, flush: Bool) {
        pending += words
        let cut = flush ? pending.endIndex : Self.lastSentenceEnd(in: pending)
        guard let cut, cut > pending.startIndex else { return }
        let sentence = String(pending[..<cut])
        pending = String(pending[cut...])
        enqueue(sentence, offset: pendingOffset)
        pendingOffset += sentence.utf16.count
    }

    func finish() {
        finished = true
        if !pending.isEmpty {
            enqueue(pending, offset: pendingOffset)
            pendingOffset += pending.utf16.count
            pending = ""
        }
        if queued.isEmpty { Task { @MainActor [weak self] in self?.onFinished?() } }
    }

    func stop() {
        queued = []
        pending = ""
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Just past the last sentence end (". ", "! ", "? " or a line break) in `text`, if any.
    static func lastSentenceEnd(in text: String) -> String.Index? {
        var index = text.endIndex
        while index > text.startIndex {
            let before = text.index(before: index)
            if text[before].isNewline { return index }
            if text[before].isWhitespace, before > text.startIndex, ".!?".contains(text[text.index(before: before)]) { return index }
            index = before
        }
        return nil
    }

    private func enqueue(_ text: String, offset: Int?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        queued.append((utterance, offset))
        synthesizer.speak(utterance)
    }

    private func offset(of utterance: AVSpeechUtterance) -> (found: Bool, offset: Int?) {
        guard let entry = queued.first(where: { $0.utterance === utterance }) else { return (false, nil) }
        return (true, entry.offset)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.offset(of: utterance).found, !self.started else { return }
            self.started = true
            self.onStarted?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                      utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, case (true, let base?) = self.offset(of: utterance) else { return }
            self.onProgress?(base + characterRange.location)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.utteranceEnded(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.utteranceEnded(utterance) }
    }

    private func utteranceEnded(_ utterance: AVSpeechUtterance) {
        guard let index = queued.firstIndex(where: { $0.utterance === utterance }) else { return }
        queued.remove(at: index)
        if finished && queued.isEmpty && pending.isEmpty { onFinished?() }
    }
}

// MARK: - The cloud voice

/// One ElevenLabs stream-input socket for one reply (straight, or through Enkeon's relay, which
/// speaks the same protocol): words go as they are released, audio comes back as raw PCM and
/// plays gaplessly through one `AVAudioPlayerNode`, and each chunk's alignment (times relative
/// to that chunk, per the API reference) is moved onto the audio's own timeline so the clock
/// gets absolute character times. `alignment` is used, not `normalizedAlignment`: normalising
/// rewrites numbers as words, which would move every offset after them.
/// https://elevenlabs.io/docs/api-reference/text-to-speech/v-1-text-to-speech-voice-id-stream-input
@MainActor
final class CookieCloudVoice: CookieSpeechPlayback {
    var onStarted: (() -> Void)?
    var onProgress: ((_ spokenOffset: Int) -> Void)?
    var onFinished: (() -> Void)?
    var onFailed: ((_ resumeFrom: Int) -> Void)? {
        didSet {
            // Opened early (key-down) and failed before a reply took it: the reply hears of it now.
            guard let onFailed, let failedBeforeAttach else { return }
            self.failedBeforeAttach = nil
            Task { @MainActor in onFailed(failedBeforeAttach) }
        }
    }
    private var failedBeforeAttach: Int?

    private let source: CookieSpeaker.Source
    private var socket: URLSessionWebSocketTask?
    private var connecting = false
    /// Messages wait here until the socket is open; then go in order, one at a time.
    private var outbox: [String] = []
    private var sending = false
    private var mapper = CookieAlignmentMapper()
    /// UTF-16 length of the acknowledgement sent ahead of the reply: its characters aren't the reply's.
    private var asideLength = 0
    private var times = CookieCharacterTimes()
    private var timeline = CookieAudioTimeline()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: CookieSpeaker.outputSampleRate, channels: 1)!
    private var engineReady = false
    private var started = false
    private var finishedSending = false
    private var finalReceived = false
    private var ended = false
    private var reconnects = 0
    private var progressTask: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?

    init(source: CookieSpeaker.Source) {
        self.source = source
    }

    /// The socket's request: Enkeon's relay with the account token, or ElevenLabs with the key.
    /// Neither sends `sync_alignment` or `auto_mode`: the relay doesn't pass them, and the
    /// first clause is flushed by hand instead (`CookieSpokenStream.holdsFirstClause`).
    private func request() async throws -> URLRequest {
        switch source {
        case .enkeon:
            return try await CookieAPI.shared.speechStreamRequest(voice: CookieSpeaker.chosenVoice, outputFormat: CookieSpeaker.outputFormat)
        case .personal(let key):
            var components = URLComponents(string: "wss://api.elevenlabs.io/v1/text-to-speech/\(CookieSpeaker.elevenLabsVoice)/stream-input")!
            components.queryItems = [
                URLQueryItem(name: "model_id", value: CookieSpeaker.elevenLabsModel),
                URLQueryItem(name: "output_format", value: CookieSpeaker.outputFormat),
                // A tool round can keep the model quiet for a while: the maximum, not the default 20 s.
                URLQueryItem(name: "inactivity_timeout", value: "180"),
            ]
            var request = URLRequest(url: components.url!)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
            return request
        }
    }

    func open() {
        guard socket == nil, !connecting, !ended else { return }
        connecting = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let request = try await self.request()
                guard !self.ended else { return }
                let socket = URLSession.shared.webSocketTask(with: request)
                // An audio chunk is base64 PCM; the relay allows up to 4 MB.
                socket.maximumMessageSize = 4 * 1024 * 1024
                self.socket = socket
                self.connecting = false
                socket.resume()
                // The first message opens the stream; it must be a single space.
                self.outbox.insert(#"{"text":" "}"#, at: 0)
                self.drain()
                self.receive(on: socket)
            } catch {
                self.connecting = false
                print("⚠️ Cloud speech: couldn't open the stream: \(error.localizedDescription)")
                self.fail()
            }
        }
    }

    func speakAside(_ words: String) {
        mapper.sent(words)
        asideLength = mapper.sentLength
        post(["text": words, "flush": true])
    }

    func speak(_ words: String, flush: Bool) {
        var message: [String: Any] = [:]
        if !words.isEmpty {
            mapper.sent(words)
            // Every text message ends with a space.
            message["text"] = words.last?.isWhitespace == true ? words : words + " "
        } else {
            message["text"] = " "
        }
        if flush { message["flush"] = true }
        post(message)
    }

    func finish() {
        guard !finishedSending else { return }
        finishedSending = true
        // An empty text ends the stream; the voice says what it holds, then sends isFinal.
        post(["text": ""])
    }

    func stop() {
        guard !ended else { return }
        ended = true
        progressTask?.cancel()
        progressTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        outbox = []
        if engineReady {
            player.stop()
            engine.stop()
        }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
    }

    // MARK: Socket

    private func post(_ message: [String: Any]) {
        guard !ended, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        outbox.append(String(decoding: data, as: UTF8.self))
        if socket == nil { open() } else { drain() }
    }

    /// Sends what waits, one message at a time, in order.
    private func drain() {
        guard !sending, let socket, !outbox.isEmpty else { return }
        sending = true
        let message = outbox.removeFirst()
        Task { [weak self] in
            do {
                try await socket.send(.string(message))
                guard let self else { return }
                self.sending = false
                self.drain()
            } catch {
                guard let self, self.socket === socket else { return }
                self.sending = false
                self.socketEnded(socket, error: error)
            }
        }
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        Task { [weak self] in
            while true {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await socket.receive()
                } catch {
                    guard let self, self.socket === socket else { return }
                    self.socketEnded(socket, error: error)
                    return
                }
                guard let self, self.socket === socket, !self.ended else { return }
                switch message {
                case .string(let text): self.handle(Data(text.utf8))
                case .data(let data): self.handle(data)
                @unknown default: break
                }
            }
        }
    }

    /// The socket closed or failed before the stream was done. Closed while the voice had
    /// nothing left to say (a long tool round outlasted its idle limit), it is opened again for
    /// the next words; anything else, this Mac's voice takes over.
    private func socketEnded(_ socket: URLSessionWebSocketTask, error: Error) {
        guard !ended, !finalReceived else { return }
        self.socket = nil
        sending = false
        let status = (socket.response as? HTTPURLResponse)?.statusCode
        let caughtUp = mapper.alignedThrough >= mapper.sentLength - 1
        if !finishedSending, caughtUp, status == nil || status == 101, reconnects < 3 {
            reconnects += 1
            outbox.removeAll { $0 == #"{"text":" "}"# }
            if !outbox.isEmpty { open() }
            return
        }
        print("⚠️ Cloud speech: stream ended early (\(status.map { "HTTP \($0)" } ?? error.localizedDescription))")
        fail()
    }

    private func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let audio = object["audio"] as? String, let bytes = Data(base64Encoded: audio), !bytes.isEmpty {
            play(bytes, alignment: object["alignment"] as? [String: Any])
        }
        if object["isFinal"] as? Bool == true {
            finalReceived = true
            if !started { onFinished?() }
            return
        }
        if object["audio"] == nil, let problem = (object["message"] ?? object["error"]) {
            print("⚠️ Cloud speech: \(problem)")
            fail()
        }
    }

    // MARK: Audio

    /// Raw `pcm_24000`: 16-bit little-endian signed mono samples. ElevenLabs' reference doesn't
    /// spell the sample layout out; this is what its PCM formats are in practice (inference).
    private func play(_ bytes: Data, alignment: [String: Any]?) {
        let frames = bytes.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        bytes.withUnsafeBytes { raw in
            for index in 0..<frames {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                channel[index] = Float(sample) / 32_768
            }
        }
        guard startEngineIfNeeded() else { return fail() }
        let chunkStart = timeline.schedule(frames: Int64(frames), playerSample: started ? playerSample() : nil)
        player.scheduleBuffer(buffer)
        if let alignment, let characters = alignment["chars"] as? [String], let startTimes = alignment["charStartTimesMs"] as? [NSNumber] {
            let chunkSeconds = Double(chunkStart) / CookieSpeaker.outputSampleRate
            for (offset, startMs) in zip(mapper.map(characters), startTimes) {
                guard let offset, offset >= asideLength else { continue }
                times.add(offset: offset - asideLength, seconds: chunkSeconds + startMs.doubleValue / 1000)
            }
        }
        if !started {
            started = true
            player.play()
            onStarted?()
            followPlayback()
        }
    }

    private func startEngineIfNeeded() -> Bool {
        guard !engineReady else { return true }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do { try engine.start() } catch {
            print("⚠️ Cloud speech: the audio output didn't start: \(error.localizedDescription)")
            return false
        }
        engineReady = true
        // Headphones unplugged, another device chosen: the engine stops; the Mac's voice carries on.
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fail() }
        }
        return true
    }

    /// Samples the player has played since it started (it keeps counting through silence).
    private func playerSample() -> Int64 {
        guard let nodeTime = player.lastRenderTime, let time = player.playerTime(forNodeTime: nodeTime) else { return 0 }
        return time.sampleTime
    }

    /// The clock, about 60 times a second: the character heard now, and the end once every
    /// chunk has played after the voice said it was done.
    private func followPlayback() {
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.ended else { return }
                let heard = self.timeline.heard(playerSample: self.playerSample())
                if let offset = self.times.offset(at: Double(heard) / CookieSpeaker.outputSampleRate) {
                    self.onProgress?(offset)
                }
                if self.finalReceived, heard >= self.timeline.scheduled {
                    self.progressTask = nil
                    self.onFinished?()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }

    /// Stops this voice and hands the reply on from the word being heard.
    private func fail() {
        guard !ended else { return }
        let resumeFrom = started ? (times.offset(at: Double(timeline.heard(playerSample: playerSample())) / CookieSpeaker.outputSampleRate) ?? 0) : 0
        stop()
        if let onFailed { onFailed(resumeFrom) } else { failedBeforeAttach = resumeFrom }
    }
}
