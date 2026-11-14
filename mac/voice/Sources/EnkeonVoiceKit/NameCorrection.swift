//
//  NameCorrection.swift
//  EnkeonVoiceKit
//
//  The recognizer's near-misses on the person's own words: "Halverson" for
//  Halvorsen, "Bright line" for Brightline. A heard word (or two run together)
//  close in spelling to a vocabulary term becomes the term. A correctly spelled
//  English word is left alone unless it matches exactly, so "coffee" never
//  becomes "Coffey". Approach after Handy's custom words (cjpais/Handy, MIT):
//  edit distance with a length guard, plus a sound-alike check.
//

import AppKit

enum NameCorrection {
    static func apply(to text: String, terms: [String]) -> String {
        let candidates = terms.filter { letters($0).count >= 4 && !$0.contains(" ") }
        guard !candidates.isEmpty else { return text }
        var tokens = text.components(separatedBy: " ")
        var index = 0
        while index < tokens.count {
            // Two heard words run together first ("Bright line"), then one.
            for width in [2, 1] where index + width <= tokens.count {
                let window = Array(tokens[index..<index + width])
                let heard = letters(window.joined())
                guard heard.count >= 4 else { continue }
                if let term = candidates.first(where: { matches(heard: heard, window: window, term: $0) }) {
                    let trailing = String(window.last!.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
                    let leading = String(window.first!.prefix { !$0.isLetter && !$0.isNumber })
                    tokens.replaceSubrange(index..<index + width, with: [leading + term + trailing])
                    break
                }
            }
            index += 1
        }
        return tokens.joined(separator: " ")
    }

    static func matches(heard: String, window: [String], term: String) -> Bool {
        let target = letters(term)
        if heard == target { return true }
        // Two words merge only when they spell the term exactly: a near miss would swallow a real word ("Enkeon is").
        guard window.count == 1 else { return false }
        // Two words merge only when they spell the term exactly: a near miss would swallow a real word ("Enkeon is").
        guard window.count == 1 else { return false }
        let longer = max(heard.count, target.count)
        guard abs(heard.count - target.count) <= max(2, longer / 4) else { return false }
        // Real words stay real words: only exact matches replace them.
        if window.allSatisfy(isEnglishWord) { return false }
        let distance = Double(levenshtein(heard, target)) / Double(longer)
        return distance <= 0.25 || (distance <= 0.34 && soundex(heard) == soundex(target))
    }

    static func letters(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

    @MainActor static let speller = NSSpellChecker.shared
    static func isEnglishWord(_ word: String) -> Bool {
        let bare = word.filter { $0.isLetter }
        guard bare.count >= 2 else { return true }
        return MainActor.assumeIsolated {
            speller.checkSpelling(of: bare, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }

    /// American Soundex: first letter and three digits.
    static func soundex(_ word: String) -> String {
        let codes: [Character: Character] = ["b": "1", "f": "1", "p": "1", "v": "1", "c": "2", "g": "2", "j": "2", "k": "2", "q": "2",
                                             "s": "2", "x": "2", "z": "2", "d": "3", "t": "3", "l": "4", "m": "5", "n": "5", "r": "6"]
        let letters = Array(word.lowercased().filter(\.isLetter))
        guard let first = letters.first else { return "" }
        var result = String(first).uppercased()
        var last = codes[first]
        for letter in letters.dropFirst() {
            let code = codes[letter]
            if let code, code != last { result.append(code) }
            if letter != "h" && letter != "w" { last = code }
            if result.count == 4 { break }
        }
        return result.padding(toLength: 4, withPad: "0", startingAt: 0)
    }
}
