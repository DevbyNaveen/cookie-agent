//
//  Proofreader.swift
//  EnkeonVoiceKit
//
//  Spelling the Mac is already sure of. macOS's own checker (instant, offline, never invents words)
//  gives its autocorrection for a word, not a list of guesses, so only confident fixes come back.
//  Grammar and tone are the on-device model's job (Fix, Humanise); measured 2026-10-30, the
//  checker's grammar pass found nothing in "She go to school every days."
//

import AppKit

public enum Proofreader {
    /// Replace `range` (UTF-16, in the checked text) with `replacement`.
    public struct Fix: Equatable {
        public let range: NSRange
        public let replacement: String
    }

    @MainActor private static let tag = NSSpellChecker.uniqueSpellDocumentTag()

    /// Confident spelling fixes in `text`, skipping names (a capital mid-sentence), words with digits
    /// and words `knows` says are yours.
    @MainActor public static func spelling(in text: String, knows: (String) -> Bool) -> [Fix] {
        let checker = NSSpellChecker.shared
        let ns = text as NSString
        let types = NSTextCheckingResult.CheckingType.spelling.rawValue | NSTextCheckingResult.CheckingType.correction.rawValue
        let results = checker.check(text, range: NSRange(location: 0, length: ns.length), types: types, options: nil,
                                    inSpellDocumentWithTag: tag, orthography: nil, wordCount: nil)
        var fixes: [Fix] = []
        for result in results {
            let word = ns.substring(with: result.range)
            guard !word.contains(where: \.isNumber), !knows(word) else { continue }
            if word.first?.isUppercase == true, !startsSentence(ns, at: result.range.location) { continue }
            let replacement: String?
            switch result.resultType {
            case .spelling:
                replacement = checker.correction(forWordRange: result.range, in: text, language: checker.language(), inSpellDocumentWithTag: tag)
            case .correction:
                replacement = result.replacementString
            default:
                replacement = nil
            }
            if let replacement, replacement != word, !fixes.contains(where: { NSIntersectionRange($0.range, result.range).length > 0 }) {
                fixes.append(Fix(range: result.range, replacement: replacement))
            }
        }
        return fixes
    }

    static func startsSentence(_ text: NSString, at location: Int) -> Bool {
        let before = text.substring(to: location).trimmingCharacters(in: .whitespaces)
        return before.isEmpty || ".!?\n".contains(before.last!)
    }

    public static func apply(_ fixes: [Fix], to text: String) -> String {
        let out = NSMutableString(string: text)
        for fix in fixes.sorted(by: { $0.range.location > $1.range.location }) {
            out.replaceCharacters(in: fix.range, with: fix.replacement)
        }
        return out as String
    }

    // MARK: What changed

    /// `revised`, word by word, each marked when it isn't in `original` at that place (a word-level
    /// longest common subsequence). Spaces stay with the word before them.
    public static func changes(from original: String, to revised: String) -> [(text: String, changed: Bool)] {
        let old = words(original), new = words(revised)
        let a = old.map(comparable), b = new.map(comparable)
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [(text: String, changed: Bool)] = []
        var i = 0, j = 0
        while j < b.count {
            if i < a.count, a[i] == b[j] {
                out.append((new[j], false)); i += 1; j += 1
            } else if i < a.count, table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                out.append((new[j], true)); j += 1
            }
        }
        return out
    }

    /// The share of words that differ: what an edit costs to read.
    public static func editShare(from original: String, to revised: String) -> Double {
        let marked = changes(from: original, to: revised)
        let kept = marked.filter { !$0.changed }.count
        let total = max(words(original).count, marked.count)
        return total == 0 ? 0 : 1 - Double(kept) / Double(total)
    }

    /// Words with the spaces after them, so the pieces join back into the text.
    static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            if character.isWhitespace {
                current.append(character)
            } else {
                if let last = current.last, last.isWhitespace { out.append(current); current = "" }
                current.append(character)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func comparable(_ word: String) -> String { word.trimmingCharacters(in: .whitespacesAndNewlines) }
}
