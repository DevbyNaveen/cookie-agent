//
//  SpeechHelper.swift
//  EnkeonVoiceKit
//
//  The client of enkeon-sense (Contents/Helpers/enkeon-sense, Helpers/enkeon-sense):
//  SpeechAnalyzer transcription in a process of its own, so a speech model that
//  fails or crashes takes down the helper, never the app, and is retried in a
//  fresh process. One helper for the app's life, started at launch; frames of
//  [u32 JSON][JSON][u32 payload][payload] both ways (big-endian lengths).
//
//  Supervised: a helper that dies fails every request in flight, a request past
//  its deadline stops the helper (it may be stuck), and the next request starts
//  it again — at most four starts in ten minutes, after which it is left stopped
//  and every request fails, closed.
//
//  Taken from Cookie's CookieSense (cookie-harness 8ffefde) without its screen
//  reading; Cookie keeps that.
//

import AppKit
import Foundation

public final class SpeechHelper: @unchecked Sendable {
    public static let shared = SpeechHelper()

    /// Stops the helper (a check that it is started again).
    func stopForTesting() {
        lock.withLock { process?.terminate() }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let helperURL: URL
    /// Built without the helper (a development build): dictation falls back to SFSpeechRecognizer.
    public var isBundled: Bool { FileManager.default.isExecutableFile(atPath: helperURL.path) }

    public init(helperURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/enkeon-sense")) {
        self.helperURL = helperURL
        // A helper that dies mid-write must fail the write, not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var listeners: [String: ([String: Any]) -> Void] = [:]
    private var launches: [Date] = []
    private var counter = 0
    private var helloReply: [String: Any]?
    private var helloWaiters: [CheckedContinuation<[String: Any]?, Never>] = []

    /// Starts the helper ahead of the first dictation, so the first key-down doesn't pay for the launch.
    func start() {
        guard isBundled else { return }
        lock.withLock { _ = launchIfNeeded() }
    }

    func nextID() -> String {
        lock.withLock {
            counter += 1
            return "c\(counter)"
        }
    }

    // MARK: Requests

    /// One request and its reply. Throws `Failure` when the helper can't be started, dies, says
    /// "error", or doesn't answer in time (it is then stopped).
    func request(_ object: [String: Any], payload: Data = Data(), timeout: Double) async throws -> [String: Any] {
        let id = object["id"] as? String ?? nextID()
        var message = object
        message["id"] = id
        let reply: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard launchIfNeeded(), let input else {
                lock.unlock()
                continuation.resume(throwing: Failure(message: "the speech helper isn't running"))
                return
            }
            pending[id] = continuation
            lock.unlock()
            Self.write(message, payload: payload, to: input)
            Task.detached {
                try? await Task.sleep(for: .seconds(timeout))
                guard let waiting = self.lock.withLock({ self.pending.removeValue(forKey: id) }) else { return }
                print("⚠️ enkeon-sense didn't answer \(message["op"] as? String ?? "") in \(Int(timeout)) s; stopping it")
                waiting.resume(throwing: Failure(message: "the speech helper didn't answer in time"))
                self.lock.withLock { self.process?.terminate() }
            }
        }
        if let problem = reply["error"] as? String { throw Failure(message: problem) }
        return reply
    }

    /// A message with no reply (speech audio), in order with everything else sent.
    func post(_ object: [String: Any], payload: Data = Data()) {
        guard let input = lock.withLock({ launchIfNeeded() ? self.input : nil }) else { return }
        Self.write(object, payload: payload, to: input)
    }

    /// Events for a session id (speech), until `stopListening`.
    func listen(_ id: String, _ handler: @escaping ([String: Any]) -> Void) {
        lock.withLock { listeners[id] = handler }
    }

    func stopListening(_ id: String) {
        _ = lock.withLock { listeners.removeValue(forKey: id) }
    }

    func deliverAudioFailure(id: String) {
        let listener = lock.withLock { listeners[id] }
        listener?(["id": id, "event": "error", "message": "Microphone audio could not be converted. Nothing was pasted."])
    }

    /// The helper's hello (what it can do), once it has said it; nil when it can't be started.
    func hello() async -> [String: Any]? {
        guard isBundled else { return nil }
        if let reply = lock.withLock({ helloReply }) { return reply }
        return try? await request(["op": "hello"], timeout: 5)
    }

    /// Whether the speech model for this language is installed, asked fresh (the hello reply is
    /// cached, and the model can finish installing after it). Asking also starts the install when
    /// it is missing. nil when the helper isn't bundled or can't answer.
    public func speechModelReady() async -> Bool? {
        guard isBundled else { return nil }
        if AppBundleConfiguration.stringValue(forKey: "VoiceTranscriptionProvider") == "parakeet" {
            return (try? await request(["op": "hello"], timeout: 5))?["parakeet"] as? Bool
        }
        return (try? await request(["op": "hello"], timeout: 5))?["speech"] as? Bool
    }

    public func prepareSpeechModel() async throws {
        guard AppBundleConfiguration.stringValue(forKey: "VoiceTranscriptionProvider") == "parakeet" else { return }
        _ = try await request(["op": "parakeet.prepare"], timeout: 600)
    }

    // MARK: Clean-up (Apple's on-device model, in the helper)

    /// Whether the on-device clean-up model can answer here, and why not. nil: no helper.
    public func cleanupAvailability() async -> (available: Bool, note: String)? {
        guard isBundled, let reply = try? await request(["op": "hello"], timeout: 5) else { return nil }
        return (reply["cleanup"] as? Bool ?? false, reply["cleanupNote"] as? String ?? "")
    }

    /// Key-down: warm a fresh session for this style while the person talks.
    public func warmCleanup(style: String) {
        guard isBundled else { return }
        post(["op": "cleanup.warm", "id": nextID(), "style": style])
    }

    /// The model's clean-up, or nil when it isn't there, fails, or misses `deadline` (dictation never waits longer).
    public func cleanup(_ text: String, style: String, deadline: Double = 2.5) async -> String? {
        guard isBundled else { return nil }
        return await Self.first(within: deadline) {
            (try? await self.request(["op": "cleanup", "text": text, "style": style], timeout: 20))?["text"] as? String
        }
    }

    // MARK: Fix and Humanise (the same on-device model)

    /// Loads the model for `mode` ("fix" or "humanise") before the person asks.
    public func warmRewrite(mode: String) {
        guard isBundled else { return }
        post(["op": "rewrite.warm", "id": nextID(), "mode": mode])
    }

    /// The text rewritten, or nil when the model isn't there, fails, or misses `deadline`.
    /// `mode` "edit" applies a spoken `instruction` to the text.
    public func rewrite(_ text: String, mode: String, instruction: String = "", samples: [String] = [], deadline: Double = 12) async -> String? {
        guard isBundled else { return nil }
        return await Self.first(within: deadline) {
            (try? await self.request(["op": "rewrite", "text": text, "mode": mode, "instruction": instruction, "samples": samples],
                                     timeout: 30))?["text"] as? String
        }
    }

    /// Whichever comes first: the work's answer or nil at the deadline. The slow answer is dropped, not awaited.
    static func first(within seconds: Double, _ work: @escaping @Sendable () async -> String?) async -> String? {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            Task { let answer = await work(); if once.claim() { continuation.resume(returning: answer) } }
            Task { try? await Task.sleep(for: .seconds(seconds)); if once.claim() { continuation.resume(returning: nil) } }
        }
    }

