//
//  CookieAgents.swift
//  Cookie
//
//  Named Cookies. Each chat belongs to one: a name, a role, a line about
//  what it does, and a kind (the base brief). Cookie herself ships; the
//  person makes the rest by saying what they want help with.
//

import Foundation

struct CookieAgent: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var role: String
    var detail: String
    var kind: CookieSpecialist
    var builtIn = false
    /// Apps this Cookie answers for when the hotkey is held in them (names as macOS shows them).
    var apps: [String] = []
    /// What it does on repeat.
    var routines: [CookieRoutine] = []

    func answers(forApp name: String?, bundleID: String?) -> Bool {
        let names = [name, bundleID].compactMap { $0?.lowercased() }
        return apps.contains { app in
            let app = app.lowercased()
            return names.contains { $0 == app || $0.hasSuffix("." + app) }
        }
    }

    /// The character Cookie drafted, from the JSON object in its reply. Nil when it didn't answer in kind.
    static func draft(from reply: String, id: UUID) -> CookieAgent? {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close,
              let json = try? JSONSerialization.jsonObject(with: Data(reply[open...close].utf8)) as? [String: Any] else { return nil }
        let name = (json["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return CookieAgent(id: id, name: name,
                           role: (json["role"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                           detail: (json["detail"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                           kind: CookieSpecialist(rawValue: (json["kind"] as? String ?? "").lowercased()) ?? .general)
    }

    /// What the model is told about who it is in this chat.
    var brief: String {
        var lines = ["you are \(name), \(role.lowercased())."]
        if !detail.isEmpty { lines.append(detail) }
        if !kind.brief.isEmpty { lines.append(kind.brief) }
        return lines.joined(separator: " ")
    }
}

/// Something a Cookie does on repeat: an instruction and when.
struct CookieRoutine: Identifiable, Codable, Equatable {
    enum Cadence: Codable, Equatable {
        /// Every day at hour:minute (local time).
        case daily(hour: Int, minute: Int)
        /// Monday to Friday at hour:minute.
        case weekdays(hour: Int, minute: Int)
        /// One weekday (1 = Sunday … 7 = Saturday) at hour:minute.
        case weekly(weekday: Int, hour: Int, minute: Int)
        /// Every N minutes, for watching something.
        case every(minutes: Int)

        var title: String {
            func clock(_ hour: Int, _ minute: Int) -> String {
                let date = Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
                return date.formatted(date: .omitted, time: .shortened)
            }
            switch self {
            case .daily(let hour, let minute): return "Every day at \(clock(hour, minute))"
            case .weekdays(let hour, let minute): return "Weekdays at \(clock(hour, minute))"
            case .weekly(let weekday, let hour, let minute):
                return "Every \(Calendar.current.weekdaySymbols[max(0, min(6, weekday - 1))] ) at \(clock(hour, minute))"
            case .every(let minutes): return minutes < 60 ? "Every \(minutes) min" : minutes == 60 ? "Every hour" : "Every \(minutes / 60) h"
            }
        }

        /// The first run strictly after `date`.
        func next(after date: Date, calendar: Calendar = .current) -> Date {
            switch self {
            case .every(let minutes):
                return date.addingTimeInterval(Double(max(1, minutes)) * 60)
            case .daily(let hour, let minute):
                return calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime) ?? date
            case .weekdays(let hour, let minute):
                var candidate = date
                for _ in 0..<8 {
                    candidate = calendar.nextDate(after: candidate, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime) ?? date
                    let weekday = calendar.component(.weekday, from: candidate)
                    if (2...6).contains(weekday) { return candidate }
                }
                return candidate
            case .weekly(let weekday, let hour, let minute):
                return calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute, weekday: weekday), matchingPolicy: .nextTime) ?? date
            }
        }
    }

    var id = UUID()
    /// What to do, in the person's words ("check what changed with these five companies").
    var instruction: String
    var cadence: Cadence
    /// Watching: only raise a card when this is true ("anyone from Northwind replied"); empty runs every time.
    var onlyWhen: String = ""
    var lastRun: Date?
    var nextRun: Date

    init(instruction: String, cadence: Cadence, onlyWhen: String = "", from date: Date = Date()) {
        self.instruction = instruction
        self.cadence = cadence
        self.onlyWhen = onlyWhen
        self.nextRun = cadence.next(after: date)
    }

    /// One sentence: "every morning, check what changed with these companies, only when something moved".
    /// The cadence words come out; "only when / only if / tell me only when" splits off the condition.
    init?(parsing sentence: String, from date: Date = Date()) {
        guard let cadence = Self.cadence(in: sentence, now: date) else { return nil }
        var text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        var onlyWhen = ""
        for marker in ["tell me only when ", "tell me only if ", "only when ", "only if "] {
            if let range = text.range(of: marker, options: .caseInsensitive) {
                onlyWhen = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
                text = String(text[..<range.lowerBound])
                break
            }
        }
        let cadencePattern = #"(?i)\b(every (morning|day|evening|afternoon|night|hour|weekday|work ?day|\d+ ?(minutes?|mins?|hours?|h)|(sun|mon|tues|wednes|thurs|fri|satur)day)|each morning|daily|hourly|weekdays|(sun|mon|tues|wednes|thurs|fri|satur)days)( at \d{1,2}(:\d{2})? ?(am|pm)?)?\b[,:]?\s*"#
        let instruction = text.replacingOccurrences(of: cadencePattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        guard !instruction.isEmpty else { return nil }
        self.init(instruction: instruction.prefix(1).uppercased() + instruction.dropFirst(), cadence: cadence, onlyWhen: onlyWhen, from: date)
    }

    /// Reads "every morning", "every weekday at 9", "every monday", "every 15 minutes", "every hour". Nil when none fits.
    static func cadence(in text: String, now: Date = Date()) -> Cadence? {
        let words = text.lowercased()
        func clock() -> (Int, Int) {
            if let range = words.range(of: #"\b([01]?\d|2[0-3])(?::([0-5]\d))?\s*(am|pm)?\b"#, options: .regularExpression),
               words[words.startIndex..<range.lowerBound].hasSuffix("at ") {
                let match = words[range]
                let parts = match.replacingOccurrences(of: "am", with: "").replacingOccurrences(of: "pm", with: "")
                    .trimmingCharacters(in: .whitespaces).split(separator: ":")
                var hour = Int(parts.first ?? "9") ?? 9
                let minute = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                if match.contains("pm"), hour < 12 { hour += 12 }
                if match.contains("am"), hour == 12 { hour = 0 }
                return (hour, minute)
            }
            if words.contains("evening") { return (18, 0) }
            if words.contains("afternoon") { return (14, 0) }
            if words.contains("night") { return (21, 0) }
            return (9, 0)
        }
        if let range = words.range(of: #"every (\d+) ?(minutes?|mins?|hours?|h)\b"#, options: .regularExpression) {
            let match = String(words[range])
            let number = Int(match.split(separator: " ")[1].filter(\.isNumber)) ?? 15
            return .every(minutes: match.contains("hour") || match.hasSuffix("h") ? number * 60 : number)
        }
        if words.contains("every hour") || words.contains("hourly") { return .every(minutes: 60) }
        let (hour, minute) = clock()
        for (index, day) in Calendar.current.weekdaySymbols.enumerated() where words.contains("every " + day.lowercased()) || words.contains(day.lowercased() + "s") {
            return .weekly(weekday: index + 1, hour: hour, minute: minute)
        }
        if words.contains("weekday") || words.contains("work day") { return .weekdays(hour: hour, minute: minute) }
        if words.contains("every morning") || words.contains("every day") || words.contains("daily") || words.contains("every evening")
            || words.contains("every afternoon") || words.contains("every night") || words.contains("each morning") {
            return .daily(hour: hour, minute: minute)
        }
        return nil
    }
}

@MainActor
final class CookieAgentStore: ObservableObject {
    static let shared = CookieAgentStore()

    @Published private(set) var agents: [CookieAgent] = []
    @Published private(set) var problem: String?

    /// Off for tests: nothing is read from or written to this Mac.
    private let connected: Bool
    private var file: URL { ChatVault.directory.appendingPathComponent("agents.sealed") }

    init(connected: Bool = true) {
        self.connected = connected
        if connected { load() }
        if agents.isEmpty {
            agents = Self.starters
            save()
        }
    }

    /// Only Cookie ships. Every other Cookie is one the person made.
    static let starters: [CookieAgent] = [
        CookieAgent(name: "Cookie", role: "Your companion", detail: "Answers anything, sees your screen and points at things.", kind: .general, builtIn: true),
    ]

    func agent(_ id: UUID?) -> CookieAgent? {
        guard let id else { return nil }
        return agents.first { $0.id == id }
    }

    /// The Cookie bound to this app, if the person bound one; Cookie herself never binds.
    func agent(forApp name: String?, bundleID: String?) -> CookieAgent? {
        agents.first { !$0.builtIn && $0.answers(forApp: name, bundleID: bundleID) }
    }

    /// The agent a new chat gets for its inferred kind: the first of that kind, else the first of all.
    func agent(for kind: CookieSpecialist) -> CookieAgent {
        agents.first { $0.kind == kind } ?? agents[0]
    }

    func add(_ agent: CookieAgent) {
        guard self.agent(agent.id) == nil else { update(agent); return }
        agents.append(agent)
        save()
    }

    func update(_ agent: CookieAgent) {
        guard let index = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        agents[index] = agent
        save()
    }

    /// Starters stay: a chat always has somewhere to land.
    func remove(_ id: UUID) {
        guard let agent = agent(id), !agent.builtIn else { return }
        agents.removeAll { $0.id == id }
        save()
    }

    // MARK: Disk

    private func load() {
        guard let sealed = try? Data(contentsOf: file) else { return }
        do {
            agents = try JSONDecoder().decode([CookieAgent].self, from: ChatVault.open(sealed))
        } catch {
            let aside = ChatVault.directory.appendingPathComponent("agents.unreadable-\(Int(Date().timeIntervalSince1970)).sealed")
            try? FileManager.default.moveItem(at: file, to: aside)
            problem = "Couldn't open your saved agents; they were set aside, not deleted."
        }
    }

    private func save() {
        guard connected else { return }
        do {
            try FileManager.default.createDirectory(at: ChatVault.directory, withIntermediateDirectories: true)
            try ChatVault.seal(JSONEncoder().encode(agents)).write(to: file, options: .atomic)
            problem = nil
        } catch {
            problem = "Couldn't save agents on this Mac: \(error.localizedDescription)"
        }
    }
}
