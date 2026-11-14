//
//  CleanupGuard.swift
//  EnkeonVoiceKit
//
//  The check every model clean-up must pass before it replaces what was heard.
//  A clean-up may drop fillers, repeated words and the few words a speaker
//  corrected; it may fix case, punctuation and number formatting. It may not
//  add words, drop meaning or grow. Measured on Apple's on-device model
//  (2026-10-30), the failures this catches: a name pasted where it wasn't said
//  ("can Halvorsen tell me time"), a clause dropped ("I think we should"), and
//  an instruction obeyed (a poem instead of the dictated sentence).
//

import Foundation

public enum CleanupGuard {
    static let fillers: Set<String> = ["um", "uh", "uhm", "umm", "er", "erm", "hmm", "ah", "like", "so"]
    static let correctionMarkers = ["no wait", "wait no", "i mean", "sorry", "actually no", "no no", "scratch that"]

    public enum Verdict: Equatable {
        case accepted
        case rejected(String)
    }

    public static func check(heard: String, cleaned: String) -> Verdict {
        let before = words(heard)
        let after = words(cleaned)
        guard !before.isEmpty else { return after.isEmpty ? .accepted : .rejected("added words to silence") }
        guard !after.isEmpty else { return .rejected("removed everything") }
        // Small edit distance is not semantic safety: one removed "not" reverses intent.
        let negations: Set<String> = ["not", "no", "never", "cannot", "can't", "don't", "doesn't", "didn't", "won't", "wouldn't", "shouldn't", "isn't", "aren't"]
        let normalizedBefore = before.map { $0.replacingOccurrences(of: "’", with: "'") }
        let normalizedAfter = after.map { $0.replacingOccurrences(of: "’", with: "'") }
        // "no wait" is an explicit spoken self-correction, handled below.
        let beforeNegations = normalizedBefore.filter { negations.contains($0) && $0 != "no" }
        let afterNegations = normalizedAfter.filter { negations.contains($0) && $0 != "no" }
        guard beforeNegations == afterNegations else { return .rejected("changed a negation") }
        if before.filter({ $0 == "no" }).count != after.filter({ $0 == "no" }).count,
           !correctionMarkers.contains(where: { heard.lowercased().contains($0) }) {
            return .rejected("changed a negation")
        }
        // Keep numeric values exact. Number formatting is accepted only when the
        // formatter's spelled-out value occurs verbatim in the source.
        var numericPool = multiset(before.filter { $0.contains(where: \.isNumber) })
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .spellOut
        let sourceWords = " " + before.joined(separator: " ").replacingOccurrences(of: "-", with: " ") + " "
        for number in after.filter({ $0.contains(where: \.isNumber) }) {
            if let count = numericPool[number], count > 0 { numericPool[number] = count - 1; continue }
            guard number.allSatisfy(\.isNumber), let value = Int(number),
                  let spelled = formatter.string(from: NSNumber(value: value)),
                  sourceWords.contains(" " + spelled.replacingOccurrences(of: "-", with: " ") + " ") else {
                return .rejected("introduced or changed a number")
            }
        }
        guard numericPool.values.allSatisfy({ $0 == 0 }) else { return .rejected("removed a number") }
        if after.count > before.count + 1 { return .rejected("grew") }

        // Words the model brought in. Digits are number formatting ("twenty five" → 25), not new words.
        var pool = multiset(before)
        var added = 0
        for word in after {
            if let count = pool[word], count > 0 { pool[word] = count - 1 }
            else if word.allSatisfy({ $0.isNumber || $0 == "%" || $0 == "$" || $0 == ":" || $0 == "." }) { continue }
            else { added += 1 }
        }
        if added > 0 { return .rejected("added \(added) words") }

        // Words it took out that aren't fillers: allowed for repeats and around a self-correction.
        let removed = pool.filter { !fillers.contains($0.key) }.reduce(0) { $0 + $1.value }
        let repeats = zip(before, before.dropFirst()).filter { $0 == $1 }.count
        let lowered = heard.lowercased()
        let corrections = correctionMarkers.reduce(0) { $0 + lowered.components(separatedBy: $1).count - 1 }
        // Number words the digits replaced ("twenty five" → "25"): each digit token may stand for up to three.
        let numberTokens = after.filter { $0.contains(where: \.isNumber) }.count
        let allowed = repeats + corrections * 4 + numberTokens * 3 + 1
        if removed > allowed { return .rejected("dropped \(removed) words") }
        return .accepted
    }

    /// Lowercased words without punctuation ("p.m." and "pm" both become "pm").
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { $0.isWhitespace || $0.isNewline || ",;!?\"“”()".contains($0) }
            .map { word -> String in
                let token = String(word)
                // "3.5" and "2:30" keep their dots and colons; "p.m." and "end." lose them.
                return token.contains(where: \.isNumber)
                    ? token.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    : token.replacingOccurrences(of: ".", with: "")
            }
            .filter { !$0.isEmpty && $0 != "-" && $0 != "—" }
    }

    static func multiset(_ words: [String]) -> [String: Int] {
        words.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}