    // MARK: The process (under `lock`)

    /// True when a helper is running or was just started.
    private func launchIfNeeded() -> Bool {
        if let process, process.isRunning { return true }
        guard isBundled else { return false }
        launches = launches.filter { Date().timeIntervalSince($0) < 600 }
        guard launches.count < 4 else { return false }
        launches.append(Date())

        let process = Process()
        process.executableURL = helperURL
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let reader = FrameReader()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            for frame in reader.append(data) { self?.deliver(frame) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            print(String(decoding: data, as: UTF8.self), terminator: "")
        }
        process.terminationHandler = { [weak self] ended in self?.ended(ended) }
        do {
            try process.run()
        } catch {
            print("⚠️ enkeon-sense couldn't start: \(error.localizedDescription)")
            return false
        }
        self.process = process
        input = stdin.fileHandleForWriting
        helloReply = nil
        print("🎙️ enkeon-sense started (pid \(process.processIdentifier))")
        let input = stdin.fileHandleForWriting
        Self.write(["op": "hello", "id": "hello-\(launches.count)"], payload: Data(), to: input)
        return true
    }

    private func deliver(_ frame: (json: [String: Any], payload: Data)) {
        let message = frame.json
        guard let id = message["id"] as? String else { return }
        if id.hasPrefix("hello-") {
            let waiters: [CheckedContinuation<[String: Any]?, Never>] = lock.withLock {
                helloReply = message
                defer { helloWaiters = [] }
                return helloWaiters
            }
            waiters.forEach { $0.resume(returning: message) }
            return
        }
        if message["event"] != nil {
            let listener = lock.withLock { listeners[id] }
            listener?(message)
            return
        }
        if let waiting = lock.withLock({ pending.removeValue(forKey: id) }) {
            waiting.resume(returning: message)
        } else if message["error"] != nil, let listener = lock.withLock({ listeners[id] }) {
            listener(["id": id, "event": "error", "message": message["error"] ?? ""])
        }
    }

