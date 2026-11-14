//
//  PhraseMemory.swift
//  EnkeonVoiceKit
//
//  Your own phrases. Every sentence you finish in an ordinary text box is kept here, on this Mac
//  (a file beside the models, never sent anywhere), so when you start one you've written before,
//  the rest comes back in your words, instantly, with no model. Tab makes a phrase stronger, Esc
//  weaker; unused phrases fade over a couple of months. Prediction suffix trees / n-gram keyboards
//  do this; at a few thousand sentences a plain scan is under a millisecond.
//

import Foundation

public final class PhraseMemory {
    struct Sentence: Codable {
        var text: String
        var app: String
        var count: Int
        var accepted: Int
        var rejected: Int
        var last: Date
    }

    static let capacity = 5_000
    static let halfLifeDays = 60.0
    /// Snippet offers: typed this many times, at least this many words.
    static let frequentCount = 5
    static let frequentWords = 6

    private(set) var sentences: [String: Sentence] = [:]
    private var dismissed: Set<String> = []
    private let file: URL?
    private let queue = DispatchQueue(label: "enkeon.phrases", qos: .utility)

    /// `file`: where phrases are kept; nil keeps them in memory only (the checks).
    public init(file: URL?) {
        self.file = file
        guard let file, let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        sentences = Dictionary(saved.sentences.map { (Self.key($0.text), $0) }, uniquingKeysWith: { a, _ in a })
        dismissed = Set(saved.dismissed)
    }

