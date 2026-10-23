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
import Vision

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
            guard let text = Self.readText(from: imageData), text.count >= 20 else { return }
            await MainActor.run { self.add(ScreenMemoryEntry(date: date, app: app, text: text)) }
        }
    }

    func add(_ entry: ScreenMemoryEntry) {
        entries.append(entry)
        prune()
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

    nonisolated static func readText(from imageData: Data) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(data: imageData, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
