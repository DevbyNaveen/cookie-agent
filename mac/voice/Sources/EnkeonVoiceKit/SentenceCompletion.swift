//
//  SentenceCompletion.swift
//  EnkeonVoiceKit
//
//  Finishes the sentence you're typing, in any app, in your words and with facts from your Enkeon
//  memory. A base (text-continuation) model runs on this Mac through enkeon-complete, llama.cpp's
//  server, which keeps the shared prompt (memory notes, your style) cached so each keystroke only
//  processes what's new. Every suggestion passes `CompletionGate` before it is shown.
//
//  Benchmarked 2026-10-30 on an M4 (Gemma 3 1B base, Q4_K_M): first token 27–44 ms, whole
//  suggestion 50–320 ms; 6/6 memory facts right, 0 invented on the trap cases.
//

import AppKit
import ApplicationServices
import Carbon
import Foundation

// MARK: - What may be shown

/// The rules a suggestion passes before it reaches the screen. Ordinary words need the model to be
/// reasonably sure (a wrong one costs nothing; the person just keeps typing). Names and numbers need
/// it to be very sure AND a memory line on the same topic to hold them; if the sentence is heading
/// for a fact nothing backs, nothing is shown at all.
public enum CompletionGate {
    static let wordMinimum = -2.5
    static let factMinimum = -1.0
    static let stopWords: Set<String> = Set(
        "the a an and or but of to in on at for with is are was were be our we you it this that my your".split(separator: " ").map(String.init))
    private static let factPattern = try! NSRegularExpression(pattern: #"\b(?:[A-Z][a-zA-Z]+|\d[\d.,/:%-]*)"#)

    /// Names and numbers in `text`, exempting ordinary sentence-opening words.
    static func facts(in text: String, typed: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return factPattern.matches(in: text, range: range).compactMap { match -> String? in
            guard let r = Range(match.range, in: text) else { return nil }
            let word = String(text[r])
            if word.first?.isUppercase == true {
                let before = (typed + text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let ordinaryStarts: Set<String> = ["Thanks", "Thank", "Hello", "Hi", "Please", "The", "This", "That", "I", "We", "You", "It", "Our", "My", "Your", "Can", "Could", "Would", "Let", "See", "Sure"]
                if (before.isEmpty || ".!?\n".contains(before.last!)), ordinaryStarts.contains(word) { return nil }
            }
            return word.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        }
    }

    /// A name or number counts only when a memory line holding it shares a topic word with the text.
    static func attributed(_ fact: String, typed: String, memory: [String]) -> Bool {
        if containsFact(fact, in: typed) { return true }
        let topic = words(typed).subtracting(stopWords)
        return memory.contains { containsFact(fact, in: $0) && !topic.isDisjoint(with: words($0)) }
    }

    private static func containsFact(_ fact: String, in text: String) -> Bool {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: fact) + "(?![\\p{L}\\p{N}])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
    }

    /// One line, ending with the first finished sentence.
    static func firstSentence(_ text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard let end = line.range(of: #"[.!?](?=\s|$)"#, options: .regularExpression) else { return line }
        return String(line[..<end.upperBound])
    }

    /// `pieces` are the model's tokens with their log-probabilities, in order.
    /// `isWord` says whether the word before the cursor is finished ("on", not "o"): only then do
    /// next words make sense.
    public static func gate(_ pieces: [(text: String, logprob: Double)], typed: String, memory: [String],
                            isWord: (String) -> Bool = { _ in true }) -> String {
        var out = ""
        for piece in pieces {
            guard piece.logprob.isFinite else { return "" }
            let isFact = !facts(in: piece.text, typed: typed + out).isEmpty
            if piece.logprob < (isFact ? factMinimum : wordMinimum) {
                if isFact { return "" }  // reaching for a fact it isn't sure of
                break
            }
            let next = out + piece.text
            if next.contains("\n") { break }
            out = next
            if out.range(of: #"[.!?]\s"#, options: .regularExpression) != nil { break }
        }
        out = firstSentence(out)
        for fact in facts(in: out, typed: typed) where !attributed(fact, typed: typed, memory: memory) {
            return ""  // a name or number memory can't back here
        }
        // End on a full thought: no dangling "… on", "… to the".
        var words = out.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        while words.count > 1, stopWords.contains(words.last!.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ","))) {
            words.removeLast()
        }
        var result = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ","))
        if out.hasPrefix(" "), !result.isEmpty { result = " " + result }
        // Never inside a word: the model guesses fragments badly ("exe" → "iting"). After a word it offers
        // the next words; right after a word's last letter, punctuation (lunch → "?") is fine too.
        if let last = typed.last, last.isLetter || last.isNumber, let first = result.first {
            if !first.isWhitespace {
                let next = result.dropFirst().first
                let endsWord = ".,!?;:".contains(first) && (next == nil || next!.isWhitespace)
                if !endsWord { return "" }
            }
            // "stays o" + " in the background": the word being typed isn't finished.
            let word = String(typed.reversed().prefix { $0.isLetter || $0 == "'" || $0 == "’" }.reversed())
            if last.isLetter, !(word.count >= 2 || ["a", "i", "I"].contains(word)) || !isWord(word) { return "" }
        }
        let body = result.trimmingCharacters(in: .whitespaces)
        // Words, or one mark that ends the sentence ("lunch" → "?"); never stray symbols ("|").
        guard body.contains(where: { $0.isLetter || $0.isNumber }) || [".", "?", "!"].contains(body) else { return "" }
        return result
    }
}

