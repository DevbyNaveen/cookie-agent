//
//  CookieRecorder.swift
//  Cookie
//
//  Record a meeting with no bot joining the call: the person's microphone and
//  the call's sound, kept apart, sent to Enkeon a minute at a time by the
//  bundled `cookie-recorder` helper, transcribed there (Amazon Transcribe,
//  eu-central-1). Nothing is kept until the person says Keep. Only the person
//  starts a recording; the model has no tool for it.
//

import Foundation

/// One line from `cookie-recorder record`.
enum RecorderLine: Equatable {
    case recording(meeting: String, secs: Int, level: Double)
    case micOnly(String)
    case stopped(meeting: String)
    case error(String)

    static func parse(_ line: String) -> RecorderLine? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let state = object["state"] as? String else { return nil }
        let meeting = object["meeting_id"] as? String ?? ""
        switch state {
        case "recording":
            return .recording(meeting: meeting, secs: (object["secs"] as? NSNumber)?.intValue ?? 0,
                              level: (object["level"] as? NSNumber)?.doubleValue ?? 0)
        case "mic_only": return .micOnly(object["message"] as? String ?? "Only your microphone is being recorded.")
        case "stopped": return .stopped(meeting: meeting)
        case "error": return .error(object["message"] as? String ?? "The recorder stopped.")
        default: return nil
        }
    }
}

/// The gateway's meeting, as far as Cookie shows it.
enum MeetingResult: Equatable {
    case working
    case ready(summary: String, promises: Int, minutes: Int)
    case failed(String)

    /// The promises as words, from strings or objects ({"text"|"promise"|"title"|"summary"}).
    static func promiseTexts(_ text: String) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let promises = object["promises"] as? [Any] else { return [] }
        return promises.compactMap { item in
            if let string = item as? String { return string }
            guard let dict = item as? [String: Any] else { return nil }
            for key in ["text", "promise", "title", "summary"] { if let value = dict[key] as? String, !value.isEmpty { return value } }
            return nil
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func parse(_ text: String) -> MeetingResult? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let state = object["state"] as? String else { return nil }
        switch state {
        case "ready", "kept":
            return .ready(summary: object["summary"] as? String ?? "",
                          promises: (object["promises"] as? [Any])?.count ?? 0,
                          minutes: max(1, ((object["duration_secs"] as? NSNumber)?.intValue ?? 0) / 60))
        case "failed", "discarded": return .failed(object["failure"] as? String ?? "The recording didn't make it.")
        default: return .working
        }
    }
}

@MainActor
final class CookieRecorder: ObservableObject {
    static let shared = CookieRecorder()

