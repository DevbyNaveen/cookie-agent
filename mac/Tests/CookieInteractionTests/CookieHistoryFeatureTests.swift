import AppKit
import EnkeonVoiceKit

@MainActor
enum CookieHistoryFeatureTests {
    static func run() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-11-11T12:00:00Z")!
        let recent = CookieHistorySearch.timeRange(in: "pricing last 20 minutes", now: now, calendar: calendar)!
        precondition(recent.start == now.addingTimeInterval(-20 * 60))
        precondition(recent.end == now.addingTimeInterval(1))
        let lastTuesday = CookieHistorySearch.timeRange(in: "what did I decide last Tuesday", now: now, calendar: calendar)!
        precondition(calendar.component(.day, from: lastTuesday.start) == 10)
        precondition(CookieHistorySearch.noMatchText(continuity: true, unavailable: [])
            == "Local Cookie history only. No match in the last 20 minutes in the searchable saved history.")
        precondition(CookieHistorySearch.noMatchText(continuity: false, unavailable: ["Chats are locked."])
            .contains("No match in the searchable saved history. Chats are locked."))

        let records = [
            DictationRecord(date: now, app: "Mail", text: "one two three four five six seven eight nine ten",
                            outcome: .inserted, durationSeconds: 60),
            DictationRecord(date: now.addingTimeInterval(60), app: "Slack", text: "alpha beta gamma delta epsilon zeta",
                            outcome: .inserted, durationSeconds: 60),
            DictationRecord(date: now, app: "Mail", text: String(repeating: "undone ", count: 100),
                            outcome: .undone, durationSeconds: 60),
            DictationRecord(date: now.addingTimeInterval(-8 * 86_400), app: "Mail", text: "outside the week",
                            outcome: .inserted, durationSeconds: 60)
        ]
        let summary = CookieWeeklySummary.calculate(records: records, now: now, calendar: calendar)
        precondition(summary.words == 16 && summary.dictations == 2 && summary.activeDays == 1)
        precondition(summary.averageWordsPerMinute == 8)

        let learned = Corrections.learned(typed: "Hello Halverson", edited: "Hello Halvorsen", isMisspelled: { $0 == "Halvorsen" })
        precondition(learned == ["Halvorsen"])
        precondition(Corrections.learned(typed: "TEAM meeting", edited: "Team meeting", isMisspelled: { _ in true }).isEmpty)

        let original = DictationRecord(id: UUID(), date: now, app: "Mail", text: "Meet Friday",
                                       outcome: .inserted, durationSeconds: 4, bundleID: "com.apple.mail")
        let corrected = DictationCorrectionHistory.correctedRecord(original, text: "Meet Tuesday", app: "Mail",
                                                                  bundleID: "com.apple.mail", duration: 2)
        precondition(corrected.id == original.id && corrected.text == "Meet Tuesday")
        precondition(DictationCorrectionHistory.restoreAfterUndo(original) == original)
        print("10 history and dictation checks passed.")
    }
}
