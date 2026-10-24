//
//  HarnessClient.swift
//  Cookie
//
//  Cookie thinks through the bundled `cookie serve` helper
//  (Contents/Helpers/cookie, from this repo's core). One helper process for
//  the app's life, one run at a time, JSON lines both ways
//  (HarnessProtocol.swift). The helper holds no state Cookie needs: if it
//  dies it is started again on the next message, and the person is told.
//

import AppKit
import Foundation

// MARK: - Model settings

/// Which model Cookie thinks with (`provider:model`, no default), the
/// credentials for it and the Enkeon key. Secrets live in the Keychain and
/// are handed only to the helper's environment.
enum CookieModelSettings {
    static let modelKey = "cookie.model"
    static let enkeonEnabledKey = "cookie.enkeon.enabled"
    private static let keychainService = "com.enkeon.cookie.provider-keys"

    /// One credential: the variable the helper reads it from, a label, and
    /// whether a reply can't happen without it.
    struct Field: Hashable {
        let variable: String
        let label: String
        var secret = true
        var required = true
    }

    struct Provider {
        let name: String
        let title: String
        let fields: [Field]
        /// Said under the fields.
        let note: String
    }

    /// Providers the bundled helper can reach (built with `--features bedrock`).
    static let providers: [Provider] = [
        Provider(name: "anthropic", title: "Anthropic", fields: [Field(variable: "ANTHROPIC_API_KEY", label: "API key")], note: ""),
        Provider(name: "openai", title: "OpenAI", fields: [Field(variable: "OPENAI_API_KEY", label: "API key")], note: ""),
        Provider(name: "gemini", title: "Gemini", fields: [Field(variable: "GEMINI_API_KEY", label: "API key")], note: ""),
        Provider(name: "bedrock", title: "Amazon Bedrock", fields: [
            Field(variable: "AWS_ACCESS_KEY_ID", label: "Access key ID"),
            Field(variable: "AWS_SECRET_ACCESS_KEY", label: "Secret access key"),
            // Read by src/providers/bedrock.rs `from_env`: the session token only for temporary credentials.
            Field(variable: "AWS_SESSION_TOKEN", label: "Session token", required: false),
            Field(variable: "AWS_REGION", label: "Region", secret: false, required: false),
        ], note: "Session token only for temporary credentials. Region only for a model id without an eu. or us. inference profile (eu. is called in eu-central-1, us. in us-east-1), for example eu-north-1."),
        Provider(name: "ollama", title: "Ollama", fields: [], note: "None needed — Ollama runs on this Mac."),
    ]

    static let enkeonField = Field(variable: "ENKEON_API_KEY", label: "Enkeon key")
    /// Optional: spoken replies through ElevenLabs. Read by CookieSpeaker only, never given to the helper.
    static let elevenLabsField = Field(variable: "ELEVENLABS_API_KEY", label: "ElevenLabs key", required: false)

