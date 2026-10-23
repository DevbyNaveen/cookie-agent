//
//  CookieAppApprovals.swift
//  Cookie
//
//  Actions in the person's connected apps (Gmail, HubSpot, Slack…) run on
//  Enkeon's gateway through `connector_call`. Anything that sends or deletes
//  is parked there for the person's yes (gateway `person_client.rs`); this is
//  where Cookie shows those cards and answers them on the person's click.
//  The model never reaches this: it only has MCP, which has no approve verb.
//

import Foundation

/// One parked action, as the gateway lists a person's own approvals.
struct GatewayApproval: Decodable, Identifiable, Equatable {
    let id: String
    let slug: String
    let tool: String
    let `class`: String
    let status: String
    /// Exactly what would be sent (the person's own request), when the gateway says.
    let detail: String?
    let expires_at: String?

    var isPending: Bool { status == "pending" }

    /// "Gmail", "HubSpot": the app's name as people write it.
    var appName: String {
        let known = ["gmail": "Gmail", "hubspot": "HubSpot", "googlecalendar": "Google Calendar", "googledrive": "Google Drive",
                     "outlook": "Outlook", "slack": "Slack", "notion": "Notion", "linear": "Linear", "jira": "Jira",
                     "pipedrive": "Pipedrive", "salesforce": "Salesforce", "apollo": "Apollo", "linkedin": "LinkedIn",
                     "asana": "Asana", "clickup": "ClickUp", "attio": "Attio"]
        return known[slug.lowercased()] ?? slug.capitalized
    }

    /// "GMAIL_SEND_EMAIL" → "Send email".
    var actionName: String {
        var words = tool.split(separator: "_").map { $0.lowercased() }
        if let first = words.first, first == slug.lowercased() || known(first) { words.removeFirst() }
        let text = words.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private func known(_ prefix: String) -> Bool { ["gmail", "hubspot", "slack", "outlook", "notion", "linear", "jira"].contains(prefix) }

    var question: String {
        switch self.class {
        case "outbound": return "Send with \(appName)?"
        case "destroy": return "Delete in \(appName)?"
        case "share": return "Share with your team?"
        default: return "Change something in \(appName)?"
        }
    }

    var verb: String {
        switch self.class {
        case "outbound": return "Send"
        case "destroy": return "Delete"
        default: return "Allow"
        }
    }

    static func decideBody(approve: Bool) -> String { approve ? #"{"approve":true}"# : #"{"approve":false}"# }
}

@MainActor
final class CookieAppApprovals: ObservableObject {
    static let shared = CookieAppApprovals()

    @Published private(set) var pending: [GatewayApproval] = []
    @Published private(set) var lastError: String?
    private var watching: Task<Void, Never>?

    /// After Cookie used a connected app: look for parked actions for a while.
    func watch(for duration: TimeInterval = 180) {
        watching?.cancel()
        watching = Task {
            let end = Date().addingTimeInterval(duration)
            while !Task.isCancelled, Date() < end {
                await refresh()
                try? await Task.sleep(for: .seconds(pending.isEmpty ? 4 : 10))
            }
        }
    }

    func refresh() async {
        guard let (token, project) = await credentials() else { return }
        var request = URLRequest(url: CookieAccount.issuer.appendingPathComponent("v1/projects/\(project)/connector-approvals"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let items = try JSONDecoder().decode([GatewayApproval].self, from: data)
            pending = items.filter(\.isPending)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The person's click. Returns why it failed, or nil.
    func decide(_ item: GatewayApproval, approve: Bool) async -> String? {
        guard let (token, project) = await credentials() else { return "Sign in to Enkeon again in Settings → Account." }
        var request = URLRequest(url: CookieAccount.issuer.appendingPathComponent("v1/projects/\(project)/connector-approvals/\(item.id)"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(GatewayApproval.decideBody(approve: approve).utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            pending.removeAll { $0.id == item.id }
            guard (200...299).contains(status) else {
                return "Enkeon didn't take that answer (HTTP \(status)): \(String(decoding: data.prefix(200), as: UTF8.self))"
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func credentials() async -> (String, String)? {
        guard let project = CookieAccount.shared.projectID, let token = await CookieAccount.shared.accessToken() else { return nil }
        return (token, project)
    }
}