    public static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Enkeon/phrases.json")
    }

    public var count: Int { sentences.count }

    // MARK: Learning

    /// A sentence you finished typing in `app`.
    public func learn(_ sentence: String, app: String, at date: Date = Date()) {
        let text = Self.tidy(sentence)
        let words = Self.tokens(text)
        guard (3...40).contains(words.count), !Self.looksPrivate(text) else { return }
        let key = Self.key(text)
        var entry = sentences[key] ?? Sentence(text: text, app: app, count: 0, accepted: 0, rejected: 0, last: date)
        entry.count += 1
        entry.text = text
        entry.app = app
        entry.last = date
        sentences[key] = entry
        if sentences.count > Self.capacity { evict(now: date) }
        save()
    }

    /// Tab (or Esc) on a phrase shown after `typed`: the sentences that gave it count up (or down).
    public func feedback(_ continuation: String, after typed: String, accepted: Bool) {
        let whole = Self.key(Self.currentSentence(typed) + continuation)
        for key in sentences.keys where key.hasSuffix(whole) || whole.hasSuffix(key) || key.contains(whole) {
            if accepted { sentences[key]!.accepted += 1 } else { sentences[key]!.rejected += 1 }
        }
        save()
    }

    public func forgetAll() {
        sentences = [:]
        dismissed = []
        save()
    }

    // MARK: Suggesting

    /// The rest of the sentence, as you wrote it before, when the last few words you typed match
    /// sentences you've written at least twice (or once and took with Tab), and they agree on how it
    /// goes on. When they disagree, the words they share ("get back to you") are offered alone.
    public func continuation(after typed: String, now: Date = Date()) -> String? {
        let sentence = Self.currentSentence(typed)
        let context = Self.tokens(sentence)
        guard !context.isEmpty else { return nil }
        // Right after a letter the last word may be whole ("I'll") or half typed ("ba"): whole first.
        let modes = typed.last?.isWhitespace == false ? [false, true] : [false]
        // The most specific context that matches anything wins: six words down to two.
        for size in stride(from: min(6, context.count), through: 2, by: -1) {
            let window = Array(context.suffix(size))
            guard window.joined(separator: " ").count >= 8 else { break }
            for partial in modes {
                var weights: [String: Double] = [:]
                for entry in sentences.values {
                    let weight = Self.weight(entry, now: now)
                    guard weight > 0 else { continue }
                    for rest in Self.continuations(of: window, partial: partial, in: Self.tokens(entry.text)) {
                        weights[rest, default: 0] += weight
                    }
                }
                guard !weights.isEmpty else { continue }
                let total = weights.values.reduce(0, +)
                guard total >= 2 else { return nil }
                let best = weights.max { $0.value < $1.value }!
                if best.value >= total * 0.6 { return Self.shaped(best.key, partial: partial, typed: typed) }
                let shared = Self.commonWords(weights.keys.map { $0 })
                return shared.split(separator: " ").count >= 2 ? Self.shaped(shared, partial: partial, typed: typed) : nil
            }
        }
        return nil
    }

    /// Sentences you type so often they could be snippets.
    public func frequent() -> [String] {
        sentences.values
            .filter { $0.count >= Self.frequentCount && Self.tokens($0.text).count >= Self.frequentWords && !dismissed.contains(Self.key($0.text)) }
            .sorted { $0.count > $1.count }
            .map(\.text)
    }

    public func dismissFrequent(_ text: String) {
        dismissed.insert(Self.key(text))
        save()
    }

    /// Whether you've typed `word` at least `times` times: then it's yours, not a typo.
    public func knows(_ word: String, times: Int = 2) -> Bool {
        let needle = word.lowercased()
        var seen = 0
        for entry in sentences.values where Self.tokens(entry.text).contains(where: { Self.bare($0) == needle }) {
            seen += entry.count
            if seen >= times { return true }
        }
        return false
    }

    // MARK: Pieces

    /// Every place `window` appears in `words`, and the words after it. With `partial`, the window's
    /// last word is still being typed: it matches the start of a word, and the rest of that word leads.
    static func continuations(of window: [String], partial: Bool, in words: [String]) -> [String] {
        guard words.count > window.count - (partial ? 1 : 0) else { return [] }
        var out: [String] = []
        let wanted = window.map(bare)
        for start in 0...(words.count - window.count) {
            var match = true
            for (offset, want) in wanted.enumerated() {
                let have = bare(words[start + offset])
                let last = offset == wanted.count - 1
                if last && partial ? !(have.hasPrefix(want) && have.count > want.count) : have != want { match = false; break }
            }
            guard match else { continue }
            let end = start + window.count
            if partial {
                let word = words[end - 1]
                let tail = String(word.dropFirst(window.last!.count))
                let rest = ([tail] + words[end...].prefix(14)).joined(separator: " ")
                out.append(rest)
            } else if end < words.count {
                out.append(words[end...].prefix(14).joined(separator: " "))
            }
        }
        return out
    }

    /// How a suggestion attaches to what's typed: straight on mid-word, after a space otherwise.
    static func shaped(_ rest: String, partial: Bool, typed: String) -> String? {
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if partial { return text }  // the rest of the word, then the words after it
        return typed.last?.isWhitespace == true ? text : " " + text
    }

    static func commonWords(_ options: [String]) -> String {
        let split = options.map { $0.split(separator: " ").map(String.init) }
        guard var shared = split.first else { return "" }
        for words in split.dropFirst() {
            shared = Array(zip(shared, words).prefix { $0.0 == $0.1 }.map(\.0))
        }
        return shared.joined(separator: " ")
    }

    static func weight(_ entry: Sentence, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(entry.last)) / 86_400
        let score = Double(entry.count + 2 * entry.accepted - 3 * entry.rejected)
        return score * pow(0.5, age / halfLifeDays)
    }

    static func tidy(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func tokens(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// A word for matching: lowercase, without the punctuation around it.
    static func bare(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'()[]…“”‘’"))
    }

    static func key(_ text: String) -> String { tokens(text).map(bare).joined(separator: " ") }

    /// The sentence the cursor is in: from the last . ! ? or line break.
    /// Only a mark followed by a space ends a sentence, so "3.5" and "e.g." don't.
    public static func currentSentence(_ text: String) -> String {
        let tail = text.suffix(400)
        var start = tail.startIndex
        var index = tail.endIndex
        while index > tail.startIndex {
            let previous = tail.index(before: index)
            if tail[previous] == "\n" || (".!?".contains(tail[previous]) && index < tail.endIndex && tail[index].isWhitespace) {
                start = index
                break
            }
            index = previous
        }
        return String(tail[start...].drop { $0.isWhitespace })
    }

    /// The finished sentences in `text` (each ends with . ! ? and a space, or a line break), and where
    /// the unfinished rest begins, in UTF-16 units.
    public static func finishedSentences(_ text: String) -> (sentences: [String], end: Int) {
        let pattern = try! NSRegularExpression(pattern: #"(?:[^\n.!?]|[.!?](?![.!?]*\s))*(?:[.!?]+(?=\s)|\n)"#)
        var sentences: [String] = []
        var end = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            let sentence = (text as NSString).substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            end = match.range.location + match.range.length
        }
        return (sentences, end)
    }

    /// Long numbers (cards, codes, phone numbers) and key-like strings are never kept.
    static func looksPrivate(_ text: String) -> Bool {
        if text.range(of: #"\d[\d\s-]{5,}\d"#, options: .regularExpression) != nil { return true }
        return tokens(text).contains { word in
            word.count >= 10 && word.contains(where: \.isNumber) && word.contains(where: \.isLetter) && !word.contains("-")
        }
    }

    private func evict(now: Date) {
        let keep = sentences.sorted { Self.weight($0.value, now: now) > Self.weight($1.value, now: now) }.prefix(Self.capacity * 9 / 10)
        sentences = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private struct Saved: Codable {
        var sentences: [Sentence]
        var dismissed: [String]
    }

    private func save() {
        guard let file else { return }
        let saved = Saved(sentences: Array(sentences.values), dismissed: Array(dismissed))
        queue.async {
            guard let data = try? JSONEncoder().encode(saved) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}