// MARK: - The model, in its own process

/// enkeon-complete (llama.cpp's server) on a private localhost port, started on demand.
actor CompletionServer {
    struct Failure: LocalizedError { let errorDescription: String? }

    private let binary: URL
    private let model: URL
    private var process: Process?
    private var port = 0

    init(binary: URL, model: URL) {
        self.binary = binary
        self.model = model
    }

    var isRunning: Bool { process?.isRunning == true }

    /// The helper's process id, so a helper left behind by a crash or a forced quit is stopped next launch.
    private static var pidFile: URL { SentenceCompleter.modelURL.deletingLastPathComponent().appendingPathComponent("enkeon-complete.pid") }

    private func stopLeftover() {
        guard let text = try? String(contentsOf: Self.pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let path = NSRunningApplication(processIdentifier: pid)?.executableURL?.path ?? Self.executablePath(pid),
              path.hasSuffix("/enkeon-complete") else { return }
        kill(pid, SIGTERM)
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }

    func start() async throws {
        try Task.checkCancellation()
        if isRunning { return }
        stopLeftover()
        port = Self.freePort()
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-m", model.path, "--host", "127.0.0.1", "--port", "\(port)", "-ngl", "99", "-c", "2048",
                             "--parallel", "1", "--no-webui", "--log-disable"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        try? "\(process.processIdentifier)".write(to: Self.pidFile, atomically: true, encoding: .utf8)
        for _ in 0..<150 {  // loading the model takes a few seconds the first time
            if await healthy() { return }
            try await Task.sleep(for: .milliseconds(100))
            if !process.isRunning { break }
        }
        stop()
        throw Failure(errorDescription: "The completion model didn't start.")
    }

    func stop() {
        process?.terminate()
        process = nil
        try? FileManager.default.removeItem(at: Self.pidFile)
    }

    private func healthy() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(decoding: data, as: UTF8.self).contains("ok")
    }

    /// Streams a continuation of `prompt`, up to 16 tokens, stopping at the end of a sentence.
    func complete(_ prompt: String) async throws -> [(text: String, logprob: Double)] {
        guard isRunning, let url = URL(string: "http://127.0.0.1:\(port)/completion") else { throw Failure(errorDescription: "not running") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "prompt": prompt, "n_predict": 16, "temperature": 0, "cache_prompt": true, "n_probs": 1, "stream": true, "stop": ["\n"],
        ])
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(errorDescription: "The completion model rejected the request.")
        }
        var pieces: [(text: String, logprob: Double)] = []
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: "), let data = line.dropFirst(6).data(using: .utf8),
                  let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for probability in event["completion_probabilities"] as? [[String: Any]] ?? [] {
                if let token = probability["token"] as? String, let logprob = probability["logprob"] as? Double {
                    pieces.append((token, logprob))
                }
            }
            let text = pieces.map(\.text).joined()
            if event["stop"] as? Bool == true || text.range(of: #"[.!?]\s"#, options: .regularExpression) != nil { break }
        }
        return pieces
    }

    private static func freePort() -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) } }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