    static var model: String {
        (UserDefaults.standard.string(forKey: modelKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func provider(of model: String) -> Provider? {
        guard let colon = model.firstIndex(of: ":") else { return nil }
        let name = model[..<colon].lowercased()
        return providers.first { $0.name == name }
    }

    /// Keychain accounts are the variable names: one value per variable.
    static func value(_ field: Field) -> String? {
        (try? CookieKeychain.read(service: keychainService, account: field.variable))
            .flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    static func setValue(_ value: String, for field: Field) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            CookieKeychain.delete(service: keychainService, account: field.variable)
        } else {
            try CookieKeychain.set(Data(trimmed.utf8), service: keychainService, account: field.variable)
        }
    }

    /// The Enkeon switch; on unless turned off.
    static var enkeonEnabled: Bool { UserDefaults.standard.object(forKey: enkeonEnabledKey) as? Bool ?? true }

    /// What lets the helper reach Enkeon this run: your sign-in (renewed if
    /// needed), else a key you pasted; nil when switched off or neither. Nil
    /// sends `"enkeon": false`, so nothing else on the Mac decides.
    @MainActor
    static func enkeonKey() async -> String? {
        guard enkeonEnabled else { return nil }
        if let token = await CookieAccount.shared.accessToken() { return token }
        return value(enkeonField)
    }

    /// What has to be set before Cookie can answer, in the person's words; nil when ready.
    static func missing(model: String = model) -> String? {
        if model.isEmpty {
            return "Choose a model first: Settings → Voice → Model, for example anthropic:claude-sonnet-4-6 or ollama:qwen3."
        }
        let parts = model.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, !parts[1].isEmpty else {
            return "\"\(model)\" isn't a model Cookie can use. Write it as provider:model, for example anthropic:claude-sonnet-4-6."
        }
        guard let provider = provider(of: model) else {
            return "Cookie can't reach \(parts[0]). Use anthropic, openai, gemini, bedrock or ollama."
        }
        let absent = provider.fields.filter { $0.required && value($0) == nil }.map(\.label)
        if !absent.isEmpty {
            return "Add your \(provider.title) \(absent.joined(separator: " and ").lowercased()) in Settings → Voice → Model."
        }
        return nil
    }

    /// The helper's whole environment: nothing inherited from whoever launched
    /// Cookie, so no stray key (ENKEON_API_KEY included) reaches it unasked.
    static func helperEnvironment(model: String = model, enkeonKey: String?) -> [String: String] {
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
        ]
        for field in provider(of: model)?.fields ?? [] {
            if let value = value(field) { environment[field.variable] = value }
        }
        if let enkeonKey { environment[enkeonField.variable] = enkeonKey }
        // Tools and Cookie's instructions stay in the model's prompt cache for an hour, not five
        // minutes: a person asks now and again, and a cached prefix is a faster first word
        // (src/provider.rs `prefix_cache_ttl`; models that can't keep it an hour ignore it).
        environment["COOKIE_PROMPT_CACHE_TTL"] = "1h"
        // Screenshots go at exactly the size the model reads (CookieImageSize): with Anthropic's
        // API a resize is then refused instead of silently moving every coordinate. (Bedrock's
        // Converse has no such option; there the sizing alone keeps them unresized.)
        environment["COOKIE_SCREEN_IMAGES_EXACT"] = "1"
        return environment
    }
}

// MARK: - Client

/// Something the model wants to do that needs a yes from the person.
/// One thing Cookie wants to do that needs a yes.
struct HarnessAction: Equatable {
    let tool: String
    let effect: String
    let preview: String
    let reason: String
    /// Values the person didn't write (`to = …`); the card says so, and
    /// nothing answers it for them.
    var fromData: [String] = []
}

/// What the harness puts to the person: one action, or every action of a
/// turn on one card (serve.rs `items`), answered one by one.
struct HarnessApproval: Equatable {
    let id: String
    let actions: [HarnessAction]

    init(id: String, actions: [HarnessAction]) {
        self.id = id
        self.actions = actions
    }

    /// One action, the usual case.
    init(id: String, tool: String, effect: String, preview: String, reason: String, fromData: [String] = []) {
        self.init(id: id, actions: [HarnessAction(tool: tool, effect: effect, preview: preview, reason: reason, fromData: fromData)])
    }

    /// From an `approval` line; nil without an id or with an empty batch.
    init?(line: HarnessLine) {
        guard let id = line.id else { return nil }
        if let items = line.items {
            guard !items.isEmpty else { return nil }
            self.init(id: id, actions: items.map {
                HarnessAction(tool: $0.tool ?? "", effect: $0.effect ?? "", preview: $0.preview ?? "",
                              reason: $0.reason ?? "", fromData: $0.from_data ?? [])
            })
        } else {
            self.init(id: id, tool: line.tool ?? "", effect: line.effect ?? "", preview: line.preview ?? "",
                      reason: line.reason ?? "", fromData: line.fromData ?? [])
        }
    }

    /// Ticked to start: what you named. Unticked: what Cookie found and you didn't write.
    var startingAnswers: [Bool] { actions.map { $0.fromData.isEmpty } }
}

@MainActor
final class HarnessClient {
    struct HarnessFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct ActiveRun {
        let id: String
        var text = ""
        /// A tool round started since the last words: the next words begin a new sentence.
        var afterTool = false
        let onText: (String) -> Void
        let onToolStarted: () -> Void
        let onStep: (String) -> Void
        let onApproval: (HarnessApproval?) -> Void
        let continuation: CheckedContinuation<String, Error>
    }

