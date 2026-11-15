//
//  CookieScreenMemory.swift
//  Cookie
//
//  What Cookie saw. Each time Cookie looks at the screen for you, the words
//  on it (after the same redaction the picture gets) are kept for a day,
//  sealed on this Mac, so "what was that number on the pricing page an hour
//  ago?" has an answer. The pictures themselves are never saved.
//

import Foundation
import EnkeonVoiceKit

struct ScreenMemoryEntry: Codable, Equatable {
    var date: Date
    var app: String
    var text: String
}

@MainActor
final class CookieScreenMemory: ObservableObject {
    static let shared = CookieScreenMemory()
    static let enabledKey = "cookie.screenMemory"
    static let keep: TimeInterval = 24 * 3600
    static let maxEntries = 300

    static let tool = HarnessRequest.Tool(
        name: "recall_screen",
        description: "What the person had on screen earlier today, as text Cookie read when it last looked (with the time and the app). Use when they ask about something they saw earlier: a number, a name, a page, a message.",
        effect: "read",
        schema: .init(properties: ["query": .init(description: "A few words of what to find.")], required: ["query"]))

    @Published private(set) var entries: [ScreenMemoryEntry] = []
    private let connected: Bool
    private var file: URL { ChatVault.directory.appendingPathComponent("screen-memory.sealed") }

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) == nil || UserDefaults.standard.bool(forKey: enabledKey)
    }

    init(connected: Bool = true) {
        self.connected = connected
        if connected, let sealed = try? Data(contentsOf: file), let plain = try? ChatVault.open(sealed),
           let saved = try? JSONDecoder().decode([ScreenMemoryEntry].self, from: plain) {
            entries = saved
            prune()
        }
    }

    /// Reads the words off a (redacted) screenshot in the background and keeps them.
    func remember(imageData: Data, app: String, date: Date = Date()) {
        guard Self.enabled else { return }
        Task.detached(priority: .utility) {
            guard let text = await Self.readText(from: imageData), text.count >= 20 else { return }
            await MainActor.run { self.add(ScreenMemoryEntry(date: date, app: app, text: text)) }
        }
    }

    func add(_ entry: ScreenMemoryEntry) {
        entries.append(entry)
        prune()
        save()
    }

    /// What was read off the screen in `app` within a minute of `date` (Proof's Forget).
    // ponytail: a read still being OCR'd when you forget lands afterwards; forget again catches it.
    func forget(app: String?, around date: Date) {
        entries.removeAll { abs($0.date.timeIntervalSince(date)) < 60 && (app == nil || $0.app == app) }
        save()
    }

    func forgetAll() {
        entries = []
        save()
    }

    /// The best few entries for the words, newest first among equals.
    func recall(_ query: String, now: Date = Date(), limit: Int = 5) -> [ScreenMemoryEntry] {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
        guard !words.isEmpty else { return Array(entries.suffix(limit).reversed()) }
        return entries
            .map { entry -> (ScreenMemoryEntry, Int) in
                let text = entry.text.lowercased()
                return (entry, words.reduce(0) { $0 + (text.contains($1) ? 1 : 0) })
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.date > $1.0.date }
            .prefix(limit)
            .map(\.0)
    }

    /// The tool's answer: when, where, and the lines that matched.
    func answer(_ query: String, now: Date = Date()) -> String {
        let hits = recall(query, now: now)
        guard !hits.isEmpty else { return "Nothing like that in what Cookie saw today." }
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
        return hits.map { entry in
            let minutes = Int(now.timeIntervalSince(entry.date) / 60)
            let when = minutes < 1 ? "just now" : minutes < 60 ? "\(minutes) min ago" : "\(minutes / 60) h ago"
            let lines = entry.text.split(separator: "\n").map(String.init)
            let matching = lines.filter { line in words.contains { line.lowercased().contains($0) } }.prefix(6)
            let shown: [String] = matching.isEmpty ? Array(lines.prefix(6)) : Array(matching)
            return "\(when) in \(entry.app):\n" + shown.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.keep)
        entries.removeAll { $0.date < cutoff }
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }

    private func save() {
        guard connected else { return }
        do {
            try FileManager.default.createDirectory(at: ChatVault.directory, withIntermediateDirectories: true)
            try ChatVault.seal(JSONEncoder().encode(entries)).write(to: file, options: .atomic)
        } catch {
            print("⚠️ Cookie: couldn't save what it saw: \(error)")
        }
    }

    nonisolated static func readText(from imageData: Data) async -> String? {
        guard let image = CookieVisionText.image(from: imageData),
              let lines = try? await CookieVisionText.lines(in: image), !lines.isEmpty else { return nil }
        return lines.map(\.text).joined(separator: "\n")
    }
}


