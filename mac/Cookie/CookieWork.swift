//
//  CookieWork.swift
//  Cookie
//
//  Work, not chats: the things the person is moving forward (a pilot, a
//  renewal, a proposal), each with its next step, who it concerns and where
//  it stands — Needs you, Cookie's on it, Waiting, Done. Kept on this Mac,
//  sealed like the chats, and mirrored to Enkeon as a `plan` memory so every
//  tool the person uses sees the same work (state held/kept, owner, to, due).
//

import Combine
import Foundation

// MARK: - Model

enum WorkColumn: String, Codable, CaseIterable, Identifiable {
    case needsYou, cookie, waiting, done
    var id: String { rawValue }

    var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .cookie: return "Cookie's on it"
        case .waiting: return "Waiting"
        case .done: return "Done"
        }
    }

    /// The plan memory's state and owner for this column (Enkeon `update`).
    /// Yours: your own name. Cookie's: the tool. Waiting: the person it concerns.
    func mirror(to: String?, person: String) -> (state: String, owner: String) {
        switch self {
        case .needsYou: return ("held", person)
        case .cookie: return ("held", "tool:cookie")
        case .waiting: return ("held", to.flatMap { $0.isEmpty ? nil : $0 } ?? "them")
        case .done: return ("kept", person)
        }
    }
}

struct WorkEvent: Codable, Equatable, Identifiable {
    var id = UUID()
    var date = Date()
    let text: String
    /// "you", "cookie" or "enkeon": who moved it.
    var by = "you"
}

struct WorkItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    /// The result that means it's done ("Northwind decides on a team plan").
    var outcome: String = ""
    /// The one next thing to do.
    var nextStep: String = ""
    /// The person or company it concerns.
    var to: String = ""
    var due: Date?
    var column: WorkColumn = .needsYou
    var created = Date()
    var updated = Date()
    var history: [WorkEvent] = []
    /// Files that belong to it (paths on this Mac).
    var files: [String] = []
    /// The chat about this work, once one exists.
    var threadID: UUID?
    /// The Enkeon plan memory it is mirrored to; nil until saved there.
    var memoryID: String?
    /// A change not yet written to Enkeon (offline, signed out).
    var needsSync = true

    /// Days since anything happened on it, for "Waiting · 3 days".
    func age(now: Date = Date()) -> Int {
        max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: updated),
                                               to: Calendar.current.startOfDay(for: now)).day ?? 0)
    }

    func isOverdue(now: Date = Date()) -> Bool {
        guard let due, column != .done else { return false }
        return Calendar.current.startOfDay(for: due) < Calendar.current.startOfDay(for: now)
    }
}

