//
//  CookieAPI.swift
//  Cookie
//
//  One Cookie, wherever it runs. The Board's jobs, drafts, approvals,
//  routines and follow-ups, and Cookie's settings, go through the routes
//  Cookie's web page uses (/v1/projects/{p}/cookie/…): Enkeon's gateway when
//  the person is signed in (docs: cookie-mac-api.md in the gateway repo),
//  else `cookie page` (src/page.rs), which the app starts from its bundled
//  helper on 127.0.0.1 the first time it is needed and stops when it quits.
//  Nothing else differs, so the Mac's Board and the web page's are one list.
//

import AppKit
import Combine
import Foundation

@MainActor
final class CookieAPI: ObservableObject {
    static let shared = CookieAPI()

    // MARK: What the board reads (the page's `CookieOverview`, the parts the Mac shows)

    struct Overview: Decodable {
        var enabled: Bool?
        var runs: [Run] = []
        var waiting: [Draft] = []
        var approvals: [Approval]?
        var routines: [Routine]?
        var chases: [Chase]?
        var viewer: Viewer?
    }

    struct Viewer: Decodable {
        var prefs: Prefs?
    }

    /// When Cookie's notices reach the person; Enkeon replaces all of it on each PUT.
    struct Prefs: Codable, Equatable {
        var notices = true
        var tz_offset_min = 0
        var tz: String?
        var quiet_from = 22
        var quiet_to = 7
    }

    struct Run: Decodable, Identifiable, Equatable {
        let id: String
        let trigger: String
        let subject: String
        let status: String
        let delivery: String?
        let answer: String?
        let questions: String?
        let started_at: String
        let queued: Bool?
        let mine: Bool?
        var isWorking: Bool { status == "running" }
    }

    struct Draft: Decodable, Identifiable, Equatable {
        let id: String
        let run_id: String
        let to: [String]
        let subject: String
        let body: String
    }

    struct Approval: Decodable, Identifiable, Equatable {
        let id: String
        let slug: String
        let tool: String
        let status: String
        let detail: String?
    }

    struct Routine: Decodable, Identifiable, Equatable {
        let id: String
        let job: String
        /// `daily` | `weekly` | `hourly`.
        let cadence: String
        /// 1 = Monday … 7 = Sunday.
        let weekday: Int
        let hour: Int
        let minute: Int
        /// `offered` | `active` | `paused`.
        let state: String
        let next_run_at: String?

        var when: String {
            let clock = Calendar.current.date(from: DateComponents(hour: hour, minute: minute)).map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
            switch cadence {
            case "hourly": return "Every hour at :\(String(format: "%02d", minute))"
            case "weekly": return "Every \(CookieRoutineWords.dayName(weekday)) at \(clock)"
            default: return "Every day at \(clock)"
            }
        }
    }

    struct Chase: Decodable, Identifiable, Equatable {
        let id: String
        let run_id: String
        let about: String
        /// pending | waiting | nudged | replied | stopped | done
        let state: String
        let to: [String]
        var isOpen: Bool { ["pending", "waiting", "nudged"].contains(state) }
    }

    /// `GET /v1/cookie/session` (Enkeon only).
    struct Session: Decodable {
        let project_id: String
        let enabled: Bool
        let speech: Bool
    }

    /// Something on the board that waits for the person.
    struct Need: Identifiable, Equatable {
        enum Kind: Equatable { case draft(Draft), approval(Approval), asked(Run), offer(Routine) }
        let kind: Kind
        var id: String {
            switch kind {
            case .draft(let d): return "draft-" + d.id
            case .approval(let a): return "approval-" + a.id
            case .asked(let r): return "asked-" + r.id
            case .offer(let r): return "offer-" + r.id
            }
        }
        var title: String {
            switch kind {
            case .draft(let d): return d.subject.isEmpty ? "A reply to \(d.to.joined(separator: ", "))" : d.subject
            case .approval(let a): return "\(a.slug.capitalized): \(a.tool.replacingOccurrences(of: "_", with: " ").lowercased())"
            case .asked(let r): return r.subject.isEmpty ? "Cookie has a question" : r.subject
            case .offer(let r): return r.job
            }
        }
        var detail: String {
            switch kind {
            case .draft(let d): return "Draft to \(d.to.joined(separator: ", ")) · send, skip or take over"
            case .approval(let a): return a.detail.flatMap { $0.split(separator: "\n").first.map(String.init) } ?? "Waiting for your yes"
            case .asked(let r): return r.questions.flatMap { $0.split(separator: "\n").first.map(String.init) } ?? "Cookie asked before starting"
            case .offer(let r): return "\(r.when) · Cookie offers to make it a routine"
            }
        }
    }

