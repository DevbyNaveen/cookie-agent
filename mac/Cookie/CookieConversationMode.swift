import Foundation

/// A modifier chord toggles on release only if it wasn't part of another shortcut.
struct CookieConversationGesture {
    private(set) var held = false
    private var usedByShortcut = false
    mutating func reset() { held = false; usedByShortcut = false }
    mutating func update(held next: Bool, otherKey: Bool = false) -> Bool {
        if next {
            if !held { usedByShortcut = false }
            held = true
            usedByShortcut = usedByShortcut || otherKey
            return false
        }
        let toggle = held && !usedByShortcut && !otherKey
        reset()
        return toggle
    }
}

/// Bounded turn detection, independent of rendering and the transcription provider.
struct CookieConversationTurn {
    enum Decision { case listen, finish, timeout }
    let startedAt: TimeInterval
    let requiresRecognizedSpeech: Bool
    let pause: TimeInterval
    private var lastSpeechAt: TimeInterval?
    private var voicedSamples = 0
    private var lastTranscript = ""
    init(at now: TimeInterval, requiresRecognizedSpeech: Bool = false, pause: TimeInterval = 1.6) {
        startedAt = now
        self.requiresRecognizedSpeech = requiresRecognizedSpeech
        self.pause = pause.isFinite ? min(5, max(0.8, pause)) : 1.6
    }
    mutating func transcript(_ text: String, at now: TimeInterval) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != lastTranscript else { return }
        lastTranscript = text
        lastSpeechAt = now
        voicedSamples = max(voicedSamples, 4)
    }
    mutating func sample(power: Double, at now: TimeInterval) -> Decision {
        if power > 0.04 { voicedSamples += 1; lastSpeechAt = now }
        else if voicedSamples < 4 && lastTranscript.isEmpty { voicedSamples = 0 }
        if requiresRecognizedSpeech && lastTranscript.isEmpty {
            return now - startedAt >= 20 ? .timeout : .listen
        }
        if now - startedAt >= 60 { return voicedSamples >= 4 ? .finish : .timeout }
        if voicedSamples >= 4, let lastSpeechAt, now - lastSpeechAt >= pause { return .finish }
        if voicedSamples < 4, now - startedAt >= 20 { return .timeout }
        return .listen
    }
}