    private var process: Process?
    private var input: FileHandle?
    private var environmentInUse: [String: String]?
    /// Bumped per launch; lines and exits from an older helper are ignored.
    private var generation = 0
    private var expectedExit = false
    private var stderrTail = ""
    private var active: ActiveRun?
    /// The helper takes one run at a time; a run it is still ending (after a
    /// cancel) blocks the next, which waits here.
    private var helperBusy = false
    private var queued: Data?
    /// Said with the next reply when the helper had to be started again.
    private(set) var restartNote: String?
    private var runCounter = 0

    init() {
        // A write to a helper that just died must fail, not kill Cookie.
        signal(SIGPIPE, SIG_IGN)
    }

    /// Runs one question. Throws HarnessFailure with words for the person,
    /// or CancellationError when the caller's task was cancelled.
    func run(model: String, input text: String, instructions: String, images: [HarnessRequest.Image],
             history: [HarnessRequest.Turn],
             onText: @escaping (String) -> Void,
             onStep: @escaping (String) -> Void,
             onApproval: @escaping (HarnessApproval?) -> Void,
             onToolStarted: @escaping () -> Void = {}) async throws -> String {
        let enkeonKey = await CookieModelSettings.enkeonKey()
        try ensureRunning(environment: CookieModelSettings.helperEnvironment(model: model, enkeonKey: enkeonKey))
        runCounter += 1
        let request = HarnessRequest.Run(
            id: "cookie-\(runCounter)", model: model, input: text, instructions: instructions,
            // open, and the Mac tools: acting needs a task the person approved.
            tools: [CookieOpen.tool, CookieHandoff.tool, CookieScreenMemory.tool, CookieRoutineWords.tool] + MacOperator.tools,
            images: images,
            history: history,
            // On: left out, so the helper uses ENKEON_API_KEY from its environment.
            enkeon: enkeonKey == nil ? false : nil
        )
        return try await start(id: request.id, line: HarnessWire.encode(request),
                               onText: onText, onStep: onStep, onApproval: onApproval, onToolStarted: onToolStarted)
    }

    /// A run is coming (the talk key went down): the helper is started if it isn't, with the
    /// environment the run will use (a different one would restart it and lose the warm
    /// connection), and asked to open its connection to the model's host now, so the TCP and TLS
    /// handshakes overlap the person's speech instead of delaying the first word.
    func warm(model: String) async {
        guard CookieModelSettings.missing(model: model) == nil else { return }
        let enkeonKey = await CookieModelSettings.enkeonKey()
        do {
            try ensureRunning(environment: CookieModelSettings.helperEnvironment(model: model, enkeonKey: enkeonKey))
        } catch {
            return
        }
        runCounter += 1
        send(HarnessWire.encode(HarnessRequest.Warm(id: "warm-\(runCounter)", model: model)))
    }

    /// One quick answer: no tools, no Enkeon, one model call (hover to explain). `onText` gets the
    /// answer so far as it streams.
    func ask(model: String, input text: String, instructions: String, images: [HarnessRequest.Image],
             onText: @escaping (String) -> Void) async throws -> String {
        try ensureRunning(environment: CookieModelSettings.helperEnvironment(model: model, enkeonKey: nil))
        runCounter += 1
        let request = HarnessRequest.Ask(id: "cookie-\(runCounter)", model: model, input: text,
                                         instructions: instructions, images: images)
        return try await start(id: request.id, line: HarnessWire.encode(request),
                               onText: onText, onStep: { _ in }, onApproval: { _ in })
    }

    private func start(id: String, line: Data,
                       onText: @escaping (String) -> Void,
                       onStep: @escaping (String) -> Void,
                       onApproval: @escaping (HarnessApproval?) -> Void,
                       onToolStarted: @escaping () -> Void = {}) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                cancel() // one run at a time: an older one still going ends here
                active = ActiveRun(id: id, onText: onText, onToolStarted: onToolStarted, onStep: onStep,
                                   onApproval: onApproval, continuation: continuation)
                if Task.isCancelled { cancel(); return }
                if helperBusy { queued = line } else { send(line); helperBusy = true }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    func approve(_ approval: HarnessApproval, allow: Bool) {
        approve(approval, answers: Array(repeating: allow, count: approval.actions.count))
    }

