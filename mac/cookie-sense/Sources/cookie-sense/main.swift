//
//  main.swift
//  cookie-sense
//
//  Cookie's eyes and ears, in a process of their own: Vision text recognition
//  and face detection (the redactor's checks, the reading pen, what Cookie
//  saw) and, on macOS 26 and later, SpeechAnalyzer transcription. A Neural
//  Engine model that fails to load can poison the process it loads in; here
//  that is this helper, which Cookie starts again, never Cookie itself. The
//  models also stay warm here between questions.
//
//  One long-lived child of Cookie.app (Contents/Helpers/cookie-sense), so the
//  app is the responsible process for privacy prompts and its usage strings
//  apply. It never opens the microphone or the screen: Cookie sends pixels
//  and audio over stdin.
//
//  Wire, both ways: frames of [u32 JSON length][JSON][u32 payload length]
//  [payload], lengths big-endian. Requests carry "op" and "id"; replies carry
//  the "id" and either the answer or "error". Speech events carry the
//  session's id and "event".
//

import Foundation

/// Writes whole frames to stdout, one at a time.
enum Wire {
    private static let lock = NSLock()

    static func send(_ object: [String: Any], payload: Data = Data()) {
        guard let json = try? JSONSerialization.data(withJSONObject: object) else { return }
        var frame = Data()
        frame.append(bigEndian: UInt32(json.count))
        frame.append(json)
        frame.append(bigEndian: UInt32(payload.count))
        frame.append(payload)
        lock.lock()
        defer { lock.unlock() }
        frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(1, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 {
                    if errno == EINTR { continue }
                    exit(0) // Cookie is gone.
                }
                offset += written
            }
        }
    }

    static func reply(_ id: String, _ fields: [String: Any]) {
        var object = fields
        object["id"] = id
        send(object)
    }

    static func fail(_ id: String, _ message: String) {
        send(["id": id, "error": message])
    }

    /// Exactly `count` bytes from stdin; nil at end of input (Cookie quit).
    static func read(_ count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            while offset < count {
                let got = Foundation.read(0, buffer.baseAddress! + offset, count - offset)
                if got == 0 { return false }
                if got < 0 { if errno == EINTR { continue }; return false }
                offset += got
            }
            return true
        }
        return ok ? data : nil
    }

    static func readLength() -> Int? {
        guard let bytes = read(4) else { return nil }
        return Int(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }
}

extension Data {
    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

/// The largest frame accepted: a screenshot's pixels are a few megabytes.
let maximumFrame = 64 * 1024 * 1024

// `cookie-sense --compile-accurate`: load Vision's accurate text model once, alone, and exit 0 when
// it read its sample. Its first load on an OS compiles it for the Neural Engine (~27 s on an M4),
// and while that runs every other Vision request in the same process stalls (fast reads took
// 10–13 s) — but not in another process, and the compiled model is cached for every later
// process (0.1 s). So Cookie runs this once per OS, beside the reader, never inside it.
if CommandLine.arguments.contains("--compile-accurate") {
    let outcome = VisionWorker.loadAccurate()
    log(outcome.map { "accurate didn't load: \($0)" } ?? "accurate compiled")
    exit(outcome == nil ? 0 : 1)
}

let vision = VisionWorker()
let speech = SpeechWorker()


Thread.detachNewThread {
    while let jsonLength = Wire.readLength(), jsonLength <= maximumFrame, let json = Wire.read(jsonLength),
          let payloadLength = Wire.readLength(), payloadLength <= maximumFrame, let payload = Wire.read(payloadLength) {
        guard let request = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let op = request["op"] as? String, let id = request["id"] as? String else { continue }
        switch op {
        case "hello":
            Task { Wire.reply(id, ["ok": true, "version": 1, "speech": await speech.isAvailable(), "accurate": await vision.stateName]) }
        case "warm":
            // Load the accurate text model; answered when it is ready or has failed. Cookie asks
            // only once `--compile-accurate` has succeeded on this OS, so it loads from the cache.
            vision.warm(id: id)
        case "read":
            Task { await vision.read(id: id, request: request, pixels: payload) }
        case "speech.start":
            Task { await speech.start(id: id, locale: request["locale"] as? String ?? Locale.current.identifier) }
        case "speech.audio":
            // In order, without waiting: the session queues it for the analyzer.
            speech.audio(id: id, pcm16: payload)
        case "speech.finish":
            Task { await speech.finish(id: id) }
        case "speech.cancel":
            Task { await speech.cancel(id: id) }
        default:
            Wire.fail(id, "unknown op \(op)")
        }
    }
    exit(0)
}

dispatchMain()
