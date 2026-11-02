import Foundation

/// Say a snippet's cue and its text goes in instead; a memory snippet fills in what Enkeon holds now.
public struct Snippet: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case text, memory }
    public var id = UUID()
    public var cue: String
    public var kind: Kind
    /// The text to insert, or (memory) what to look up.
    public var body: String

    public init(id: UUID = UUID(), cue: String, kind: Kind, body: String) {
        self.id = id; self.cue = cue; self.kind = kind; self.body = body
    }
}


/// What a dictation asks for: a snippet whose cue is the whole dictation, or a memory lookup.
public enum SnippetRequest: Equatable, Sendable {
    case snippet(Snippet)
    case memory(query: String)

    /// "from memory <what>" (or "insert from memory <what>") fills in the strongest memory on <what>.
    static let memoryPrefixes = ["insert from memory ", "from memory "]

    public static func find(in transcript: String, snippets: [Snippet]) -> SnippetRequest? {
        let said = normalized(transcript)
        if let prefix = memoryPrefixes.first(where: { said.hasPrefix($0) }) {
            let query = String(said.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return query.isEmpty ? nil : .memory(query: query)
        }
        if let snippet = snippets.first(where: { normalized($0.cue) == said && !said.isEmpty }) { return .snippet(snippet) }
        return nil
    }

    /// Words as heard, lowercased, without punctuation or a leading "insert".
    static func normalized(_ text: String) -> String {
        var words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(.whitespaces))
            .joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if words.hasPrefix("insert "), !memoryPrefixes.contains(where: { words.hasPrefix($0) }) { words.removeFirst(7) }
        return words
    }
}
