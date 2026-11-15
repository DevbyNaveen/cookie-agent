//
//  CookieMemoryCursor.swift
//  Cookie
//
//  Memory at your cursor. Hold ⌥⇧ over a name, a ticket, an amount: when the
//  words under the pointer look like something the person's Enkeon could know
//  about, Cookie asks it (the name only, never the sentence round it) and shows
//  up to three dated lines under the cursor. Nothing found, not signed in, or
//  no answer within 1.5 s: no card, and the hover's usual explanation stands.
//

import Foundation

/// Something worth looking up, found in the words under the pointer.
struct CookieEntity: Equatable {
    enum Kind: String { case person, project, number, id }
    let kind: Kind
    /// What goes to Enkeon, and the card's title.
    let text: String

    /// One cache entry per entity, whatever its case or spacing.
    var key: String {
        kind.rawValue + ":" + text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The entity at `index` (UTF-16 offset, as AX and NSString count) in `text`; nil for ordinary words.
    /// Checked in order: an email (its owner), a ticket id, an amount with a currency, a capitalised name.
    static func extract(from text: String, at index: Int) -> CookieEntity? {
        let string = text as NSString
        guard index >= 0, index < string.length else { return nil }
        let found = match(email, in: string, at: index).flatMap(person(fromEmail:))
            ?? match(ticket, in: string, at: index).map { CookieEntity(kind: .id, text: $0) }
            ?? match(amount, in: string, at: index).map { CookieEntity(kind: .number, text: $0) }
            ?? name(in: string, at: index)
        // A card number or a key never leaves the Mac, even as a "name".
        guard let found, SensitiveText.ranges(in: found.text).isEmpty else { return nil }
        return found
    }

    private static let email = regex(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#)
    private static let ticket = regex(#"\b[A-Z][A-Z0-9]{1,9}-\d{1,6}\b|(?<![\w&])#\d{2,7}\b"#)
    private static let amount = regex(#"[€$£¥]\s?\d{1,3}(?:[,.\u00A0 ]\d{3})*(?:[.,]\d+)?(?:\s?(?:[kKmM]|bn)\b)?|\d{1,3}(?:[,.\u00A0 ]\d{3})*(?:[.,]\d+)?\s?(?:[kKmM]\s?)?(?:EUR|USD|GBP|SEK|NOK|DKK|CHF|eur|usd|euros?|dollars?|€|\$|£)(?!\p{L})"#)
    private static let word = regex(#"\p{L}[\p{L}\p{M}'’-]*"#)

    /// Words a capital letter doesn't make a name: sentence starters, days, months, the labels apps put on buttons.
    static let stopWords: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "it", "its", "i", "we", "you", "he", "she", "they", "my", "our",
        "your", "his", "her", "their", "and", "or", "but", "so", "if", "when", "then", "there", "here", "what", "who", "why",
        "how", "where", "which", "yes", "no", "not", "hi", "hello", "hey", "dear", "thanks", "thank", "please", "ok", "okay",
        "re", "fwd", "fw", "cc", "to", "from", "subject", "date", "in", "on", "at", "for", "of", "with", "by", "as", "is", "are",
        "was", "be", "do", "did", "have", "has", "can", "will", "would", "should", "could", "all", "any", "some", "new", "today",
        "tomorrow", "yesterday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january",
        "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "file", "edit", "view", "window", "help", "format", "insert", "tools", "go", "open", "close", "save", "cancel", "done",
        "send", "reply", "forward", "delete", "archive", "inbox", "drafts", "sent", "trash", "settings", "preferences",
        "search", "share", "print", "undo", "redo", "copy", "paste", "cut", "back", "next", "previous", "more", "less", "add",
        "remove", "apply", "submit", "continue", "skip", "home", "menu", "untitled", "note", "notes", "page", "comments",
        // Verbs that open a sentence before a name: "Call Anna", "Ship ThinkingRoot".
        "call", "ask", "email", "meet", "tell", "ping", "see", "check", "ship", "fix", "fixed", "invite", "message", "remind",
        "follow", "let", "get", "make", "talk", "update", "review", "sign", "pay", "book", "join",
    ]

    /// Words that make a capitalised phrase a project rather than a person.
    private static let projectWords: Set<String> = [
        "project", "plan", "launch", "program", "programme", "roadmap", "app", "platform", "team", "initiative", "campaign",
        "release", "sprint", "inc", "ltd", "llc", "gmbh", "corp", "labs", "studio", "group",
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }

    private static func match(_ pattern: NSRegularExpression, in string: NSString, at index: Int) -> String? {
        pattern.matches(in: string as String, range: NSRange(location: 0, length: string.length))
            .first { NSLocationInRange(index, $0.range) }
            .map { string.substring(with: $0.range).trimmingCharacters(in: .whitespaces) }
    }

    /// anna.berzina@acme.com → Anna Berzina; a single-part local name stays as written.
    private static func person(fromEmail address: String) -> CookieEntity? {
        guard let local = address.split(separator: "@").first else { return nil }
        let parts = local.split(whereSeparator: { "._-+".contains($0) })
        let text = parts.count > 1 && parts.allSatisfy({ $0.allSatisfy(\.isLetter) })
            ? parts.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
            : String(local)
        return text.isEmpty ? nil : CookieEntity(kind: .person, text: text)
    }

    /// The capitalised word under the index, grown into the name it belongs to (up to four words).
    private static func name(in string: NSString, at index: Int) -> CookieEntity? {
        let words = word.matches(in: string as String, range: NSRange(location: 0, length: string.length)).map(\.range)
        guard let hovered = words.firstIndex(where: { NSLocationInRange(index, $0) }) else { return nil }
        // "Anna's" is Anna.
        func text(_ i: Int) -> String {
            let word = string.substring(with: words[i])
            return word.hasSuffix("'s") || word.hasSuffix("’s") ? String(word.dropLast(2)) : word
        }
        func isName(_ i: Int) -> Bool {
            let word = text(i)
            guard let first = word.first, first.isUppercase else { return false }
            // "OK", "FILE": the labels apps write in capitals, not names.
            if word.count > 1, word == word.uppercased() { return false }
            return !stopWords.contains(word.lowercased())
        }
        // Neighbours only count when nothing but a space stands between them.
        func joined(_ a: Int, _ b: Int) -> Bool {
            let gap = string.substring(with: NSRange(location: NSMaxRange(words[a]), length: words[b].location - NSMaxRange(words[a])))
            return gap == " " || gap == "\u{00A0}"
        }
        guard isName(hovered) else { return nil }
        var first = hovered, last = hovered
        while last - first < 3, first > 0, joined(first - 1, first), isName(first - 1) { first -= 1 }
        while last - first < 3, last + 1 < words.count, joined(last, last + 1), isName(last + 1) { last += 1 }
        let phrase = (first...last).map(text)

        // One word that opens a sentence is a name only if the text doesn't also use it in lower case
        // ("Meeting moved. The meeting is…").
        if phrase.count == 1 {
            let before = string.substring(to: words[first].location).trimmingCharacters(in: .whitespaces)
            let opensSentence = before.isEmpty || before.last.map { ".!?:\n".contains($0) } == true
            if opensSentence, (string as String).range(of: "\\b\(NSRegularExpression.escapedPattern(for: phrase[0].lowercased()))\\b",
                                                         options: .regularExpression) != nil { return nil }
        }
        let isProject = phrase.contains { word in
            projectWords.contains(word.lowercased()) || word.dropFirst().contains(where: \.isUppercase)
        }
        return CookieEntity(kind: isProject ? .project : .person, text: phrase.joined(separator: " "))
    }
}

/// What Enkeon knows about one entity: up to three lines, each with its date and source when it has them.
struct CookieMemoryCard: Equatable {
    struct Line: Equatable {
        let text: String
        let date: Date?
        /// The app it was synced from ("gmail"), else the memory's id.
        let source: String?
        /// The app it was synced from, when it was.
        let app: String?
    }

    let title: String
    let lines: [Line]

    /// "from Enkeon · gmail · 25 Oct": the newest dated line's app and day.
    var footer: String {
        var parts = ["from Enkeon"]
        if let app = lines.compactMap(\.app).first { parts.append(app) }
        if let date = lines.compactMap(\.date).max() {
            parts.append(date.formatted(.dateTime.day().month(.abbreviated)
                .year(Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? .omitted : .defaultDigits)))
        }
        return parts.joined(separator: " · ")
    }

    /// Enkeon's recall answer (one JSON object, then notes) → the card, keeping only hits that
    /// mention the entity; nil when none do.
    @MainActor static func parse(_ answer: String, about entity: CookieEntity) -> CookieMemoryCard? {
        guard let json = CookieCalendar.leadingJSONObject(answer),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let hits = object["hits"] as? [[String: Any]] else { return nil }
        let lines: [Line] = hits.compactMap { hit in
            guard let statement = (hit["statement"] as? String)?.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces), !statement.isEmpty, mentions(statement, entity) else { return nil }
            let app = (hit["source_uri"] as? String).flatMap(syncedApp)
            return Line(text: firstSentence(statement),
                        date: (hit["valid_from"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                        source: app ?? hit["id"] as? String, app: app)
        }
        return lines.isEmpty ? nil : CookieMemoryCard(title: entity.text, lines: Array(lines.prefix(3)))
    }

    /// Recall returns its best three whatever was asked; a line about someone else isn't shown.
    static func mentions(_ statement: String, _ entity: CookieEntity) -> Bool {
        let folded = statement.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        switch entity.kind {
        case .number:
            // €1,200 and 1200 EUR are the same amount: compare digits.
            let digits = entity.text.filter(\.isNumber)
            return !digits.isEmpty && statement.filter { $0.isNumber || $0 == " " }
                .split(separator: " ").joined().contains(digits)
        case .id:
            return folded.contains(entity.text.folding(options: [.caseInsensitive], locale: nil))
        case .person, .project:
            // Any word of the name will do: "Anna" for Anna Berzina.
            return entity.text.split(separator: " ").contains { part in
                part.count >= 3 && folded.range(of: "\\b\(NSRegularExpression.escapedPattern(for: part.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)))\\b",
                                                options: .regularExpression) != nil
            }
        }
    }

    /// ".../sources/synced/gmail/re--a1b2.md" → gmail; a remembered note names no app.
    private static func syncedApp(_ uri: String) -> String? {
        guard let range = uri.range(of: "sources/synced/") else { return nil }
        let app = uri[range.upperBound...].split(separator: "/").first.map(String.init) ?? ""
        return app.isEmpty ? nil : app
    }

    private static func firstSentence(_ text: String) -> String {
        let sentence = text.range(of: #"[.!?](\s|$)"#, options: .regularExpression).map { String(text[..<$0.upperBound]) } ?? text
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 120 ? String(trimmed.prefix(119)) + "\u{2026}" : trimmed
    }
}

/// Looks entities up in Enkeon for the hover, quickly or not at all.
@MainActor
final class CookieMemoryCursor {
    static let shared = CookieMemoryCursor()
    /// Settings → Shortcuts → Memory at your cursor; on unless turned off.
    static let enabledKey = "cookie.memoryCursor"
    static let cacheFor: TimeInterval = 600
    /// The hover never waits longer than this for a card.
    static let timeout: Double = 1.5

    /// Set by the checks; the app asks Enkeon with the person's sign-in.
    var lookup: @MainActor (String) async throws -> String = { try await EnkeonDirect.shared.recall(query: $0) }
    var signedIn: () -> Bool = { CookieAccount.shared.isSignedIn }
    var now: () -> Date = { Date() }
    var proof = CookieProof.shared
    var defaults = UserDefaults.standard
    /// A card, or nil for "Enkeon had nothing", per entity key.
    private var cache: [String: (at: Date, card: CookieMemoryCard?)] = [:]

    var isOn: Bool { (defaults.object(forKey: Self.enabledKey) as? Bool ?? true) && signedIn() }

    /// The card for an entity, or nil: switched off, not signed in, nothing that mentions it, or too slow.
    func card(for entity: CookieEntity) async -> CookieMemoryCard? {
        guard isOn else { return nil }
        if let kept = cache[entity.key], now().timeIntervalSince(kept.at) < Self.cacheFor { return kept.card }
        proof.record(.sent, feature: "memory cursor", summary: "a \(entity.kind.rawValue) to look up",
                     destination: "Enkeon", bytes: entity.text.utf8.count, payload: .name, count: 1)
        let lookup = self.lookup, query = entity.text
        // A timeout or an error isn't kept: the next hover asks again.
        guard let answer = await withDeadline(seconds: Self.timeout, { try await lookup(query) }) else { return nil }
        let card = CookieMemoryCard.parse(answer, about: entity)
        cache[entity.key] = (now(), card)
        return card
    }
}
