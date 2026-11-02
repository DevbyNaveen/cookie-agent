//
//  main.swift
//  enkeon-sense (from Cookie's cookie-sense, cookie-harness 8ffefde, without Vision)
//
//  Enkeon's ears, in a process of their own: SpeechAnalyzer transcription and
//  the on-device clean-up model (Foundation Models), on macOS 26 and later. A speech model that fails can poison the process it
//  loads in; here that is this helper, which the app starts again, never the
//  app itself. The model also stays warm here between dictations.
//
//  One long-lived child of Enkeon.app (Contents/Helpers/enkeon-sense), so the
//  app is the responsible process for privacy prompts and its usage strings
//  apply. It never opens the microphone: the app sends audio over stdin.
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
                    exit(0) // The app is gone.
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

    /// Exactly `count` bytes from stdin; nil at end of input (the app quit).
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

func log(_ message: String) {
    FileHandle.standardError.write(Data("🎙️ enkeon-sense: \(message)\n".utf8))
}

/// The largest frame accepted: audio arrives in buffers of well under a megabyte.
let maximumFrame = 8 * 1024 * 1024

let speech = SpeechWorker()
let parakeet = ParakeetWorker()
let cleanup = CleanupWorker()
let rewrite = RewriteWorker()

Thread.detachNewThread {
    while let jsonLength = Wire.readLength(), jsonLength <= maximumFrame, let json = Wire.read(jsonLength),
          let payloadLength = Wire.readLength(), payloadLength <= maximumFrame, let payload = Wire.read(payloadLength) {
        guard let request = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let op = request["op"] as? String, let id = request["id"] as? String else { continue }
        switch op {
        case "hello":
            Task { Wire.reply(id, ["ok": true, "version": 1, "speech": await speech.isAvailable(),
                                   "parakeet": parakeet.ready,
                                   "cleanup": cleanup.isAvailable(), "cleanupNote": cleanup.availabilityNote()]) }
        case "parakeet.prepare": Task { await parakeet.prepare(id: id, gpu: request["compute"] as? String == "gpu") }
        case "parakeet.transcribe": Task { await parakeet.transcribe(id: id, data: payload) }
        case "meeting.transcribe": Task { await parakeet.transcribe(id: id, data: payload, reply: true) }
        case "parakeet.start": Task { await parakeet.start(id: id) }
        case "parakeet.audio": parakeet.audio(id: id, data: payload)
        case "parakeet.finish": Task { await parakeet.finish(id: id) }
        case "parakeet.cancel": Task { await parakeet.cancel(id: id) }
        case "speech.start":
            Task { await speech.start(id: id, locale: request["locale"] as? String ?? Locale.current.identifier) }
        case "speech.audio":
            // In order, without waiting: the session queues it for the analyzer.
            speech.audio(id: id, pcm16: payload)
        case "speech.finish":
            Task { await speech.finish(id: id) }
        case "speech.cancel":
            Task { await speech.cancel(id: id) }
        case "cleanup.warm":
            cleanup.warm(style: request["style"] as? String ?? "neutral")
        case "cleanup":
            let text = request["text"] as? String ?? ""
            let style = request["style"] as? String ?? "neutral"
            let terms = request["terms"] as? [String] ?? []
            Task { await cleanup.cleanup(id: id, text: text, style: style, terms: terms) }
        case "rewrite.warm":
            rewrite.warm(mode: request["mode"] as? String ?? "fix")
        case "rewrite":
            let text = request["text"] as? String ?? ""
            let mode = request["mode"] as? String ?? "fix"
            let samples = request["samples"] as? [String] ?? []
            let instruction = request["instruction"] as? String ?? ""
            Task { await rewrite.rewrite(id: id, text: text, mode: mode, instruction: instruction, samples: samples) }
        default:
            Wire.fail(id, "unknown op \(op)")
        }
    }
    exit(0)
}

dispatchMain()
