import Foundation

/// A continuation copied from a complete memory statement, not newly generated facts.
/// Conservative by design: prefix wording must match and competing answers suppress the suggestion.
public enum MemorySentenceCompletion {
    public static func continuation(after typed: String, memories: [String]) -> String? {
        let sentence = SentenceCompleter.currentSentence(typed)
        guard sentence.count >= 8, sentence.split(whereSeparator: \.isWhitespace).count >= 2 else { return nil }
        let prefix = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = Set<String>()
        for memory in memories {
            guard memory.count <= 1200, !memory.contains("\n"), !memory.hasSuffix("…"),
                  let range = memory.range(of: prefix, options: [.anchored, .caseInsensitive]),
                  range.upperBound < memory.endIndex else { continue }
            let remaining = String(memory[range.upperBound...])
            // Never complete half a word, even when the name happens to prefix a remembered name.
            guard remaining.first?.isWhitespace == true || remaining.first.map({ ".,!?;:".contains($0) }) == true else { continue }
            let tail = CompletionGate.firstSentence(remaining)
            guard !tail.trimmingCharacters(in: .whitespaces).isEmpty, tail.utf16.count <= 300 else { continue }
            candidates.insert(tail)
        }
        guard candidates.count == 1, var result = candidates.first else { return nil }
        if typed.last?.isWhitespace == true { result = String(result.drop(while: \.isWhitespace)) }
        return result.isEmpty ? nil : result
    }
}