enum WorkText {
    /// "Today", "Tomorrow", "Thu", "17 Oct" — the way a person says a near date.
    static func due(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2..<7: return date.formatted(.dateTime.weekday(.abbreviated))
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    static func age(_ days: Int) -> String {
        switch days {
        case 0: return "today"
        case 1: return "1 day"
        default: return "\(days) days"
        }
    }

    /// The id in Enkeon's `remember`/`update` answer: "… (id 01M4…, v1)".
    static func memoryID(in answer: String) -> String? {
        guard let range = answer.range(of: #"id ([0-9A-HJKMNP-TV-Z]{26})"#, options: .regularExpression) else { return nil }
        return String(answer[range].dropFirst(3))
    }
}

// MARK: - Store

@MainActor
final class WorkStore: ObservableObject {
    /// `--sample-work` swaps in sample work for a look at the screens: held
    /// in memory only, never saved on this Mac, never sent to Enkeon.
    static let shared = CommandLine.arguments.contains("--sample-work") ? WorkStore.sample() : WorkStore()

    @Published private(set) var items: [WorkItem] = []
    /// Why the last write to Enkeon failed, shown quietly; nil when in step.
    @Published private(set) var syncProblem: String?
    fileprivate var replySubscription: AnyCancellable?

    private var file: URL { ChatVault.directory.appendingPathComponent("work.sealed") }

    /// Off in tests: nothing is read from or written to this Mac or Enkeon.
    private let connected: Bool

    init(connected: Bool = true) {
        self.connected = connected
        if connected { load() }
    }

    func items(in column: WorkColumn) -> [WorkItem] {
        items.filter { $0.column == column }.sorted(by: Self.order)
    }

    /// Overdue first, then by due date, then most recently moved.
    static func order(_ a: WorkItem, _ b: WorkItem) -> Bool {
        if a.isOverdue() != b.isOverdue() { return a.isOverdue() }
        switch (a.due, b.due) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.updated > b.updated
        }
    }

    func item(_ id: UUID) -> WorkItem? { items.first { $0.id == id } }

    @discardableResult
    func add(title: String, nextStep: String = "", outcome: String = "", to: String = "", due: Date? = nil,
             column: WorkColumn = .needsYou, by: String = "you") -> WorkItem {
        var item = WorkItem(title: title.trimmingCharacters(in: .whitespacesAndNewlines), outcome: outcome,
                            nextStep: nextStep, to: to, due: due, column: column)
        item.history.append(WorkEvent(text: "Started", by: by))
        items.append(item)
        save()
        sync(item.id)
        return item
    }

    func update(_ id: UUID, by: String = "you", note: String? = nil, _ change: (inout WorkItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        let before = item
        change(&item)
        guard item != before || note != nil else { return }
        if item.column != before.column {
            item.history.append(WorkEvent(text: "Moved to \(item.column.title)", by: by))
        }
        if let note, !note.isEmpty { item.history.append(WorkEvent(text: note, by: by)) }
        item.updated = Date()
        item.needsSync = true
        items[index] = item
        save()
        sync(id)
    }

    func move(_ id: UUID, to column: WorkColumn, by: String = "you") {
        update(id, by: by) { $0.column = column }
    }

    func remove(_ id: UUID) {
        guard let item = item(id) else { return }
        items.removeAll { $0.id == id }
        save()
        // In Enkeon the plan is dropped, not erased: other tools may have read it.
        if connected, let memoryID = item.memoryID {
            Task { _ = try? await EnkeonDirect.shared.update(id: memoryID, state: "dropped", owner: nil, to: nil, due: nil) }
        }
    }

    /// Retry every change Enkeon hasn't got yet (after sign-in, at launch).
    func syncAll() {
        for item in items where item.needsSync { sync(item.id) }
    }

    // MARK: Disk

    private func load() {
        guard let sealed = try? Data(contentsOf: file) else { return }
        do {
            items = try JSONDecoder().decode([WorkItem].self, from: ChatVault.open(sealed))
        } catch {
            // Never overwrite work we couldn't read: set it aside for recovery.
            let aside = ChatVault.directory.appendingPathComponent("work.unreadable-\(Int(Date().timeIntervalSince1970)).sealed")
            try? FileManager.default.moveItem(at: file, to: aside)
            items = []
        }
    }

    private func save() {
        guard connected else { return }
        do {
            try FileManager.default.createDirectory(at: ChatVault.directory, withIntermediateDirectories: true)
            try ChatVault.seal(JSONEncoder().encode(items)).write(to: file, options: .atomic)
        } catch {
            syncProblem = "Couldn't save work on this Mac: \(error.localizedDescription)"
        }
    }

    // MARK: Enkeon

    private func sync(_ id: UUID) {
        guard connected else { return }
        Task {
            guard CookieAccount.shared.isSignedIn, let item = item(id), item.needsSync else { return }
            let person = NSFullUserName().split(separator: " ").first.map(String.init) ?? "me"
            let (state, owner) = item.column.mirror(to: item.to, person: person)
            do {
                if let memoryID = item.memoryID {
                    _ = try await EnkeonDirect.shared.update(id: memoryID, state: state, owner: owner,
                                                             to: item.to.isEmpty ? nil : item.to, due: Self.day(item.due))
                    markSynced(id, memoryID: memoryID)
                } else {
                    let answer = try await EnkeonDirect.shared.rememberPlan(
                        text: Self.planText(item), name: item.title, to: item.to.isEmpty ? nil : item.to,
                        owner: owner, due: Self.day(item.due), acceptance: item.outcome.isEmpty ? nil : item.outcome)
                    guard let memoryID = WorkText.memoryID(in: answer) else {
                        syncProblem = "Enkeon didn't confirm the save."
                        return
                    }
                    if state != "held" {
                        _ = try await EnkeonDirect.shared.update(id: memoryID, state: state, owner: nil, to: nil, due: nil)
                    }
                    markSynced(id, memoryID: memoryID)
                }
            } catch {
                syncProblem = "Not saved to Enkeon yet: \(error.localizedDescription)"
            }
        }
    }

    private func markSynced(_ id: UUID, memoryID: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].memoryID = memoryID
        items[index].needsSync = false
        syncProblem = nil
        save()
    }

    static func planText(_ item: WorkItem) -> String {
        var parts = ["Work: \(item.title)."]
        if !item.to.isEmpty { parts.append("It concerns \(item.to).") }
        if !item.outcome.isEmpty { parts.append("Done when: \(item.outcome).") }
        if !item.nextStep.isEmpty { parts.append("Next step: \(item.nextStep).") }
        return parts.joined(separator: " ")
    }

    static func day(_ date: Date?) -> String? {
        date.map { $0.formatted(.iso8601.year().month().day()) }
    }
}

// MARK: - Enkeon, called directly

/// The person's own app writing their work to Enkeon over MCP (Streamable
/// HTTP), with their sign-in: `remember` and `update` for work items, and
/// `recall` for a meeting's line of prep. The model reaches Enkeon through
/// the harness, never through this.
@MainActor
final class EnkeonDirect {
    static let shared = EnkeonDirect()
    private var session: String?
    private var next = 1

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func rememberPlan(text: String, name: String, to: String?, owner: String?, due: String?, acceptance: String?) async throws -> String {
        try await call("remember", [
            "text": text, "purpose": "Work the person is moving forward in Cookie.", "kind": "plan", "weight": "notable",
            "feeling": NSNull(), "about": to.map { [$0] } ?? NSNull(), "name": name, "updates": NSNull(), "branch": NSNull(),
            "due": due ?? NSNull(), "to": to ?? NSNull(), "owner": owner ?? NSNull(), "resources": NSNull(),
            "depends_on": NSNull(), "acceptance": acceptance ?? NSNull(),
        ])
    }