/// Searches only data Cookie already has because the person explicitly asked it to look,
/// recorded a meeting, or used Cookie chat. It never captures the current screen or runs in the background.
@MainActor
enum CookieHistorySearch {
    private struct Match {
        let date: Date
        let source: String
        let text: String
        let score: Int
    }

    static let tool = HarnessRequest.Tool(
        name: "search_cookie_history",
        description: "Search the person's locally kept Cookie chats, user-started meeting transcripts, and on-demand screen text when they ask what they saw or heard earlier. This never captures the current screen or records continuously. Return exact source and time, distinguish missing sources from no matches, and never guess.",
        effect: "read",
        schema: .init(properties: ["query": .init(description: "The topic, name, phrase, or time such as 'pricing last Tuesday' or 'what was I doing?'")], required: ["query"]))

    private static let stopWords: Set<String> = [
        "what", "was", "were", "where", "when", "who", "why", "how", "did", "does", "do", "say", "said",
        "doing", "that", "this", "it", "they", "them", "he", "she", "guy", "person", "about", "the", "a", "an",
        "and", "or", "to", "of", "in", "on", "for", "at", "with", "my", "your", "we", "i", "me", "is", "are",
        "last", "this", "week", "today", "yesterday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"
    ]

    static func answer(_ rawQuery: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        let query = String(rawQuery.prefix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "Say what topic or moment to search for." }
        let lower = query.lowercased()
        let continuity = ["what was i doing", "where did i leave off", "what was i working on"].contains { lower.contains($0) }
        let requestedRange = timeRange(in: lower, now: now, calendar: calendar)
        let recentRange = continuity && requestedRange == nil
            ? DateInterval(start: now.addingTimeInterval(-20 * 60), end: now.addingTimeInterval(1))
            : nil
        let range = requestedRange ?? recentRange
        let terms = Set(tokens(query).filter { !stopWords.contains($0) })
        guard continuity || !terms.isEmpty || requestedRange != nil else {
            return "Add a topic, name, or time phrase so I can search your saved Cookie history."
        }

        var matches: [Match] = []
        var unavailable: [String] = []
        if CookieScreenMemory.enabled {
            for entry in CookieScreenMemory.shared.entries {
                append(date: entry.date, source: "Screen · \(entry.app)", text: entry.text,
                       terms: terms, range: range, to: &matches)
            }
        } else {
            unavailable.append("On-demand screen memory is off.")
        }

        do {
            let meetings = try MeetingRepository(directory: MeetingModel.defaultDirectory).loadRecovering()
            if meetings.unreadable > 0 { unavailable.append("\(meetings.unreadable) meeting record(s) could not be read.") }
            for meeting in meetings.records {
                for segment in meeting.segments where !segment.isGap && !segment.text.isEmpty {
                    let date = meeting.started.addingTimeInterval(segment.start)
                    append(date: date, source: "Meeting · \(meeting.title) · \(segment.timestamp)", text: segment.text,
                           terms: terms, range: range, to: &matches)
                }
            }
        } catch {
            unavailable.append("Meeting history could not be opened; those records were left untouched.")
        }

        do {
            for thread in try CookieThreadStore.loadForSearch() {
                for message in thread.messages where message.role == .user || message.role == .assistant {
                    guard !message.text.isEmpty else { continue }
                    let role = message.role == .user ? "You" : "Cookie"
                    append(date: message.date, source: "Chat · \(thread.title) · \(role)", text: message.text,
                           terms: terms, range: range, to: &matches)
                }
            }
        } catch {
            unavailable.append("Saved chats could not be opened; they were left untouched.")
        }

        let ranked = matches.sorted { $0.score == $1.score ? $0.date > $1.date : $0.score > $1.score }.prefix(8)
        let header = "Local Cookie history only. No background screen recording is used."
        guard !ranked.isEmpty else {
            return Self.noMatchText(continuity: continuity, unavailable: unavailable)
        }
        let items = ranked.map { match in
            "• \(match.date.formatted(date: .abbreviated, time: .shortened)) — \(match.source)\n  \(excerpt(match.text, terms: terms))"
        }.joined(separator: "\n")
        let missing = unavailable.isEmpty ? "" : "\nSome sources were unavailable: " + unavailable.joined(separator: " ")
        return "\(header)\n\(items)\(missing)"
    }

