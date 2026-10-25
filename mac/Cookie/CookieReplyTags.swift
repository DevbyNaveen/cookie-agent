//
//  CookieReplyTags.swift
//  Cookie
//
//  The tags a reply carries inline ([DRAW:…], [READ:…], [FOCUS:…], [POINT:…], [NEXT:…], [CARD {…}],
//  [SCENE {…}]), each
//  kept with the place it sat in the words. The words without the tags are
//  exactly what the voice speaks, so a tag's place is a place on the speech
//  clock: a mark written after "this cell" draws as "this cell" is said.
//

import Foundation

/// One tag from a reply, and where it sat in the spoken text.
struct CookieReplyTag: Equatable {
    /// The tag's name, as written: "DRAW", "READ", "FOCUS", "POINT", "NEXT", "CARD", "SCENE", "LOOK".
    let kind: String
    /// Everything after "KIND:" up to the closing bracket, or the JSON object after "KIND ".
    let body: String
    /// UTF-16 offset in the spoken text (`CookieSpeechClock` units) where the tag sat.
    let offset: Int
}

enum CookieReplyTags {
    /// The tags a reply may carry. A tag is "[KIND:body]", or "[KIND {json}]" when its body is
    /// a JSON object (brackets inside JSON strings are fine). A new kind is one more name here
    /// plus a reader for its body.
    static let kinds = ["NEXT", "DRAW", "READ", "FOCUS", "POINT", "CARD", "SCENE", "LOOK", "TEACH", "VISUAL", "WORK"]

    /// Splits a reply into the words to speak and its tags, in order.
    ///
    /// Spaces left doubled where a tag was are closed up, a space a tag leaves before
    /// punctuation goes, and the ends are trimmed; each tag's offset is in that final text.
    /// A tag that never closes, and anything after it, is left out (a half-written tag
    /// mid-stream, or a reply cut off). With `streaming`, an unclosed "[" of any kind is left
    /// out too, so a tag never flashes on screen half-typed.
    static func split(_ text: String, kinds: [String] = kinds, streaming: Bool = false) -> (spoken: String, tags: [CookieReplyTag]) {
        var spoken = ""
        var tags: [CookieReplyTag] = []
        var index = text.startIndex
        scan: while index < text.endIndex {
            let character = text[index]
            if character == "[" {
                switch tag(in: text, at: index, kinds: kinds) {
                case .incomplete:
                    break scan
                case .tag(let kind, let body, let next):
                    index = next
                    // "this [DRAW:…] ." reads "this." and "this [DRAW:…] cell" reads "this cell".
                    var after = index
                    while after < text.endIndex, text[after] == " " || text[after] == "\t" { after = text.index(after: after) }
                    if after < text.endIndex, ".,;:!?)".contains(text[after]) {
                        while let last = spoken.last, last == " " || last == "\t" { spoken.removeLast() }
                        index = after
                    } else if spoken.isEmpty || spoken.last == " " || spoken.last == "\t" || spoken.last?.isNewline == true {
                        index = after
                    }
                    tags.append(CookieReplyTag(kind: kind, body: body, offset: spoken.utf16.count))
                    continue scan
                case .none:
                    if streaming, text[index...].firstIndex(of: "]") == nil { break scan }
                }
            }
            if !(spoken.isEmpty && character.isWhitespace) { spoken.append(character) }
            index = text.index(after: index)
        }
        while let last = spoken.last, last.isWhitespace { spoken.removeLast() }
        let end = spoken.utf16.count
        return (spoken, tags.map { $0.offset > end ? CookieReplyTag(kind: $0.kind, body: $0.body, offset: end) : $0 })
    }

    private enum Found {
        case none
        case incomplete
        case tag(kind: String, body: String, next: String.Index)
    }

    /// A known tag starting at `start` (which holds "[").
    private static func tag(in text: String, at start: String.Index, kinds: [String]) -> Found {
        let rest = text[text.index(after: start)...]
        guard let kind = kinds.first(where: { rest.hasPrefix($0) }) else {
            // "[DR" at the very end may still become a tag.
            return kinds.contains(where: { $0.hasPrefix(rest) }) ? .incomplete : .none
        }
        let afterKind = rest.index(rest.startIndex, offsetBy: kind.count)
        guard afterKind < text.endIndex else { return .incomplete }
        switch text[afterKind] {
        case ":":
            let bodyStart = text.index(after: afterKind)
            guard let close = text[bodyStart...].firstIndex(of: "]") else { return .incomplete }
            return .tag(kind: kind, body: String(text[bodyStart..<close]), next: text.index(after: close))
        case " ":
            // [KIND {json}]: the object ends where its braces balance, outside strings.
            var index = text.index(after: afterKind)
            while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
            guard index < text.endIndex else { return .incomplete }
            guard text[index] == "{" else { return .none }
            let bodyStart = index
            var depth = 0, inString = false, escaped = false
            while index < text.endIndex {
                let character = text[index]
                if inString {
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                } else if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let bodyEnd = text.index(after: index)
                        var close = bodyEnd
                        while close < text.endIndex, text[close].isWhitespace { close = text.index(after: close) }
                        guard close < text.endIndex else { return .incomplete }
                        guard text[close] == "]" else { return .none }
                        return .tag(kind: kind, body: String(text[bodyStart..<bodyEnd]), next: text.index(after: close))
                    }
                }
                index = text.index(after: index)
            }
            return .incomplete
        default:
            return .none
        }
    }
}