    /// A preference Cookie learned from how the person edited a draft, filed under that Cookie.
    func rememberCorrection(text: String, agent: String) async throws -> String {
        try await call("remember", [
            "text": text, "purpose": "So \(agent)'s next draft sounds more like the person.", "kind": "preference", "weight": "routine",
            "feeling": NSNull(), "about": [agent, "Cookie"], "name": NSNull(), "updates": NSNull(), "branch": NSNull(),
            "due": NSNull(), "to": NSNull(), "owner": NSNull(), "resources": NSNull(), "depends_on": NSNull(), "acceptance": NSNull(),
        ])
    }

    func recall(query: String) async throws -> String {
        try await call("recall", [
            "query": query, "top_k": 3, "since": NSNull(), "until": NSNull(), "type": NSNull(), "state": NSNull(),
            "workspace": NSNull(), "branch": NSNull(), "budget_tokens": NSNull(), "as_of": NSNull(), "check": NSNull(),
            "folder": NSNull(),
        ])
    }

    func update(id: String, state: String?, owner: String?, to: String?, due: String?) async throws -> String {
        try await call("update", [
            "id": id, "text": NSNull(), "kind": NSNull(), "weight": NSNull(), "feeling": NSNull(), "purpose": NSNull(),
            "name": NSNull(), "state": state ?? NSNull(), "due": due ?? NSNull(), "to": to ?? NSNull(),
            "owner": owner ?? NSNull(), "workspace": NSNull(),
        ])
    }

    private func call(_ tool: String, _ arguments: [String: Any]) async throws -> String {
        for attempt in 0..<2 {
            if session == nil { try await initialize() }
            let (status, body) = try await post(["jsonrpc": "2.0", "id": nextID(), "method": "tools/call",
                                                 "params": ["name": tool, "arguments": arguments]])
            if status == 404, attempt == 0 { session = nil; continue } // the session expired: start a new one
            guard (200...299).contains(status) else { throw Failure(message: "Enkeon answered HTTP \(status)") }
            guard let result = (body["result"] as? [String: Any]) else {
                throw Failure(message: ((body["error"] as? [String: Any])?["message"] as? String) ?? "Enkeon sent no result")
            }
            let text = ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
            if (result["isError"] as? Bool) == true { throw Failure(message: String(text.prefix(200))) }
            return text
        }
        throw Failure(message: "Enkeon's session kept expiring")
    }

