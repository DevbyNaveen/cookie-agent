//
//  CookieCalendar.swift
//  Cookie
//
//  Up next: the person's next meeting from the Mac's own calendars (EventKit,
//  read only, asked for only when they press Connect), with one line of prep:
//  the work it concerns, else the strongest thing Enkeon recalls about it.
//  Nothing about the meeting is written anywhere.
//

import AppKit
import EventKit
import Foundation
import EnkeonVoiceKit

struct UpcomingMeeting: Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let attendees: [String]
}

@MainActor
final class CookieCalendar: ObservableObject {
    static let shared = CookieCalendar()

    enum Access: Equatable { case notAsked, allowed, denied }

    @Published private(set) var access: Access = .notAsked
    @Published private(set) var next: UpcomingMeeting?
    /// One line of prep per meeting id, from Enkeon.
    @Published private(set) var recalled: [String: String] = [:]
    @Published private(set) var pendingBrief: CookieMeetingBrief?

    private let store = EKEventStore()
    private var recalledAt: [String: Date] = [:]
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private let presentedBriefsKey = "cookie.calendar.presentedBriefs"
    private var presentedBriefIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "cookie.calendar.presentedBriefs") ?? [])

    /// How far ahead a meeting counts as "up next".
    static let horizon: TimeInterval = 12 * 3600

    private init() {
        readAccess()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // A 15-second poll keeps the T-2-minute brief within one short tick; a 60-second poll can make it nearly a minute late.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func connect() {
        switch access {
        case .allowed: refresh()
        case .denied:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        case .notAsked:
            NSApp.activate(ignoringOtherApps: true)
            store.requestFullAccessToEvents { [weak self] _, _ in
                Task { @MainActor in
                    self?.readAccess()
                    self?.refresh()
                }
            }
        }
    }

    func refresh() {
        readAccess()
        guard access == .allowed else { next = nil; return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(Self.horizon), calendars: nil)
        let meeting = Self.pick(store.events(matching: predicate).map(Self.meeting), now: now)
        if meeting != next { next = meeting }
        if let meeting {
            recallPrep(for: meeting)
            presentBriefIfDue(for: meeting, now: now)
        }
    }

    func dismissBrief(_ id: String) {
        guard pendingBrief?.meeting.id == id else { return }
        pendingBrief = nil
    }

    private func presentBriefIfDue(for meeting: UpcomingMeeting, now: Date) {
        let presented = CookieMeetingBriefBuilder.presentIfDue(
            access: access, meeting: meeting, now: now,
            alreadyPresented: presentedBriefIDs.contains(meeting.id), pendingBrief: &pendingBrief
        ) { self.makeBrief(for: meeting) }
        guard presented else { return }
        presentedBriefIDs.insert(meeting.id)
        UserDefaults.standard.set(Array(presentedBriefIDs).sorted(), forKey: presentedBriefsKey)
    }

    private func refreshPendingBrief(for meeting: UpcomingMeeting) {
        guard pendingBrief?.meeting.id == meeting.id else { return }
        pendingBrief = makeBrief(for: meeting)
    }

    private func makeBrief(for meeting: UpcomingMeeting) -> CookieMeetingBrief {
        let past = (try? MeetingRepository(directory: MeetingModel.defaultDirectory).loadRecovering().records) ?? []
        return CookieMeetingBriefBuilder.make(meeting: meeting, pastMeetings: past,
                                              work: WorkStore.shared.items, recall: recalled[meeting.id])
    }

    private func readAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .allowed
        case .notDetermined: access = .notAsked
        default: access = .denied
        }
    }

    private static func meeting(_ event: EKEvent) -> (UpcomingMeeting, skip: Bool) {
        let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
        var seenNames = Set<String>()
        let names = (event.attendees ?? []).filter { !$0.isCurrentUser }.compactMap { attendee -> String? in
            guard let name = attendee.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  seenNames.insert(name.lowercased()).inserted else { return nil }
            return name
        }
        let meeting = UpcomingMeeting(id: event.calendarItemIdentifier + "@\(event.startDate.timeIntervalSince1970)",
                                      title: event.title?.isEmpty == false ? event.title! : "Meeting",
                                      start: event.startDate, end: event.endDate, attendees: names)
        return (meeting, event.isAllDay || declined || event.status == .canceled)
    }

    /// The next meeting that hasn't ended: one already running for under
    /// 10 minutes still counts, so a late join still gets its prep.
    static func pick(_ events: [(UpcomingMeeting, skip: Bool)], now: Date) -> UpcomingMeeting? {
        events.filter { !$0.skip && $0.0.end > now && $0.0.start > now.addingTimeInterval(-600) }
            .map(\.0).min { $0.start < $1.start }
    }

    // MARK: Prep from Enkeon

    private func recallPrep(for meeting: UpcomingMeeting) {
        guard CookieAccount.shared.isSignedIn else { return }
        if let at = recalledAt[meeting.id], Date().timeIntervalSince(at) < 1800 { return }
        recalledAt[meeting.id] = Date()
        let query = ([meeting.title] + meeting.attendees.prefix(3)).joined(separator: " ")
        Task {
            guard let answer = try? await EnkeonDirect.shared.recall(query: query) else { return }
            if let line = Self.firstStatement(in: answer) {
                recalled[meeting.id] = line
                refreshPendingBrief(for: meeting)
            }
        }
    }

    /// The first hit's statement, cut to its first sentence. Enkeon's answer is
    /// a JSON object followed by plain-text notes; only the object is read.
    static func firstStatement(in answer: String) -> String? {
        guard let json = leadingJSONObject(answer),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let hit = (object["hits"] as? [[String: Any]])?.first,
              let statement = hit["statement"] as? String else { return nil }
        let flat = statement.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let sentence = flat.range(of: #"[.!?](\s|$)"#, options: .regularExpression).map { String(flat[..<$0.upperBound]) } ?? flat
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 140 ? String(trimmed.prefix(139)) + "\u{2026}" : trimmed
    }

    static func leadingJSONObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let c = text[index]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

enum UpNextText {
    /// "in 12 min", "now", "at 14:30".
    static func when(_ start: Date, now: Date = Date()) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        return "at " + start.formatted(date: .omitted, time: .shortened)
    }

    /// Work that concerns this meeting: its person or company in the title or among the attendees.
    static func work(for meeting: UpcomingMeeting, in items: [WorkItem]) -> WorkItem? {
        let haystack = ([meeting.title] + meeting.attendees).joined(separator: " ").lowercased()
        return items.filter { $0.column != .done && $0.to.count >= 2 }
            .first { haystack.contains($0.to.lowercased()) }
    }
}