    private func ended(_ ended: Process) {
        let (waiting, listening, hellos): ([CheckedContinuation<[String: Any], Error>], [([String: Any]) -> Void], [CheckedContinuation<[String: Any]?, Never>]) = lock.withLock {
            guard process === ended else { return ([], [], []) }
            process = nil
            input = nil
            helloReply = nil
            defer { pending = [:]; listeners = [:]; helloWaiters = [] }
            return (Array(pending.values), Array(listeners.values), helloWaiters)
        }
        if !waiting.isEmpty || !listening.isEmpty {
            print("⚠️ enkeon-sense stopped (exit \(ended.terminationStatus)); it starts again with the next request")
        }
        waiting.forEach { $0.resume(throwing: Failure(message: "the speech helper stopped")) }
        listening.forEach { $0(["event": "error", "message": "the speech helper stopped"]) }
        hellos.forEach { $0.resume(returning: nil) }
    }

    /// Frames from different threads (audio, requests) must never interleave.
    private static let writing = NSLock()

    private static func write(_ object: [String: Any], payload: Data, to input: FileHandle) {
        guard let json = try? JSONSerialization.data(withJSONObject: object) else { return }
        var frame = Data()
        frame.append(contentsOf: withUnsafeBytes(of: UInt32(json.count).bigEndian, Array.init))
        frame.append(json)
        frame.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init))
        frame.append(payload)
        // One frame per write, under one lock; a dead helper fails the write (SIGPIPE is
        // ignored in `init`) and its exit is reported by the termination handler.
        writing.withLock { try? input.write(contentsOf: frame) }
    }
}

/// Bytes in, whole frames out. Touched only from the stdout pipe's readability handler, which
/// the system calls one read at a time.
final class FrameReader: @unchecked Sendable {
    private var buffer = Data()
    static let maximumFrame = 8 * 1024 * 1024
    private(set) var invalid = false

    func append(_ data: Data) -> [(json: [String: Any], payload: Data)] {
        guard !invalid else { return [] }
        buffer.append(data)
        var frames: [(json: [String: Any], payload: Data)] = []
        while let frame = next() { frames.append(frame) }
        return frames
    }

    private func next() -> (json: [String: Any], payload: Data)? {
        func length(at offset: Int) -> Int? {
            guard buffer.count >= offset + 4 else { return nil }
            let start = buffer.startIndex + offset
            return Int(buffer[start..<start + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        }
        guard let jsonLength = length(at: 0) else { return nil }
        guard jsonLength <= Self.maximumFrame else { invalid = true; buffer = Data(); return nil }
        guard let payloadLength = length(at: 4 + jsonLength) else { return nil }
        guard payloadLength <= Self.maximumFrame else { invalid = true; buffer = Data(); return nil }
        guard buffer.count >= 8 + jsonLength + payloadLength else { return nil }
        let start = buffer.startIndex
        let json = buffer[start + 4..<start + 4 + jsonLength]
        let payload = Data(buffer[start + 8 + jsonLength..<start + 8 + jsonLength + payloadLength])
        buffer = Data(buffer[(start + 8 + jsonLength + payloadLength)...])
        let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        return (object, payload)
    }
}
