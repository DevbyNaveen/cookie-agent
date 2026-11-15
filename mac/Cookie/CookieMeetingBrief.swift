import Foundation
import EnkeonVoiceKit

struct CookieMeetingBriefLine: Equatable, Identifiable {
    let label: String
    let text: String
    let source: String
    var id: String { label + ":" + source }
}

struct CookieMeetingBrief: Equatable {
    let meeting: UpcomingMeeting
    let lines: [CookieMeetingBriefLine]

    var text: String {
        let header = "\(meeting.title) · \(meeting.start.formatted(date: .omitted, time: .shortened))"
        guard !lines.isEmpty else { return header }
        return ([header] + lines.map { "\($0.label): \($0.text) · \($0.source)" }).joined(separator: "\n")
    }

    var noticeMessage: String {
        let header = "\(meeting.title) · \(meeting.start.formatted(date: .omitted, time: .shortened))"
        return ([header] + lines.map { "\($0.label): \($0.text) · \($0.source)" }).joined(separator: "\n")
    }
}

enum CookieMeetingBriefBuilder {
    static let leadTime: TimeInterval = 2 * 60

    static func shouldPresent(access: CookieCalendar.Access, meeting: UpcomingMeeting, now: Date,
                              alreadyPresented: Bool) -> Bool {
        guard access == .allowed, !alreadyPresented else { return false }
        let seconds = meeting.start.timeIntervalSince(now)
        return seconds >= 0 && seconds <= leadTime
    }

    /// Creates the first pending notice at its T-2-minute poll; refreshes use a separate path.
    @discardableResult
    static func presentIfDue(access: CookieCalendar.Access, meeting: UpcomingMeeting, now: Date,
                             alreadyPresented: Bool, pendingBrief: inout CookieMeetingBrief?,
                             makeBrief: () -> CookieMeetingBrief) -> Bool {
        guard shouldPresent(access: access, meeting: meeting, now: now, alreadyPresented: alreadyPresented) else {
            return false
        }
        pendingBrief = makeBrief()
        return true
    }

    static func make(meeting: UpcomingMeeting, pastMeetings: [MeetingRecord], work: [WorkItem],
                     recall: String?) -> CookieMeetingBrief {
        var lines: [CookieMeetingBriefLine] = []
        let attendees = meeting.attendees.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !attendees.isEmpty {
            lines.append(.init(label: "With", text: attendees.prefix(6).joined(separator: ", "), source: "Calendar"))
        }

        let pastPromise = pastMeetings
            .filter({ matches($0, meeting: meeting) })
            .sorted(by: { $0.started > $1.started })
            .compactMap { record -> (MeetingRecord, String)? in
                // Only the user's microphone track can support a claim about what they promised.
                let transcript = record.segments.filter { !$0.isGap && $0.source == "Microphone" }
                    .map(\.text).joined(separator: "\n")
                return MeetingPromises.extract(transcript).first.map { (record, $0) }
            }.first
        if let (past, promise) = pastPromise {
            let boardPromise = work.first { item in
                normalized(item.title) == normalized(String(promise.prefix(90)))
                    && item.history.contains { $0.text == "Promised in a meeting" }
            }
            let date = past.started.formatted(date: .abbreviated, time: .shortened)
            let source = boardPromise == nil ? "Microphone transcript · \(date)" : "Board promise · \(date)"
            lines.append(.init(label: "Promise", text: boardPromise?.title ?? promise, source: source))
        }

        if let item = UpNextText.work(for: meeting, in: work) {
            let detail = item.nextStep.isEmpty ? item.title : "\(item.title) — \(item.nextStep)"
            lines.append(.init(label: "Board", text: detail, source: "Open Board item"))
        }
        if let recall = recall?.trimmingCharacters(in: .whitespacesAndNewlines), !recall.isEmpty {
            lines.append(.init(label: "Recall", text: recall, source: "Enkeon"))
        }
        return CookieMeetingBrief(meeting: meeting, lines: Array(lines.prefix(4)))
    }

    private static func matches(_ record: MeetingRecord, meeting: UpcomingMeeting) -> Bool {
        let titleMatch = normalized(record.title) == normalized(meeting.title)
        let oldNames = Set((record.attendees ?? []).map(normalized))
        let newNames = Set(meeting.attendees.map(normalized))
        return titleMatch || (!oldNames.isEmpty && !newNames.isEmpty && !oldNames.isDisjoint(with: newNames))
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}
