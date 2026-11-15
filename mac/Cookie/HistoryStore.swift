import EnkeonVoiceKit
import Foundation

struct CookieWeeklySummary: Equatable {
    let weekStarting: Date
    let words: Int
    let dictations: Int
    let activeDays: Int
    let averageWordsPerMinute: Int?

    static func calculate(records: [DictationRecord], now: Date = Date(), calendar: Calendar = .current) -> Self {
        let interval = calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 7 * 86_400)
        let kept = records.filter { $0.outcome != .undone && $0.date >= interval.start && $0.date < interval.end }
        let words = kept.reduce(0) { $0 + $1.wordCount }
        let timed = kept.filter { $0.durationSeconds >= 1 }
        let seconds = timed.reduce(0) { $0 + $1.durationSeconds }
        let wordsPerMinute = seconds > 0 ? Int((Double(timed.reduce(0) { $0 + $1.wordCount }) * 60 / seconds).rounded()) : nil
        let activeDays = Set(kept.map { calendar.startOfDay(for: $0.date) }).count
        return Self(weekStarting: interval.start, words: words, dictations: kept.count,
                    activeDays: activeDays, averageWordsPerMinute: wordsPerMinute)
    }
}

/// Every finished dictation, on this Mac only: ~/Library/Application Support/Enkeon/history.json.
/// Turned off in Settings, nothing is written and what was kept is deleted.
@MainActor
final class HistoryStore: ObservableObject {
    static let enabledKey = "enkeon.history.enabled"
    /// ponytail: one JSON file rewritten per dictation; a database when history grows past this.
    static let limit = 2_000

    @Published private(set) var records: [DictationRecord] = []

    let file: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Enkeon", isDirectory: true)
        file = base.appendingPathComponent("history.json")
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        guard isEnabled else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder.history.decode([DictationRecord].self, from: data) {
            records = Array(saved.prefix(Self.limit))
        }
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func add(_ record: DictationRecord) {
        guard isEnabled else { return }
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
        save()
    }

    func delete(_ record: DictationRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func clear() {
        records = []
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: Numbers for Home, from the records themselves

    var totalWords: Int { records.filter { $0.outcome != .undone }.reduce(0) { $0 + $1.wordCount } }

    /// Words per minute over dictations long enough to measure; nil when there are none.
    var wordsPerMinute: Int? {
        let timed = records.filter { $0.outcome != .undone && $0.durationSeconds >= 1 }
        let minutes = timed.reduce(0) { $0 + $1.durationSeconds } / 60
        guard minutes > 0 else { return nil }
        return Int((Double(timed.reduce(0) { $0 + $1.wordCount }) / minutes).rounded())
    }

    /// Consecutive days with a dictation, ending today or yesterday.
    var dayStreak: Int {
        let calendar = Calendar.current
        let days = Set(records.map { calendar.startOfDay(for: $0.date) })
        var day = calendar.startOfDay(for: Date())
        if !days.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var streak = 0
        while days.contains(day) {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    /// Words dictated on each of the last `days` days, oldest first.
    func wordsPerDay(days: Int = 14) -> [Double] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var totals = [Date: Int]()
        for record in records where record.outcome != .undone {
            totals[calendar.startOfDay(for: record.date), default: 0] += record.wordCount
        }
        return (0..<days).reversed().map { offset in
            Double(totals[calendar.date(byAdding: .day, value: -offset, to: today)!] ?? 0)
        }
    }

    /// Dictations on each of the last `days` days, oldest first.
    func dictationsPerDay(days: Int = 14) -> [Double] {
        perDay(days) { _ in 1 }
    }

    /// Whether there was a dictation on each of the last `days` days, oldest first.
    func activeDays(_ days: Int = 7) -> [Bool] { dictationsPerDay(days: days).map { $0 > 0 } }

    /// Notes saved to Enkeon in the last seven days.
    var notesThisWeek: Int {
        let since = Date().addingTimeInterval(-7 * 86_400)
        return records.filter { $0.outcome == .remembered && $0.date >= since }.count
    }

    /// A calendar-week summary from this Mac's kept dictation history. It makes no typing-time claim.
    func weeklySummary(now: Date = Date(), calendar: Calendar = .current) -> CookieWeeklySummary {
        CookieWeeklySummary.calculate(records: records, now: now, calendar: calendar)
    }

    private func perDay(_ days: Int, _ value: (DictationRecord) -> Double) -> [Double] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var totals = [Date: Double]()
        for record in records where record.outcome != .undone {
            totals[calendar.startOfDay(for: record.date), default: 0] += value(record)
        }
        return (0..<days).reversed().map { totals[calendar.date(byAdding: .day, value: -$0, to: today)!] ?? 0 }
    }

    /// The apps dictated into most, with how many dictations each.
    func topApps(limit: Int = 5) -> [(app: String, count: Int, bundleID: String?)] {
        let kept = records.filter { $0.outcome != .undone }
        let counts = Dictionary(grouping: kept, by: \.app).mapValues(\.count)
        let bundles = Dictionary(kept.compactMap { r in r.bundleID.map { (r.app, $0) } }, uniquingKeysWith: { first, _ in first })
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map { ($0.key, $0.value, bundles[$0.key]) }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.history.encode(records).write(to: file, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            print("⚠️ History: couldn't save (\(error.localizedDescription))")
        }
    }
}

private extension JSONEncoder {
    static let history: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let history: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
