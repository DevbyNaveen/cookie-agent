//
//  CookieSense.swift
//  Cookie
//
//  The client of cookie-sense (Contents/Helpers/cookie-sense, mac/cookie-sense):
//  Cookie's text recognition, face detection and SpeechAnalyzer transcription
//  in a process of their own, so a Vision model that fails to load (e5rt) or
//  crashes takes down the helper, never Cookie, and is retried in a fresh
//  process. One helper for the app's life, started at launch; frames of
//  [u32 JSON][JSON][u32 payload][payload] both ways (big-endian lengths).
//
//  Supervised: a helper that dies fails every request in flight (the
//  redactor then refuses the picture), a request past its deadline stops the
//  helper (it may be stuck), and the next request starts it again — at most
//  four starts in ten minutes, after which it is left stopped and every
//  request fails, closed.
//

import AppKit
import Foundation

final class CookieSense: @unchecked Sendable {
    static let shared = CookieSense()

    /// Stops the helper (a check that it is started again).
    func stopForTesting() {
        lock.withLock { process?.terminate() }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let helperURL: URL
    /// Built without the helper (a development build): Cookie reads screenshots itself.
    var isBundled: Bool { FileManager.default.isExecutableFile(atPath: helperURL.path) }

    init(helperURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cookie-sense")) {
        self.helperURL = helperURL
    }

    /// The OS on which the accurate text model last failed to load: it isn't asked for again
    /// there (a failed load takes ~26 s and slows every other read meanwhile). A new OS tries again.
    static let accurateFailedOSKey = "cookie.vision.accurateFailedOS"
    /// The OS on which `cookie-sense --compile-accurate` succeeded: the model is in the system's
    /// compiled-model cache, so the reader loads it in ~0.1 s (measured on an M4, macOS 27.0).
    static let accurateCompiledOSKey = "cookie.vision.accurateCompiledOS"
    static var operatingSystem: String { ProcessInfo.processInfo.operatingSystemVersionString }
    static var accurateKnownBroken: Bool {
        UserDefaults.standard.string(forKey: accurateFailedOSKey) == operatingSystem
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

    /// Starts the helper (at launch) and gets the accurate text model ready: compiled once per OS
    /// in a separate `--compile-accurate` run (its first load stalls every other Vision request in
    /// its process for ~27 s, but not in another process), then loaded by the reader from the cache.
    func start() {
        guard isBundled else { return }
        lock.withLock { _ = launchIfNeeded() }
        let defaults = UserDefaults.standard
        let system = Self.operatingSystem
        guard defaults.string(forKey: Self.accurateCompiledOSKey) != system,
              defaults.string(forKey: Self.accurateFailedOSKey) != system else { return }
        let compile = Process()
        compile.executableURL = helperURL
        compile.arguments = ["--compile-accurate"]
        compile.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
        compile.qualityOfService = .utility
        compile.terminationHandler = { [weak self] ended in
            if ended.terminationStatus == 0 {
                defaults.set(system, forKey: Self.accurateCompiledOSKey)
                print("👁️ Vision text: accurate compiled for this macOS; the reader loads it now")
                self?.post(["op": "warm", "id": "warm-compiled"])
            } else {
                defaults.set(system, forKey: Self.accurateFailedOSKey)
                print("👁️ Vision text: accurate didn't load on this macOS; fast until the OS changes")
            }
        }
        try? compile.run()
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
                continuation.resume(throwing: Failure(message: "Cookie's reader isn't running"))
                return
            }
            pending[id] = continuation
            lock.unlock()
            Self.write(message, payload: payload, to: input)
            Task.detached {
                try? await Task.sleep(for: .seconds(timeout))
                guard let waiting = self.lock.withLock({ self.pending.removeValue(forKey: id) }) else { return }
                print("⚠️ cookie-sense didn't answer \(message["op"] as? String ?? "") in \(Int(timeout)) s; stopping it")
                waiting.resume(throwing: Failure(message: "Cookie's reader didn't answer in time"))
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

    /// The helper's hello (what it can do), once it has said it; nil when it can't be started.
    func hello() async -> [String: Any]? {
        guard isBundled else { return nil }
        if let reply = lock.withLock({ helloReply }) { return reply }
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let reply = helloReply {
                lock.unlock()
                continuation.resume(returning: reply)
            } else if launchIfNeeded() {
                helloWaiters.append(continuation)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: Pictures

    /// A screenshot's text and faces, read by the helper from its raw pixels (no JPEG round trip).
    func read(_ image: CGImage, faces: Bool) async throws -> CookieScreenRead {
        guard let (layout, pixels) = Self.pixels(of: image) else { throw Failure(message: "the picture couldn't be read") }
        var object = layout
        object["op"] = "read"
        object["faces"] = faces
        // The first read in a fresh helper loads the fast model (~0.1–0.5 s); 10 s is a stuck one.
        let reply = try await request(object, payload: pixels, timeout: 10)
        guard let read = reply["read"], let data = try? JSONSerialization.data(withJSONObject: read) else {
            throw Failure(message: "Cookie's reader answered without a read")
        }
        return try JSONDecoder().decode(CookieScreenRead.self, from: data)
    }

    /// The image's own bytes when they are 8-bit RGBA-like (what screenshots are), else redrawn so.
    static func pixels(of image: CGImage) -> (layout: [String: Any], data: Data)? {
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32, let data = image.dataProvider?.data as Data? {
            return (["width": image.width, "height": image.height, "bytesPerRow": image.bytesPerRow, "bitsPerComponent": 8,
                     "bitsPerPixel": 32, "bitmapInfo": image.bitmapInfo.rawValue,
                     "colorSpace": (image.colorSpace?.name as String?) ?? (CGColorSpace.sRGB as String)], data)
        }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: space, bitmapInfo: info) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let redrawn = context.makeImage(), let data = redrawn.dataProvider?.data as Data? else { return nil }
        return (["width": redrawn.width, "height": redrawn.height, "bytesPerRow": redrawn.bytesPerRow, "bitsPerComponent": 8,
                 "bitsPerPixel": 32, "bitmapInfo": info, "colorSpace": CGColorSpace.sRGB as String], data)
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
            print("⚠️ cookie-sense couldn't start: \(error.localizedDescription)")
            return false
        }
        self.process = process
        input = stdin.fileHandleForWriting
        helloReply = nil
        print("👁️ cookie-sense started (pid \(process.processIdentifier))")
        let input = stdin.fileHandleForWriting
        Self.write(["op": "hello", "id": "hello-\(launches.count)"], payload: Data(), to: input)
        if UserDefaults.standard.string(forKey: Self.accurateCompiledOSKey) == Self.operatingSystem {
            Self.write(["op": "warm", "id": "warm-\(launches.count)"], payload: Data(), to: input)
        }
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
        if id.hasPrefix("warm-") {
            print(message["accurate"] as? String == "ready" ? "👁️ Vision text: accurate ready"
                  : "⚠️ Vision text: accurate didn't load in the reader (\(message["failure"] ?? "")); reading with fast")
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
            print("⚠️ cookie-sense stopped (exit \(ended.terminationStatus)); it starts again with the next request")
        }
        waiting.forEach { $0.resume(throwing: Failure(message: "Cookie's reader stopped")) }
        listening.forEach { $0(["event": "error", "message": "Cookie's reader stopped"]) }
        hellos.forEach { $0.resume(returning: nil) }
    }

    /// Frames from different threads (audio, reads) must never interleave.
    private static let writing = NSLock()

    private static func write(_ object: [String: Any], payload: Data, to input: FileHandle) {
        guard let json = try? JSONSerialization.data(withJSONObject: object) else { return }
        var frame = Data()
        frame.append(contentsOf: withUnsafeBytes(of: UInt32(json.count).bigEndian, Array.init))
        frame.append(json)
        frame.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init))
        frame.append(payload)
        // One frame per write, under one lock; a dead helper fails the write (SIGPIPE is ignored
        // app-wide by HarnessClient) and its exit is reported by the termination handler.
        writing.withLock { try? input.write(contentsOf: frame) }
    }
}

/// Bytes in, whole frames out. Touched only from the stdout pipe's readability handler, which
/// the system calls one read at a time.
final class FrameReader: @unchecked Sendable {
    private var buffer = Data()

    func append(_ data: Data) -> [(json: [String: Any], payload: Data)] {
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
        guard let jsonLength = length(at: 0), let payloadLength = length(at: 4 + jsonLength),
              buffer.count >= 8 + jsonLength + payloadLength else { return nil }
        let start = buffer.startIndex
        let json = buffer[start + 4..<start + 4 + jsonLength]
        let payload = Data(buffer[start + 8 + jsonLength..<start + 8 + jsonLength + payloadLength])
        buffer = Data(buffer[(start + 8 + jsonLength + payloadLength)...])
        let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        return (object, payload)
    }
}