    /// One answer per action, in order; a short list is padded with no.
    func approve(_ approval: HarnessApproval, answers: [Bool]) {
        active?.onApproval(nil)
        let padded = approval.actions.indices.map { $0 < answers.count && answers[$0] }
        send(HarnessWire.encode(HarnessRequest.approve(id: approval.id, answers: padded)))
    }

    /// Stops the run now (only `id`, when given). Anything it was waiting on
    /// is answered "no" by the helper.
    func cancel(_ id: String? = nil) {
        guard let run = active, id == nil || run.id == id else { return }
        active = nil
        if queued != nil { queued = nil } else { send(HarnessWire.encode(HarnessRequest.Cancel())) }
        run.onApproval(nil)
        run.continuation.resume(throwing: CancellationError())
    }

    /// Ends the run and its helper: for a client that lives only as long as one background run.
    func shutdown() {
        cancel()
        expectedExit = true
        process?.terminate()
        process = nil
    }

    // MARK: Process

    private func ensureRunning(environment: [String: String]) throws {
        if let process, process.isRunning {
            guard environment != environmentInUse, active == nil else { return }
            // A new key or provider: the helper reads them once, at launch.
            expectedExit = true
            process.terminate()
            self.process = nil
        }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cookie")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw HarnessFailure(message: "Cookie's helper is missing from the app (Contents/Helpers/cookie). Rebuild Cookie with ./build.sh.")
        }
        generation += 1
        let launched = generation
        expectedExit = false
        stderrTail = ""
        helperBusy = false
        queued = nil