    private func initialize() async throws {
        session = nil
        let (status, _) = try await post(["jsonrpc": "2.0", "id": nextID(), "method": "initialize", "params": [
            "protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "cookie-app", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"],
        ]])
        guard (200...299).contains(status), session != nil else { throw Failure(message: "Couldn't open an Enkeon session (HTTP \(status))") }
        _ = try? await post(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    private func nextID() -> Int {
        next += 1
        return next
    }

    private func post(_ message: [String: Any]) async throws -> (Int, [String: Any]) {
        guard let token = await CookieAccount.shared.accessToken() else { throw Failure(message: "Not signed in to Enkeon") }
        var request = URLRequest(url: CookieAccount.issuer.appendingPathComponent("mcp"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        if let id = http?.value(forHTTPHeaderField: "Mcp-Session-Id") { session = id }
        return (http?.statusCode ?? 0, Self.body(data))
    }

    /// A JSON body, or the last `data:` line of an SSE body.
    static func body(_ data: Data) -> [String: Any] {
        let text = String(decoding: data, as: UTF8.self)
        let json = text.contains("data:")
            ? text.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("data:") }).map { String($0.dropFirst(5)) } ?? ""
            : text
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }
}

// MARK: - Cookie takes the next step

extension WorkStore {
    /// What Cookie is asked when it takes a work item's next step.
    static func brief(_ item: WorkItem) -> String {
        var lines = ["Take the next step on this work: \(item.title)."]
        if !item.to.isEmpty { lines.append("It concerns \(item.to).") }
        if !item.outcome.isEmpty { lines.append("It's done when: \(item.outcome).") }
        lines.append("Next step: \(item.nextStep.isEmpty ? "work out the next step and say what it is" : item.nextStep).")
        if !item.files.isEmpty { lines.append("Its files: " + item.files.joined(separator: ", ") + ".") }
        if let due = item.due { lines.append("Due \(due.formatted(date: .abbreviated, time: .omitted)).") }
        lines.append("Recall what we know about it first. Prepare everything you can; anything that sends, pays or deletes waits for my yes. End by saying what you did and what's left for me.")
        return lines.joined(separator: " ")
    }

    /// When Cookie's reply lands in a work item's chat, the item comes back
    /// to the person: Needs you, with what Cookie said as the first line.
    func follow(_ replies: PassthroughSubject<(threadID: UUID, message: CompanionChatMessage), Never>) {
        replySubscription = replies.receive(on: DispatchQueue.main).sink { [weak self] reply in
            guard let self, let item = self.items.first(where: { $0.threadID == reply.threadID && $0.column == .cookie }) else { return }
            let failed = reply.message.role == .failure
            let said = reply.message.text.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? ""
            self.update(item.id, by: "cookie", note: failed ? "Couldn't finish: \(said)" : said) { $0.column = .needsYou }
        }
    }
}

extension CompanionManager {
    /// Cookie works on a work item in its own chat (the same chat each time).
    func startWork(on id: UUID) {
        let store = WorkStore.shared
        guard let item = store.item(id) else { return }
        if let thread = item.threadID, threads.contains(where: { $0.id == thread }) {
            selectThread(thread)
        } else {
            newThread()
        }
        sendTypedMessage(WorkStore.brief(item))
        guard let thread = currentThreadID else { return }
        store.update(id, by: "cookie", note: "Started on the next step") {
            $0.threadID = thread
            $0.column = .cookie
        }
    }
}

// MARK: - Sample work (screens only)

extension WorkStore {
    static func sample(now: Date = Date()) -> WorkStore {
        let store = WorkStore(connected: false)
        func day(_ n: Double) -> Date { now.addingTimeInterval(n * 86_400) }
        func add(_ title: String, _ next: String, to: String, due: Date?, outcome: String = "",
                 column: WorkColumn = .needsYou, notes: [String] = []) {
            let item = store.add(title: title, nextStep: next, outcome: outcome, to: to, due: due)
            for note in notes { store.update(item.id, by: "cookie", note: note) { _ in } }
            if column != .needsYou { store.move(item.id, to: column) }
        }
        add("Northwind team pilot", "Review the follow-up draft and send it", to: "Northwind", due: now,
            outcome: "Northwind decides on a team plan", notes: ["Drafted the recap and the pilot proposal"])
        add("Fabrikam team plan", "Set the price for five seats", to: "Fabrikam", due: day(1),
            outcome: "Fabrikam moves the team onto one plan")
        add("Contoso renewal", "Check usage before the renewal call", to: "Contoso", due: day(-1))
        add("Globex brief", "Read the brief, then reply", to: "Globex", due: day(2),
            notes: ["Wrote a one-page brief from their site"])
        add("Initech pilot", "Research their engineering leads", to: "Initech", due: day(3), column: .cookie)
        add("Umbrella call notes", "Update the deal with today's call", to: "Umbrella", due: nil, column: .cookie)
        add("Hooli free to Pro", "Nudge if no reply by Friday", to: "Hooli", due: day(3), column: .waiting)
        add("Riga intros", "Follow up with whoever replies", to: "Local founders", due: nil, column: .waiting)
        add("Fabrikam Pro", "", to: "Fabrikam", due: nil, column: .done)
        return store
    }
}
