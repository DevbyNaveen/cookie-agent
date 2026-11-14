//
//  EnkeonClient.swift
//  EnkeonVoiceKit (from Cookie's EnkeonDirect, cookie-harness 8ffefde)
//
//  The app talking to Enkeon over MCP (Streamable HTTP) with the person's
//  sign-in: `remember` for what they say with ⇧, `recall` for context, and
//  `list_branches` for the names dictation should spell right.
//

import Foundation

@MainActor
public final class EnkeonClient {
    public static let shared = EnkeonClient()
    /// Whose sign-in the requests carry. Unset: Enkeon's own account (the standalone app); Cookie sets its own.
    public var tokenSource: (() async -> String?)?
    public static let memoryDidChange = Notification.Name("EnkeonMemoryDidChange")
    private var session: String?
    private var next = 1

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// A spoken note, saved as a memory. Returns Enkeon's reply ("Remembered — … (id …)").
    public func rememberNote(_ text: String, app: String, branch: String? = nil) async throws -> String {
        try await call("remember", [
            "text": text, "purpose": "Said aloud with Enkeon dictation in \(app), to keep.", "kind": NSNull(), "weight": "routine",
            "feeling": NSNull(), "about": NSNull(), "name": NSNull(), "updates": NSNull(), "branch": branch.map { $0 as Any } ?? NSNull(),
            "due": NSNull(), "to": NSNull(), "owner": NSNull(), "resources": NSNull(), "depends_on": NSNull(), "acceptance": NSNull(),
        ])
    }

    public func rememberMeeting(_ text: String, branch: String, title: String, source: String, updates: String?) async throws -> String {
        guard !branch.isEmpty else { throw Failure(message: "Choose a branch before saving meeting memory.") }
        return try await call("remember", [
            "text": text, "purpose": "Reviewed by the user from meeting \(title). Source: \(source)",
            "kind": "fact", "weight": "notable", "feeling": NSNull(), "about": NSNull(), "name": NSNull(),
            "updates": updates.map { $0 as Any } ?? NSNull(), "branch": branch, "due": NSNull(), "to": NSNull(),
            "owner": NSNull(), "resources": [source], "depends_on": NSNull(), "acceptance": NSNull()
        ])
    }

    public func recall(query: String, topK: Int = 3) async throws -> String {
        try await call("recall", [
            "query": query, "top_k": topK, "since": NSNull(), "until": NSNull(), "type": NSNull(), "state": NSNull(),
            "workspace": NSNull(), "branch": NSNull(), "budget_tokens": NSNull(), "as_of": NSNull(), "check": NSNull(),
            "folder": NSNull(),
        ])
    }

    public func recallMeeting(query: String, branch: String?) async throws -> String {
        try await call("recall", ["query": query, "top_k": 3, "branch": branch.map { $0 as Any } ?? NSNull(), "workspace": NSNull(),
            "since": NSNull(), "until": NSNull(), "type": NSNull(), "state": NSNull(), "budget_tokens": 1200,
            "as_of": NSNull(), "check": NSNull(), "folder": NSNull()])
    }

    public struct MemoryCandidate: Identifiable {
        public let id: String
        public let statement: String
        public let revisionID: String?
    }
    nonisolated public static func memoryCandidates(fromRecall text: String) -> [MemoryCandidate] {
        let hits = firstJSONObject(in: text)?["hits"] as? [[String: Any]] ?? []
        return hits.compactMap { hit in
            guard hit["may_be_outdated"] == nil,
                  !["dropped", "broken"].contains(hit["state"] as? String ?? ""),
                  let id = hit["id"] as? String, let statement = hit["statement"] as? String else { return nil }
            return MemoryCandidate(id: id, statement: statement, revisionID: sourceMemoryID(hit))
        }
    }