        let process = Process()
        process.executableURL = url
        process.arguments = ["serve"]
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let reader = LineReader()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let lines = reader.buffer.append(data).compactMap(HarnessWire.decode)
            // The main queue keeps lines in the order they arrived.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for line in lines { self.handle(line, from: launched) }
                }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard launched == self.generation else { return }
                    self.stderrTail = String((self.stderrTail + String(decoding: data, as: UTF8.self)).suffix(600))
                }
            }
        }
        process.terminationHandler = { ended in
            let status = ended.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.helperExited(status: status, generation: launched) }
            }
        }
        do {
            try process.run()
        } catch {
            throw HarnessFailure(message: "Cookie couldn't start its helper: \(error.localizedDescription)")
        }
        self.process = process
        self.input = stdin.fileHandleForWriting
        environmentInUse = environment
        print("🧩 Cookie helper started (pid \(process.processIdentifier))")
    }

    private func helperExited(status: Int32, generation launched: Int) {
        guard launched == generation else { return }
        process = nil
        input = nil
        helperBusy = false
        queued = nil
        if expectedExit { return }
        let detail = stderrTail.split(separator: "\n").last.map { ": \($0)" } ?? ""
        let what = "Cookie's helper stopped unexpectedly (exit \(status))\(detail)"
        print("⚠️ \(what)")
        if let run = active {
            active = nil
            run.onApproval(nil)
            run.continuation.resume(throwing: HarnessFailure(message: "\(what). It starts again with your next message."))
        } else {
            restartNote = "Started Cookie's helper again — it had stopped (exit \(status))"
        }
    }

    /// Hands over the restart note once, for the reply that follows it.
    func takeRestartNote() -> String? {
        defer { restartNote = nil }
        return restartNote
    }

    private func send(_ line: Data) {
        guard let input else { return }
        do {
            try input.write(contentsOf: line)
        } catch {
            // The exit handler reports the dead helper; nothing else to do here.
            print("⚠️ Cookie helper: write failed: \(error.localizedDescription)")
        }
    }

    // MARK: Lines

    private func handle(_ line: HarnessLine, from launched: Int) {
        guard launched == generation else { return }
        let ended = line.type == "done" || (line.type == "error" && line.run != nil)
        if ended {
            // The helper is free again: send a run that waited behind a cancelled one.
            helperBusy = false
            if let next = queued { queued = nil; send(next); helperBusy = true }
        }
        guard let run = active, line.run == run.id else {
            if line.type == "error" && line.run == nil { print("⚠️ Cookie helper: \(line.message ?? "error")") }
            return
        }
        switch line.type {
        case "event":
            guard let event = line.event else { return }
            switch event.type {
            case "text_delta":
                let delta = event.text ?? ""
                guard !delta.isEmpty else { return }
                // Words from a round after a tool call follow words from before it with no space
                // ("let me look.the button…"): start them on a new line, which reads and sounds right.
                if active?.afterTool == true, let last = active?.text.last, !last.isWhitespace, delta.first?.isWhitespace == false {
                    active?.text += "\n"
                }
                active?.afterTool = false
                active?.text += delta
                run.onText(active?.text ?? "")
            case "tool_call_started":
                active?.afterTool = true
                run.onToolStarted()
                let name = event.detail?.name ?? "a tool"
                // A connected-app action may be parked on Enkeon for the person's yes.
                if name == "connector_call" { CookieAppApprovals.shared.watch() }
                let plain = ["recall": "Looked in Enkeon", "remember": "Saving to Enkeon", "web_search": "Searching the web",
                             "fetch_page": "Reading a page", "fetch_pages": "Reading pages", "check_quote": "Checking a quote",
                             "connector_actions": "Looking at your connected apps", "connector_call": "Using a connected app",
                             "use_skill": "Opening a skill", "look": "Looking at the app"]
                run.onStep(plain[name] ?? "Using \(name.replacingOccurrences(of: "_", with: " "))")
            case "usage":
                if let usage = event.usage {
                    print("⏱ model usage input=\(usage.input_tokens ?? 0) output=\(usage.output_tokens ?? 0) cache_read=\(usage.cache_read_tokens ?? 0) cache_write=\(usage.cache_write_tokens ?? 0)")
                }
            case "enkeon_unavailable":
                run.onStep("Enkeon didn't answer; going on without it")
            default:
                break
            }
        case "tool_call":
            guard let id = line.id else { return }
            // The harness sends a call only after the person said yes on the card
            // (or the approved task covered it).
            let name = line.name ?? ""
            let args = line.args ?? [:]
            if MacOperator.names.contains(name) {
                Task { @MainActor in
                    let result = await MacOperator.shared.perform(name, args)
                    if !result.isError, let first = result.output.split(separator: "\n").first {
                        run.onStep(first.hasSuffix(".") ? String(first.dropLast()) : String(first))
                    }
                    self.send(HarnessWire.encode(HarnessRequest.ToolResult(id: id, output: result.output, is_error: result.isError)))
                }
                return
            }
            if name == CookieScreenMemory.tool.name {
                Task { @MainActor in
                    let answer = CookieScreenMemory.shared.answer(args["query"] as? String ?? "")
                    run.onStep("Remembering what was on screen")
                    self.send(HarnessWire.encode(HarnessRequest.ToolResult(id: id, output: answer, is_error: false)))
                }
                return
            }
            if name == CookieRoutineWords.tool.name {
                Task { @MainActor in
                    let result = await CookieRoutineWords.perform(args)
                    if !result.1 { run.onStep("Made a routine") }
                    self.send(HarnessWire.encode(HarnessRequest.ToolResult(id: id, output: result.0, is_error: result.1)))
                }
                return
            }
            if name == CookieHandoff.tool.name {
                Task { @MainActor in
                    let result = CookieHandoff.perform(args, from: CookieHandoff.currentAgentName?())
                    if !result.1 { run.onStep(result.0) }
                    self.send(HarnessWire.encode(HarnessRequest.ToolResult(id: id, output: result.0, is_error: result.1)))
                }
                return
            }
            let result = name == CookieOpen.tool.name
                ? CookieOpen.perform(name: args["name"] as? String ?? "")
                : ("Cookie has no tool named \(name.isEmpty ? "that" : name).", true)
            if !result.1 { run.onStep(result.0.hasSuffix(".") ? String(result.0.dropLast()) : result.0) }
            send(HarnessWire.encode(HarnessRequest.ToolResult(id: id, output: result.0, is_error: result.1)))
        case "approval":
            guard let approval = HarnessApproval(line: line) else { return }
            run.onApproval(approval)
        case "done":
            active = nil
            run.onApproval(nil)
            run.continuation.resume(returning: line.answer ?? run.text)
        case "error":
            active = nil
            run.onApproval(nil)
            run.continuation.resume(throwing: HarnessFailure(message: line.message ?? "The model didn't answer."))
        default:
            break
        }
    }
}

/// The stdout line buffer. Touched only from that pipe's readability
/// handler, which the system calls one read at a time.
private final class LineReader: @unchecked Sendable {
    var buffer = HarnessWire.LineBuffer()
}