    private static func append(date: Date, source: String, text: String, terms: Set<String>, range: DateInterval?, to matches: inout [Match]) {
        if let range, !(date >= range.start && date < range.end) { return }
        let score = terms.isEmpty ? 1 : Set(tokens(source + " " + text)).intersection(terms).count
        guard score > 0 else { return }
        matches.append(Match(date: date, source: source, text: text, score: score))
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func excerpt(_ text: String, terms: Set<String>) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let line = lines.max { left, right in
            Set(tokens(left)).intersection(terms).count < Set(tokens(right)).intersection(terms).count
        } ?? text
        let characters = Array(line)
        guard characters.count > 380 else { return line }
        let lower = line.lowercased()
        let matchOffset = terms.compactMap { term -> Int? in
            guard let found = lower.range(of: term) else { return nil }
            return lower.distance(from: lower.startIndex, to: found.lowerBound)
        }.min() ?? 0
        let start = max(0, matchOffset - 120)
        let end = min(characters.count, start + 380)
        return (start > 0 ? "…" : "") + String(characters[start..<end]) + (end < characters.count ? "…" : "")
    }

    static func noMatchText(continuity: Bool, unavailable: [String]) -> String {
        let window = continuity ? " in the last 20 minutes" : ""
        let missing = unavailable.isEmpty ? "" : " " + unavailable.joined(separator: " ")
        return "Local Cookie history only. No match\(window) in the searchable saved history.\(missing)"
    }

    static func timeRange(in query: String, now: Date, calendar: Calendar) -> DateInterval? {
        let query = query.lowercased()
        if query.contains("last 20 minutes") || query.contains("past 20 minutes") {
            return DateInterval(start: now.addingTimeInterval(-20 * 60), end: now.addingTimeInterval(1))
        }
        if query.contains("yesterday") {
            guard let day = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
            return dayInterval(day, calendar: calendar)
        }
        if query.contains("today") { return dayInterval(now, calendar: calendar) }
        if query.contains("last week"), let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now),
           let previousStart = calendar.date(byAdding: .day, value: -7, to: currentWeek.start) {
            return DateInterval(start: previousStart, end: currentWeek.start)
        }
        let weekdays: [(String, Int)] = [("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4),
                                         ("thursday", 5), ("friday", 6), ("saturday", 7)]
        for (name, weekday) in weekdays where query.contains("last \(name)") {
            let today = calendar.startOfDay(for: now)
            let currentWeekday = calendar.component(.weekday, from: today)
            let daysBack = (currentWeekday - weekday + 7) % 7
            let strictDaysBack = daysBack == 0 ? 7 : daysBack
            guard let day = calendar.date(byAdding: .day, value: -strictDaysBack, to: today) else { return nil }
            return dayInterval(day, calendar: calendar)
        }
        return nil
    }

    private static func dayInterval(_ date: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }
}