    @Published private(set) var overview: Overview?
    /// The answer so far of each job being watched live.
    @Published private(set) var live: [String: String] = [:]
    /// Why the last request failed, in the person's words; nil when fine.
    @Published private(set) var problem: String?
    /// Enkeon refused the sign-in for Cookie: the person signs in again.
    @Published private(set) var needsSignIn = false
    @Published private(set) var session: Session?

    private var watching: Set<String> = []
    private var zoneSent = false
    private var accountChange: AnyCancellable?
    let localPage = LocalCookiePage()

    private init() {
        accountChange = CookieAccount.shared.$phase.removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                self?.overview = nil
                self?.session = nil
                self?.needsSignIn = false
                self?.zoneSent = false
                await self?.refresh()
            }
        }
    }

    /// Drafts, approvals, questions and routine offers, oldest question first.
    var needs: [Need] {
        guard let overview else { return [] }
        let drafts = overview.waiting.map { Need(kind: .draft($0)) }
        let approvals = (overview.approvals ?? []).filter { $0.status == "pending" }.map { Need(kind: .approval($0)) }
        let asked = overview.runs.filter { $0.delivery == "asked" && $0.mine != false }.map { Need(kind: .asked($0)) }
        let offers = (overview.routines ?? []).filter { $0.state == "offered" }.map { Need(kind: .offer($0)) }
        return drafts + approvals + asked + offers
    }

    var working: [Run] { overview?.runs.filter(\.isWorking) ?? [] }
    var finished: [Run] { overview?.runs.filter { !$0.isWorking && $0.delivery != "asked" }.prefix(8).map { $0 } ?? [] }
    var openChases: [Chase] { overview?.chases?.filter(\.isOpen) ?? [] }
    var routines: [Routine] { overview?.routines?.filter { $0.state != "offered" } ?? [] }

    // MARK: Calls

    /// For the notch peek: reads the board when doing so starts nothing (signed
    /// in, or this Mac's page already running), so a hover never launches a helper.
    func refreshIfRunning() {
        guard CookieAccount.shared.isSignedIn || localPage.isRunning else { return }
        Task { await refresh() }
    }

    func refresh() async {
        do {
            overview = try JSONDecoder().decode(Overview.self, from: try await call("GET", ""))
            problem = nil
            for run in working { watch(run.id) }
            // Once a launch: the person's zone, so routines and quiet hours follow their clock.
            if !zoneSent {
                zoneSent = true
                await sendTimeZone()
            }
        } catch {
            show(error)
        }
    }

    /// Gives Cookie a job (`answers`: the run whose questions these words answer); its run id.
    @discardableResult
    func give(_ text: String, conversation: String? = nil, answers: String? = nil) async throws -> String {
        var body: [String: Any] = ["text": text]
        if let conversation { body["conversation"] = conversation }
        if let answers { body["answers"] = answers }
        struct Started: Decodable { let run_id: String }
        let started = try JSONDecoder().decode(Started.self, from: try await call("POST", "/jobs", body))
        watch(started.run_id)
        await refresh()
        return started.run_id
    }

    func stop(_ runID: String) async { await act("POST", "/runs/\(runID)/stop") }
    func draft(_ id: String, _ action: String) async { await act("POST", "/drafts/\(id)", ["action": action]) }
    func approve(_ id: String, _ yes: Bool) async { await act("POST", "/approvals/\(id)", ["approve": yes]) }
    func routine(_ id: String, _ action: String) async { await act("POST", "/routines/\(id)", ["action": action]) }
    func stopChase(_ id: String) async { await act("POST", "/chases/\(id)/stop") }

    /// A routine the person asked for (`weekday` 1 = Monday). Enkeon has no route
    /// for one made from the app yet; it answers 404/405 and the person is told.
    func makeRoutine(job: String, cadence: String, weekday: Int, hour: Int, minute: Int) async throws {
        do {
            _ = try await call("POST", "/routines", ["job": job, "cadence": cadence, "weekday": weekday, "hour": hour, "minute": minute])
        } catch let failure as Failure where CookieAccount.shared.isSignedIn && [404, 405].contains(failure.status) {
            throw Failure(status: failure.status, code: failure.code, message: "Enkeon doesn't take routines from the app yet. Ask on Cookie's page in the Console, or give the job a few times and Cookie offers one.")
        }
    }

    /// The person's zone, so routines and quiet hours follow their clock.
    func sendTimeZone() async {
        if overview == nil { await refresh() }
        let zone = TimeZone.current
        let current = overview?.viewer?.prefs ?? Prefs()
        var prefs = current
        prefs.tz = zone.identifier
        prefs.tz_offset_min = zone.secondsFromGMT() / 60
        guard prefs != current || overview?.viewer?.prefs == nil else { return }
        await act("PUT", "/prefs", ["notices": prefs.notices, "tz": zone.identifier, "tz_offset_min": prefs.tz_offset_min,
                                    "quiet_from": prefs.quiet_from, "quiet_to": prefs.quiet_to], refreshAfter: true)
    }

    /// The SOUL. Enkeon keeps the team's in the Console (the app gets 403); on this Mac it is the person's own.
    func setSoul(_ text: String) async throws {
        _ = try await call("PUT", "/soul", ["text": text])
    }

    /// Enkeon's session for this sign-in: whether Cookie is on and Enkeon's voice is set up.
    @discardableResult
    func loadSession() async -> Session? {
        guard CookieAccount.shared.isSignedIn else { session = nil; return nil }
        if let session { return session }
        do {
            session = try JSONDecoder().decode(Session.self, from: try await call("GET", "/v1/cookie/session", absolute: true))
        } catch {
            show(error)
        }
        return session
    }

    /// Enkeon's voice: ElevenLabs' with-timestamps answer, as CookieSpeaker decodes it.
    func speech(_ text: String, voice: String?) async throws -> Data {
        var body: [String: Any] = ["text": text]
        if let voice { body["voice"] = voice }
        return try await call("POST", "/speech", body, timeout: 30)
    }

    private func act(_ method: String, _ path: String, _ body: [String: Any]? = nil, refreshAfter: Bool = true) async {
        do {
            _ = try await call(method, path, body)
            if refreshAfter { await refresh() }
        } catch {
            show(error)
        }
    }

    // MARK: Live

    /// Follows one job's stream (a one-use ticket, which both backends take)
    /// until its last frame, then reads the board again.
    func watch(_ runID: String) {
        guard !watching.contains(runID) else { return }
        watching.insert(runID)
        Task {
            defer {
                watching.remove(runID)
                live[runID] = nil
            }
            do {
                let (base, project, token) = try await backend()
                let path = "/v1/projects/\(project)/cookie/runs/\(runID)/stream"
                struct Ticket: Decodable { let ticket: String }
                let ticket = try JSONDecoder().decode(Ticket.self, from: try await send("POST", base.appendingPathComponent("v1/stream-tickets"),
                                                                                       ["path": path, "method": "GET"], token: token, timeout: 15))
                var components = URLComponents(url: base.appendingPathComponent(String(path.dropFirst())), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "ticket", value: ticket.ticket)]
                var request = URLRequest(url: components.url!)
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 300
                let (bytes, _) = try await URLSession.shared.bytes(for: request)
                struct Frame: Decodable { let text: String; let done: Bool }
                for try await line in bytes.lines where line.hasPrefix("data:") {
                    guard let frame = try? JSONDecoder().decode(Frame.self, from: Data(line.dropFirst(5).utf8)) else { continue }
                    live[runID] = frame.text
                    if frame.done { break }
                }
            } catch {
                // A dropped stream loses only the live words; the board below has the record.
            }
            await refresh()
        }
    }

    // MARK: HTTP

    struct Failure: LocalizedError {
        let status: Int
        let code: String
        let message: String
        var errorDescription: String? { message }
    }

    /// Where Cookie answers now: Enkeon when signed in, else the page on this Mac.
    private func backend() async throws -> (base: URL, project: String, token: String?) {
        if CookieAccount.shared.isSignedIn {
            guard let token = await CookieAccount.shared.accessToken() else {
                throw Failure(status: 401, code: "cookie_sign_in", message: "Your Enkeon sign-in ended. Sign in again in Settings → Account.")
            }
            guard let project = CookieAccount.shared.projectID else {
                throw Failure(status: 401, code: "cookie_sign_in", message: "Sign in to Enkeon again so Cookie knows your project.")
            }
            return (CookieAccount.issuer, project, token)
        }
        let port = try await localPage.ensure()
        return (URL(string: "http://127.0.0.1:\(port)")!, "local", nil)
    }

    /// One request under `/v1/projects/{p}/cookie` (or `absolute`, a path from the root).
    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, absolute: Bool = false,
                      timeout: TimeInterval = 20) async throws -> Data {
        let (base, project, token) = try await backend()
        let full = absolute ? path : "/v1/projects/\(project)/cookie" + path
        return try await send(method, base.appendingPathComponent(String(full.dropFirst())), body, token: token, timeout: timeout)
    }

    private func send(_ method: String, _ url: URL, _ body: [String: Any]?, token: String?, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("desktop", forHTTPHeaderField: "x-tr-client")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else { throw failure(status: status, data: data) }
        return data
    }

    /// The error body (`{"error": {"code", "message"}}`), acted on where the contract says to.
    private func failure(status: Int, data: Data) -> Failure {
        struct Body: Decodable { struct E: Decodable { let code: String; let message: String }; let error: E }
        let parsed = try? JSONDecoder().decode(Body.self, from: data)
        let code = parsed?.error.code ?? ""
        let message = parsed?.error.message ?? "Cookie answered HTTP \(status)."
        switch code {
        case "cookie_scope", "cookie_sign_in":
            needsSignIn = true
            return Failure(status: status, code: code, message: "Sign in to Enkeon again to let Cookie use your board (Settings → Account).")
        case "cookie_not_member":
            CookieAccount.shared.signOut()
            return Failure(status: status, code: code, message: "You're no longer on this Enkeon project, so Cookie signed out of it.")
        case "payment_required":
            return Failure(status: status, code: code, message: "Cookie's credits for this month are used up.")
        default:
            return Failure(status: status, code: code, message: message)
        }
    }

    private func show(_ error: Error) {
        problem = error.localizedDescription
    }
}

