import Foundation
import EnkeonVoiceKit

@MainActor
enum CookieDecisionRecall {
    static let noDecision = "No past decision on this."

    static let tool = HarnessRequest.Tool(
        name: "decision_recall",
        description: "Search only Enkeon memories typed as decisions. Return the stored decision statements with each memory's date and source. If no dated, sourced decision is found, return exactly: No past decision on this. Never infer what the user would decide.",
        effect: "read",
        schema: .init(properties: ["query": .init(description: "The exact topic from the user's question or the visible subject they asked about.")], required: ["query"]))

    static func requested(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("what would i decide here") || lower.contains("what did i decide about")
            || lower.contains("what did we decide about") || lower.contains("what was the decision about")
    }

    static func formatted(_ raw: String) -> String {
        guard let object = firstJSONObject(in: raw),
              let hits = object["hits"] as? [[String: Any]] else { return noDecision }
        let lines = hits.compactMap { hit -> String? in
            guard hit["may_be_outdated"] == nil,
                  !["dropped", "broken"].contains(hit["state"] as? String ?? ""),
                  let statement = hit["statement"] as? String, !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let date = dateLabel(hit),
                  let source = (hit["source_uri"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
                    ?? (hit["id"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
            let changed = CookieRecallProof.of(hit) == .sourceChanged ? CookieRecallProof.changedSuffix : ""
            return "• \(statement.trimmingCharacters(in: .whitespacesAndNewlines)) — \(date) · source: \(source)\(changed)"
        }
        guard !lines.isEmpty else { return noDecision }
        return lines.joined(separator: "\n")
    }

    private static func firstJSONObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
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

    private static func dateLabel(_ hit: [String: Any]) -> String? {
        if let seconds = hit["valid_from"] as? NSNumber {
            return Date(timeIntervalSince1970: seconds.doubleValue).formatted(date: .abbreviated, time: .omitted)
        }
        if let raw = hit["added_at"] as? String {
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: raw) {
                return date.formatted(date: .abbreviated, time: .omitted)
            }
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.timeZone = TimeZone(secondsFromGMT: 0)
            day.dateFormat = "yyyy-MM-dd"
            if let date = day.date(from: raw) { return date.formatted(date: .abbreviated, time: .omitted) }
        }
        return nil
    }

    static func answer(_ query: String) async -> String {
        let topic = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty, CookieAccount.shared.isSignedIn else { return noDecision }
        guard let raw = try? await EnkeonClient.shared.recallDecisions(query: topic) else { return noDecision }
        return formatted(raw)
    }
}