    /// Extracted fact IDs are retrieval identities, not revision targets. Only a structured
    /// Enkeon source URI can connect them to the saved parent memory.
    nonisolated static func sourceMemoryID(_ hit: [String: Any]) -> String? {
        func valid(_ value: String) -> Bool {
            value.range(of: #"^[0-9A-Z]{20,32}$"#, options: .regularExpression) != nil
        }
        if let source = hit["source_uri"] as? String, let url = URL(string: source),
           url.scheme == "mcp", url.host == "agent", valid(url.lastPathComponent) {
            return url.lastPathComponent
        }
        guard hit["claim_type"] as? String != "atomic-fact",
              let id = hit["id"] as? String, valid(id) else { return nil }
        return id
    }

    /// The best memory for `query`, only when Enkeon calls the match strong; nil otherwise.
    public func strongMemory(for query: String) async throws -> (id: String, statement: String)? {
        Self.strongHit(fromRecall: try await recall(query: query, topK: 1))
    }

    /// `recall` answers with a JSON object (hits, match_quality), sometimes followed by notes in text.
    nonisolated static func strongHit(fromRecall text: String) -> (id: String, statement: String)? {
        guard let object = firstJSONObject(in: text),
              let hit = (object["hits"] as? [[String: Any]])?.first,
              let id = hit["id"] as? String, let statement = hit["statement"] as? String, !statement.isEmpty else { return nil }
        let strong = (object["match_quality"] as? String) == "strong"
            && hit["may_be_outdated"] == nil
            && !["dropped", "broken"].contains(hit["state"] as? String ?? "")
        return strong ? (id, statement) : nil
    }

    /// What a `recall` reply knows, shortest and surest first: the decisions it names as in force
    /// ("- Cookie execution stays on AWS (id …)", after the JSON), then the hits, each cut to about
    /// two sentences so one long memory can't crowd the rest out.
    nonisolated public static func statements(fromRecall text: String) -> [String] {
        let decisions = decisions(in: text)
        let hits = (firstJSONObject(in: text)?["hits"] as? [[String: Any]] ?? []).compactMap { $0["statement"] as? String }
            .map { statement -> String in
                guard statement.count > 220 else { return statement }
                let head = statement.prefix(220)
                return head.range(of: ". ", options: .backwards).map { String(head[..<$0.lowerBound]) + "." } ?? String(head) + "…"
            }
        return (decisions + hits).filter { !$0.isEmpty }
    }

    /// Only current, strongly relevant structured hits are eligible for inline factual suggestions.
    /// Do not turn generic standing instructions or truncated snippets into assertions by the writer.
    nonisolated public static func completionStatements(fromRecall text: String) -> [String] {
        guard let object = firstJSONObject(in: text), object["match_quality"] as? String == "strong",
              let hits = object["hits"] as? [[String: Any]] else { return [] }
        return Array(Set(hits.compactMap { hit -> String? in
            guard hit["may_be_outdated"] == nil,
                  !["dropped", "broken", "silent"].contains(hit["state"] as? String ?? ""),
                  hit["confidence_band"] as? String == "strong",
                  let statement = hit["statement"] as? String, !statement.isEmpty, statement.count <= 1200 else { return nil }
            return statement
        })).sorted().prefix(6).map { $0 }
    }

    nonisolated public static func completionEvidence(fromRecall text: String) -> [String: String] {
        let eligible = Set(completionStatements(fromRecall: text))
        let hits = firstJSONObject(in: text)?["hits"] as? [[String: Any]] ?? []
        var result: [String: String] = [:]
        for hit in hits {
            if let statement = hit["statement"] as? String, eligible.contains(statement),
               let id = sourceMemoryID(hit) ?? hit["id"] as? String {
                result[statement] = id
            }
        }
        return result
    }

    /// The "- …" lines after "Decisions in force", without their ids or dates.
    nonisolated static func decisions(in text: String) -> [String] {
        var decisions: [String] = []
        guard let section = text.range(of: "Decisions in force") else { return [] }
        for line in text[section.upperBound...].split(separator: "\n") {
            guard line.hasPrefix("- ") else { if !decisions.isEmpty { break } else { continue } }
            var item = line.dropFirst(2)
            if let id = item.range(of: " (id ", options: .backwards) { item = item[..<id.lowerBound] }
            if let date = item.range(of: #" \(\d{4}-\d{2}-\d{2}\)$"#, options: .regularExpression) { item = item[..<date.lowerBound] }
            decisions.append(String(item).trimmingCharacters(in: .whitespaces))
        }
        return decisions
    }

    /// The first complete top-level JSON object in `text`, braces matched outside strings.
    nonisolated static func firstJSONObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let json = String(text[start...index])
                    return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The brain's branch names (clients, projects, areas), most used first.
    public func branchNames() async throws -> [String] {
        Self.branchNames(fromListing: try await call("list_branches", ["workspace": NSNull()]))
    }

    /// `list_branches` answers in text: "- name (12 documents, 340 memories)" per branch. Branches
    /// holding nothing (created for a repository and never used) are not vocabulary.
    nonisolated static func branchNames(fromListing text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.hasPrefix("- ") else { return nil }
            let entry = line.dropFirst(2)
            guard let open = entry.range(of: " (") else { return nil }
            let name = entry[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
            let counts = entry[open.upperBound...]
            if counts.hasPrefix("0 documents, 0 memories") { return nil }
            return name.isEmpty ? nil : name
        }
    }

    /// The memory id in a `remember` reply, if it names one.
    nonisolated public static func memoryID(fromReply text: String) -> String? {
        guard let range = text.range(of: #"\(id ([0-9A-Z]{20,32})"#, options: .regularExpression) else { return nil }
        return String(text[range].dropFirst(4))
    }

    private func call(_ tool: String, _ arguments: [String: Any]) async throws -> String {
        for attempt in 0..<2 {
            if session == nil { try await initialize() }
            let (status, body) = try await post(["jsonrpc": "2.0", "id": nextID(), "method": "tools/call",
                                                 "params": ["name": tool, "arguments": arguments]])
            if status == 404, attempt == 0 { session = nil; continue } // the session expired: start a new one
            guard (200...299).contains(status) else { throw Failure(message: "Enkeon answered HTTP \(status)") }
            guard let result = (body["result"] as? [String: Any]) else {
                let message = ((body["error"] as? [String: Any])?["message"] as? String) ?? "Enkeon sent no result"
                throw Failure(message: message)
            }
            let text = ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            if (result["isError"] as? Bool) == true {
                throw Failure(message: String(text.prefix(200)))
            }
            if tool == "remember" || (tool == "tool_invoke" && arguments["name"] as? String == "remember") {
                NotificationCenter.default.post(name: Self.memoryDidChange, object: nil)
            }
            return text
        }
        throw Failure(message: "Enkeon's session kept expiring")
    }

    nonisolated public static func projectListingUnavailable(_ error: Error) -> Bool {
        error.localizedDescription.contains("not available on the directory surface")
    }

    private func initialize() async throws {
        session = nil
        let (status, _) = try await post(["jsonrpc": "2.0", "id": nextID(), "method": "initialize", "params": [
            "protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "enkeon-app", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"],
        ]])
        guard (200...299).contains(status), session != nil else { throw Failure(message: "Couldn't open an Enkeon session (HTTP \(status))") }
        _ = try? await post(["jsonrpc": "2.0", "method": "notifications/initialized"])
        // Read the whole brain. Otherwise Enkeon pins the session to whichever branch the first call
        // names ("Cookies e" → `cookie`), and every later lookup misses what lives elsewhere.
        let (branchStatus, branchBody) = try await post(["jsonrpc": "2.0", "id": nextID(), "method": "tools/call", "params": [
            "name": "use_branch", "arguments": ["branch": NSNull(), "workspace": NSNull(), "private": NSNull()],
        ]])
        guard (200...299).contains(branchStatus), branchBody["error"] == nil,
              let branchResult = branchBody["result"] as? [String: Any],
              branchResult["isError"] as? Bool != true else {
            session = nil
            throw Failure(message: "Couldn’t prepare memory search. Try again.")
        }
    }

    private func nextID() -> Int {
        next += 1
        return next
    }

    private func post(_ message: [String: Any]) async throws -> (Int, [String: Any]) {
        let signedIn: String?
        if let tokenSource { signedIn = await tokenSource() } else { signedIn = await EnkeonAccount.shared.accessToken() }
        guard let token = signedIn else { throw Failure(message: "Not signed in to Enkeon") }
        var request = URLRequest(url: EnkeonAccount.issuer.appendingPathComponent("mcp"))
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
    nonisolated static func body(_ data: Data) -> [String: Any] {
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return object }
        let text = String(decoding: data, as: UTF8.self)
        let json = text.contains("data:")
            ? text.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("data:") }).map { String($0.dropFirst(5)) } ?? ""
            : text
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }
}