// MARK: - Cookie's page on this Mac

/// `cookie page` from the app's own helper, for a person not signed in to
/// Enkeon: started the first time the board needs it, on a free port on
/// 127.0.0.1, with the model and keys the chats use; restarted when they
/// change; stopped when Cookie quits. It reads the web and the files in
/// Application Support/Cookie/page/files (read only), and keeps its jobs,
/// routines and SOUL in Application Support/Cookie/page.
@MainActor
final class LocalCookiePage {
    private var process: Process?
    private var port = 0
    private var environmentInUse: [String: String]?
    private var stderrTail = ""
    private var quitObserver: NSObjectProtocol?

    static var home: URL { ChatVault.directory.appendingPathComponent("page", isDirectory: true) }

    var isRunning: Bool { process?.isRunning == true }

    func ensure() async throws -> Int {
        let model = CookieModelSettings.model
        if let missing = CookieModelSettings.missing(model: model) { throw failure(missing) }
        let environment = CookieModelSettings.helperEnvironment(model: model, enkeonKey: await CookieModelSettings.enkeonKey())
        if let process, process.isRunning, environment == environmentInUse { return port }
        stop()
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cookie")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw failure("Cookie's helper is missing from the app (Contents/Helpers/cookie). Rebuild Cookie with ./build.sh.")
        }
        let files = Self.home.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let port = try Self.freePort()
        let process = Process()
        process.executableURL = helper
        process.arguments = ["page", files.path, "--model", model, "--home", Self.home.path, "--port", String(port)]
        process.environment = environment
        // Its own folder, so `--page` never finds a stray web/out.
        process.currentDirectoryURL = Self.home
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        stderrTail = ""
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.stderrTail = String((self.stderrTail + String(decoding: data, as: UTF8.self)).suffix(600))
                }
            }
        }
        do { try process.run() } catch {
            throw failure("Cookie couldn't start its page: \(error.localizedDescription)")
        }
        self.process = process
        self.port = port
        environmentInUse = environment
        if quitObserver == nil {
            quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        }
        // Ready when it answers; a helper that exits says why on stderr.
        let who = URL(string: "http://127.0.0.1:\(port)/api/cookie/who")!
        for _ in 0..<80 {
            if !process.isRunning { break }
            if let (_, response) = try? await URLSession.shared.data(from: who), (response as? HTTPURLResponse)?.statusCode == 200 { return port }
            try await Task.sleep(for: .milliseconds(100))
        }
        let why = stderrTail.split(separator: "\n").last.map { ": \($0)" } ?? ""
        stop()
        throw failure("Cookie's page on this Mac didn't start\(why)")
    }

    func stop() {
        process?.terminate()
        process = nil
        environmentInUse = nil
    }

    private func failure(_ message: String) -> CookieAPI.Failure {
        CookieAPI.Failure(status: 0, code: "local", message: message)
    }

    /// A port nothing listens on now: bound to 0, read, released. Another
    /// program could take it in the moment between; the start then fails and says so.
    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CookieAPI.Failure(status: 0, code: "local", message: "No free port for Cookie's page.") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound else { throw CookieAPI.Failure(status: 0, code: "local", message: "No free port for Cookie's page.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

// MARK: - Routines by voice

/// "every Tuesday and Thursday at 5, clean up my inbox": the model reads the
/// days and the time from the person's words and calls `make_routine`; the
/// card says exactly what will repeat, and a yes makes one routine per day
/// through the API (Enkeon's routines are one weekday each).
@MainActor
enum CookieRoutineWords {
    static let tool = HarnessRequest.Tool(
        name: "make_routine",
        description: "Make a routine: a job Cookie does again on a schedule, when the person asks for one (\"every Tuesday and Thursday at 5, clean up my inbox\"). The person sees the schedule and says yes first. It shows on the Board under Routines, where they can pause it.",
        effect: "outbound",
        guard: ["job"],
        schema: .init(properties: [
            "job": .init(description: "What to do each time, in the person's own words exactly as they said them, without the schedule: \"clean up my inbox\"."),
            "days": .init(description: "Which days: weekday names joined by commas (\"Tuesday, Thursday\"), \"every day\", \"weekdays\", or \"every hour\"."),
            "time": .init(description: "The time, 24-hour HH:MM on the person's clock. \"at 5\" for an inbox or a report means 17:00; ask when it could be either."),
        ], required: ["job", "days", "time"]),
        parallel_safe: false)

    /// Mondays as 1, as the API counts.
    nonisolated static let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    nonisolated static func dayName(_ weekday: Int) -> String {
        days[max(0, min(6, weekday - 1))].capitalized
    }

    struct Plan: Equatable {
        let job: String
        /// `daily`, `hourly`, or `weekly` on `weekdays`.
        let cadence: String
        let weekdays: [Int]
        let hour: Int
        let minute: Int

        var sentence: String {
            let clock = Calendar.current.date(from: DateComponents(hour: hour, minute: minute)).map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
            switch cadence {
            case "hourly": return "Every hour: \(job)"
            case "daily": return "Every day at \(clock): \(job)"
            default:
                let names = weekdays.map(dayName)
                let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names.first ?? ""
                return "Every \(list) at \(clock): \(job)"
            }
        }
    }

    /// The tool's arguments as a plan; nil when the days or time don't read.
    static func plan(_ args: [String: Any]) -> Plan? {
        let job = (args["job"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let words = (args["days"] as? String ?? "").lowercased()
        let time = (args["time"] as? String ?? "").split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !job.isEmpty, let hour = time.first, (0...23).contains(hour) else { return nil }
        let minute = time.count > 1 ? time[1] : 0
        guard (0...59).contains(minute) else { return nil }
        if words.contains("hour") { return Plan(job: job, cadence: "hourly", weekdays: [], hour: hour, minute: minute) }
        if words.contains("every day") || words.contains("daily") { return Plan(job: job, cadence: "daily", weekdays: [], hour: hour, minute: minute) }
        let picked = words.contains("weekday") ? Array(1...5) : days.indices.filter { words.contains(days[$0]) }.map { $0 + 1 }
        guard !picked.isEmpty else { return nil }
        return picked.count == 7 ? Plan(job: job, cadence: "daily", weekdays: [], hour: hour, minute: minute)
            : Plan(job: job, cadence: "weekly", weekdays: picked, hour: hour, minute: minute)
    }

    static func question(for action: HarnessAction) -> String? {
        guard action.tool == tool.name else { return nil }
        return plan(MacOperator.args(of: action)).map { "Make a routine? \($0.sentence)" } ?? "Make a routine?"
    }

    /// After the yes: one routine per day. The answer the model reads, and whether it failed.
    static func perform(_ args: [String: Any]) async -> (String, Bool) {
        guard let plan = plan(args) else {
            return ("make_routine needs a job, days (weekday names, \"every day\", \"weekdays\" or \"every hour\") and a time as HH:MM.", true)
        }
        let api = CookieAPI.shared
        await api.sendTimeZone()
        var made: [String] = []
        do {
            for weekday in plan.cadence == "weekly" ? plan.weekdays : [1] {
                try await api.makeRoutine(job: plan.job, cadence: plan.cadence, weekday: weekday, hour: plan.hour, minute: plan.minute)
                made.append(dayName(weekday))
            }
        } catch {
            await api.refresh()
            let part = made.isEmpty ? "" : " (only \(made.joined(separator: " and ")) was made)"
            return ("The routine wasn't made\(part): \(error.localizedDescription)", true)
        }
        await api.refresh()
        return ("Made: \(plan.sentence). It's on the Board under Routines, where it can be paused.", false)
    }
}