    enum Phase: Equatable {
        case idle
        /// On this Mac: the meeting model gets ready (about 630 MB, the first time only).
        case preparing
        case recording(secs: Int, level: Double, micOnly: Bool)
        case stopping
        case transcribing
        case ready(meeting: String, summary: String, promises: Int, minutes: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// The promises of the meeting that's ready, as words, for the Board and the follow-up.
    private(set) var readyPromises: [String] = []
    private(set) var readySummary = ""
    private var process: Process?
    private var input: FileHandle?
    private var meeting: String?
    private var micOnly = false
    private var refresher: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    /// On this Mac: Enkeon Voice's meeting engine (capture, Parakeet in cookie-sense, saved locally).
    private var local: MeetingModel?
    private var localTicker: Task<Void, Never>?

    private var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cookie-recorder") }

    var isBusy: Bool {
        switch phase {
        case .idle, .ready, .failed: return false
        default: return true
        }
    }

    func start(title: String = "Meeting " + Date().formatted(date: .abbreviated, time: .shortened)) {
        let upcoming = CookieCalendar.shared.access == .allowed ? CookieCalendar.shared.next : nil
        let startsFromCalendar = title.hasPrefix("Meeting ") && upcoming != nil
        let actualTitle = startsFromCalendar ? upcoming!.title : title
        let attendees = startsFromCalendar ? upcoming!.attendees : []
        if MeetingTranscription.current() == .onDevice { return startOnDevice(title: actualTitle, attendees: attendees) }
        guard !isBusy else { return }
        Task {
            guard FileManager.default.isExecutableFile(atPath: helper.path) else { return fail("The recorder is missing from this build of Cookie.") }
            guard let project = CookieAccount.shared.projectID, let token = await CookieAccount.shared.accessToken() else {
                return fail("Sign in to Enkeon (Settings → Account) to record a meeting.")
            }
            let process = Process()
            process.executableURL = helper
            process.arguments = ["record", "--project", project, "--title", actualTitle]
            process.environment = ["COOKIE_TOKEN": token, "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            // The handler runs one read at a time, so the buffer is only ever touched there.
            final class Reader: @unchecked Sendable { var lines = HarnessWire.LineBuffer() }
            let reader = Reader()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                let lines = reader.lines.append(data).map { String(decoding: $0, as: UTF8.self) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { lines.compactMap(RecorderLine.parse).forEach(self.handle) }
                }
            }
            process.terminationHandler = { ended in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.ended(status: ended.terminationStatus) }
                }
            }
            do {
                try process.run()
            } catch {
                return fail("Couldn't start the recorder: \(error.localizedDescription)")
            }
            self.process = process
            input = stdin.fileHandleForWriting
            micOnly = false
            phase = .recording(secs: 0, level: 0, micOnly: false)
            // A meeting can outlast the hour a sign-in token lives: hand over renewed ones.
            refresher = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20 * 60))
                    if let fresh = await CookieAccount.shared.accessToken() { send("token \(fresh)") }
                }
            }
        }
    }

    func stop() {
        guard case .recording = phase else { return }
        phase = .stopping
        if let local, local.isActive { return stopOnDevice(local) }
        send("stop")
    }

    private func startOnDevice(title: String, attendees: [String] = []) {
        guard !isBusy else { return }
        let model = local ?? MeetingModel()
        local = model
        model.title = title
        phase = .preparing
        Task {
            await model.start(attendees: attendees)
            guard model.phase == .recording else {
                phase = .failed(model.error ?? "The meeting couldn't start on this Mac.")
                return
            }
            let started = Date()
            localTicker?.cancel()
            localTicker = Task { [weak self] in
                while !Task.isCancelled, model.isActive {
                    if case .recording = self?.phase {
                        self?.phase = .recording(secs: Int(Date().timeIntervalSince(started)), level: 0, micOnly: !model.includeSystem)
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// Stops capture, waits for the last chunks to be transcribed on this Mac, then offers Keep.
    private func stopOnDevice(_ model: MeetingModel) {
        let id = model.activeID
        Task {
            await model.stop()
            localTicker?.cancel()
            phase = .transcribing
            for _ in 0..<600 {
                guard let record = model.records.first(where: { $0.id == id }), record.status == "processing" else { break }
                try? await Task.sleep(for: .seconds(1))
            }
            guard let id, let record = model.records.first(where: { $0.id == id }) else {
                phase = .failed(model.error ?? "The meeting's transcript wasn't saved.")
                return
            }
            let transcript = record.transcript
            readyPromises = MeetingPromises.extract(transcript)
            readySummary = String(transcript.prefix(280))
            let minutes = Int(((record.ended ?? Date()).timeIntervalSince(record.started)) / 60)
            phase = .ready(meeting: "local:" + id.uuidString, summary: readySummary, promises: readyPromises.count, minutes: max(1, minutes))
            CookieNotifications.shared.post(.reply, threadID: nil, title: "Meeting ready", body: "Transcribed on this Mac.", panelOpen: false)
        }
    }

    /// Keep it in Enkeon (the summary and promises become context), or throw it away.
    func decide(keep: Bool) {
        guard case .ready(let meeting, _, _, _) = phase else { return }
        phase = .idle
        if !meeting.hasPrefix("local:") {
            Task { _ = await runHelper(["decide", "--meeting", meeting, keep ? "--keep" : "--discard"]) }
        }
        if keep { Self.rememberMeeting(summary: readySummary, promises: readyPromises) }
        readyPromises = []
        readySummary = ""
    }

    /// Kept meeting: each promise becomes a piece of work, and Cookie drafts the follow-up in the background.
    static func rememberMeeting(summary: String, promises: [String], work: WorkStore = .shared) {
        for promise in promises.prefix(12) {
            let item = work.add(title: String(promise.prefix(90)), nextStep: "Do what was promised, then say so", by: "cookie")
            work.update(item.id, by: "cookie", note: "Promised in a meeting") { _ in }
        }
        guard !summary.isEmpty, let cookie = CookieAgentStore.shared.agents.first else { return }
        let input = "I just had a meeting. Summary:\n\(summary)\n\nPromises made: \(promises.isEmpty ? "none noted" : promises.joined(separator: "; ")).\n\nDraft the follow-up email in my voice: a short recap, the decisions, the next steps, and what I promised to send. Under 120 words. Put the draft first, then one line on who it should go to if that's clear from the summary. Don't send anything."
        CookieBackgroundRuns.shared.start(agent: cookie, input: input, title: "Cookie: follow-up after the meeting", kind: .meeting) { reply, threadID in
            CookieNotifications.shared.post(.reply, threadID: threadID, title: "Follow-up draft ready", body: reply, panelOpen: false)
            CookieBackgroundRuns.shared.companionManager?.replyFinished.send((threadID, CompanionChatMessage(role: .assistant, text: reply)))
        }
    }

    func dismiss() {
        if case .failed = phase { phase = .idle }
    }

    private func handle(_ line: RecorderLine) {
        switch line {
        case .recording(let id, let secs, let level):
            meeting = id
            if case .stopping = phase { return }
            phase = .recording(secs: secs, level: level, micOnly: micOnly)
        case .micOnly:
            micOnly = true
        case .stopped(let id):
            meeting = id
            phase = .transcribing
            pollUntilReady()
        case .error(let message):
            if case .recording = phase { phase = .failed(message) }
        }
    }

    private func ended(status: Int32) {
        refresher?.cancel()
        process = nil
        input = nil
        if case .recording = phase { phase = .failed("The recorder stopped unexpectedly (exit \(status)).") }
        if case .stopping = phase, meeting == nil { phase = .failed("The recording didn't start on Enkeon.") }
    }

    private func pollUntilReady() {
        poller?.cancel()
        poller = Task {
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(10))
                guard let meeting, let text = await runHelper(["get", "--meeting", meeting]),
                      let result = MeetingResult.parse(text) else { continue }
                switch result {
                case .working: continue
                case .ready(let summary, let promises, let minutes):
                    readyPromises = MeetingResult.promiseTexts(text)
                    readySummary = summary
                    phase = .ready(meeting: meeting, summary: summary, promises: promises, minutes: minutes)
                    CookieNotifications.shared.post(.reply, threadID: nil, title: "Meeting ready", body: summary.isEmpty ? "Your transcript is ready." : summary, panelOpen: false)
                    return
                case .failed(let why):
                    phase = .failed(why)
                    return
                }
            }
            phase = .failed("The transcript is taking longer than 20 minutes. Check it in Enkeon.")
        }
    }

    private func runHelper(_ args: [String]) async -> String? {
        guard let project = CookieAccount.shared.projectID, let token = await CookieAccount.shared.accessToken() else { return nil }
        let process = Process()
        process.executableURL = helper
        process.arguments = [args[0], "--project", project] + args.dropFirst()
        process.environment = ["COOKIE_TOKEN": token, "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func send(_ line: String) {
        try? input?.write(contentsOf: Data((line + "\n").utf8))
    }

    private func fail(_ message: String) {
        phase = .failed(message)
    }
}

/// Where meetings are transcribed: on this Mac (Parakeet, the default) or by Enkeon in the cloud
/// (Amazon Transcribe, eu-central-1), when Settings → Privacy says so.
enum MeetingTranscription: Equatable {
    case onDevice, cloud
    static let cloudKey = "cookie.meetings.cloud"
    static func current(defaults: UserDefaults = .standard) -> MeetingTranscription {
        defaults.bool(forKey: cloudKey) ? .cloud : .onDevice
    }
}

/// Promises heard in a meeting transcribed on this Mac: sentences where someone commits to something.
// ponytail: a phrase match on first-person commitments ("I'll", "we will", "let me"); the cloud path gets
// Enkeon's model-made promises. Upgrade: ask Cookie's model for promises when one is configured.
enum MeetingPromises {
    private static let commitment = try! NSRegularExpression(
        pattern: #"\b(I'll|I will|we'll|we will|I'm going to|I am going to|we're going to|let me)\b"#, options: [.caseInsensitive])

    static func extract(_ transcript: String) -> [String] {
        let sentences = transcript.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
            var out: [String] = [], current = ""
            for character in line {
                current.append(character)
                if ".!?".contains(character) { out.append(current); current = "" }
            }
            if !current.isEmpty { out.append(current) }
            return out
        }
        return sentences.map { $0.trimmingCharacters(in: .whitespaces) }.filter { sentence in
            !sentence.hasSuffix("?") &&
            commitment.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)) != nil
        }
    }
}
