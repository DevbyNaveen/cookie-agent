import Foundation
import Combine

/// Kept with navigation so folding the notch preserves the idea and the character.
@MainActor
final class CookieCreationSession: ObservableObject {
    typealias Conversation = ([(you: String, cookie: String)], String, UUID) async throws -> (say: String, agent: CookieAgent?)
    typealias Speech = (String, @escaping () -> Void, @escaping (Double) -> Void) async -> Void

    static let opening = "What would you love a little help with?"
    @Published var typed = ""
    @Published var draft: CookieAgent?
    @Published private(set) var line = opening
    @Published private(set) var lastAnswer = ""
    @Published private(set) var problem: String?
    @Published private(set) var phase: CookieComposerPhase = .ready
    @Published private(set) var preparingSpeech = false
    @Published private(set) var speechProgress = 1.0
    private(set) var identity = UUID()
    private var history: [(you: String, cookie: String)] = []

    /// Everything the person said while making this Cookie: its first job.
    var wish: String {
        let said = history.map(\.you) + (history.last?.you == lastAnswer || lastAnswer.isEmpty ? [] : [lastAnswer])
        return said.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var configuredPage: CookieNavigation.AgentPage?
    private var request: Task<Void, Never>?
    private var requestID = UUID()

    /// Returns true only for a fresh creation; returning to a folded page stays quiet.
    func prepare(page: CookieNavigation.AgentPage?, profile: CookieAgent?) -> Bool {
        guard configuredPage != page else { return false }
        configuredPage = page
        reset(profile: profile)
        return page == .new
    }

    func reset(profile: CookieAgent? = nil) {
        stop()
        identity = profile?.id ?? UUID()
        draft = profile
        typed = ""
        line = Self.opening
        lastAnswer = ""
        history = []
        problem = nil
    }

    func finish() {
        configuredPage = nil
        reset()
    }

    func greet(speech: @escaping Speech) {
        stop()
        let identifier = requestID
        request = Task { await say(line, identifier: identifier, speech: speech) }
    }

    @discardableResult
    func answer(_ input: String, conversation: @escaping Conversation, speech: @escaping Speech) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, phase != .thinking else { return false }
        stop()
        if typed.trimmingCharacters(in: .whitespacesAndNewlines) == text { typed = "" }
        lastAnswer = text
        problem = nil
        phase = .thinking
        let identifier = requestID
        let previousHistory = history
        let characterID = identity
        request = Task {
            do {
                let reply = try await conversation(previousHistory, text, characterID)
                guard !Task.isCancelled, requestID == identifier else { return }
                history.append((text, reply.say))
                line = reply.say.prefix(1).uppercased() + reply.say.dropFirst()
                if let agent = reply.agent { draft = agent }
                phase = .ready
                await say(line, identifier: identifier, speech: speech)
            } catch {
                guard !Task.isCancelled, requestID == identifier else { return }
                phase = .ready
                problem = error.localizedDescription
                if typed.isEmpty { typed = text }
            }
        }
        return true
    }

    func stop() {
        requestID = UUID()
        request?.cancel()
        request = nil
        phase = .ready
        preparingSpeech = false
        speechProgress = 1
    }

    private func say(_ text: String, identifier: UUID, speech: @escaping Speech) async {
        guard !Task.isCancelled, requestID == identifier else { return }
        preparingSpeech = true
        // The full line stays readable during a slow download. Reveal starts with sound.
        speechProgress = 1
        await speech(text, { [weak self] in
            guard let self, self.requestID == identifier else { return }
            self.preparingSpeech = false
            self.phase = .speaking
            self.speechProgress = 0
        }, { [weak self] progress in
            guard let self, self.requestID == identifier, self.phase == .speaking, progress.isFinite else { return }
            self.speechProgress = max(self.speechProgress, min(1, max(0, progress)))
        })
        guard !Task.isCancelled, requestID == identifier else { return }
        preparingSpeech = false
        phase = .ready
        speechProgress = 1
        request = nil
    }
}

enum CookieSpokenText {
    /// Reveal whole words without splitting an emoji, accent or native speech's UTF-16 range.
    static func parts(_ text: String, progress: Double) -> (spoken: String, upcoming: String) {
        guard progress.isFinite, progress > 0 else { return ("", text) }
        guard progress < 1 else { return (text, "") }
        let target = max(1, Int(ceil(Double(text.utf16.count) * progress)))
        var length = 0
        var boundary = text.startIndex
        while boundary < text.endIndex {
            let character = text[boundary]
            if length >= target && character.isWhitespace { break }
            length += String(character).utf16.count
            boundary = text.index(after: boundary)
        }
        return (String(text[..<boundary]), String(text[boundary...]))
    }
}
