import Foundation

@MainActor
enum CookieWorkspaceTool {
    static let tool = HarnessRequest.Tool(name: "workspace", description: "Create, inspect and revise persistent outputs in Cookie's workspace. Use for websites, spreadsheets, documents, diagrams and 3D. Writes are local drafts, never publish or send. Each completed put is immediately visible. Build progressively using several meaningful revisions. Read before editing; base must match the latest revision. Call check before reporting completion, disclose unsupported checks. Actions: list, read, put, check, checkpoint, suggest_format. When the person asks to use a format next time, suggest_format payload {preference} proposes a reusable instruction for their review. For presentations create self-contained HTML slides. Existing-output put stages a reviewable proposal; it does not apply it. Wait for user acceptance before dependent changes. checkpoint payload {summary,nextStep} records progress. Payload is a JSON string. put payload: {id,title,kind,base,summary,content}. kind html uses content.body (self-contained HTML/CSS/JS, no network; add stable element ids); document uses content.blocks [{id,text}]; sheet uses content.grid [[string]] with A1 at grid[0][0] including headers (formulas +,-,*,/,SUM,AVERAGE,MIN,MAX,COUNT); diagram uses content.nodes [{id,label,x,y}] with normalized x/y 0..1 and content.edges [{from,to}]; scene uses content.body containing Cookie SCENE JSON. content.sources [{id,title,url,retrievedAt,target?}] use real sources you retrieved and ISO8601 times; unknowns stay unknown. content.dependencies maps other output IDs to revisions used. Other actions payload {id}. Existing sources and dependencies must be preserved unless intentionally changed. For explanations use [WORK:output-id:target-id] at the relevant spoken phrase (cells A1, block/node/HTML ids, scene part ids).", effect: "write", schema: .init(properties: ["action": .init(description: "list, read, put, check, checkpoint or suggest_format"), "payload": .init(description: "JSON object encoded as a string; use {} for list")], required: ["action", "payload"]), parallel_safe: false)

    static func perform(_ args: [String: Any], thread: UUID, store: CookieWorkspaceStore = .shared) -> (String, Bool) {
        do {
            guard let action = args["action"] as? String,
                  let raw = args["payload"] as? String, raw.utf8.count <= 1_100_000,
                  let data = raw.data(using: .utf8), let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CookieWorkspaceStore.Failure("Provide action and a valid JSON payload string.")
            }
            let id = payload["id"] as? String ?? ""
            let artifact = store.project(thread).first { $0.id == id }
            switch action {
            case "list": return (store.project(thread).map { "\($0.id): \($0.title) (\($0.kind.rawValue)), revision \($0.current.id)" }.joined(separator: "\n"), false)
            case "read":
                guard let artifact else { throw CookieWorkspaceStore.Failure("Output not found in this conversation.") }
                return (String(decoding: try JSONEncoder().encode(artifact.current), as: UTF8.self), false)
            case "check":
                guard let artifact else { throw CookieWorkspaceStore.Failure("Output not found.") }
                let issues = store.checks(artifact)
                let scope = "Checks cover supported formulas, references, sources' metadata, dependency freshness and errors reported by an open HTML preview. They do not verify factual accuracy, every browser interaction, or Excel feature parity."
                return ((issues.isEmpty ? "No issues found in these checks." : issues.joined(separator: "\n")) + "\n" + scope, false)
            case "suggest_format":
                guard let preference = payload["preference"] as? String, !preference.isEmpty, preference.count <= 2000 else { throw CookieWorkspaceStore.Failure("Provide a preference of 1–2000 characters.") }
                store.setSession(thread) { $0.proposedPreference = preference; $0.showing = true }
                return ("Format preference proposed for review in Project controls; not saved as a preference yet.", false)
            case "checkpoint":
                store.setSession(thread) { $0.checkpoint = String((payload["summary"] as? String ?? "").prefix(2000)); $0.nextStep = String((payload["nextStep"] as? String ?? "").prefix(1000)) }
                return ("Project checkpoint saved.", false)
            case "put":
                guard let title = payload["title"] as? String, let kind = CookieArtifact.Kind(rawValue: payload["kind"] as? String ?? ""),
                      let object = payload["content"] as? [String: Any] else { throw CookieWorkspaceStore.Failure("put needs title, kind and content.") }
                let content = try JSONDecoder().decode(CookieArtifact.Content.self, from: JSONSerialization.data(withJSONObject: object))
                if let artifact {
                    guard artifact.kind == kind else { throw CookieWorkspaceStore.Failure("Create a new output to change its format.") }
                    try store.propose(thread: thread, artifact: artifact, content: content, base: payload["base"] as? String, title: title, summary: payload["summary"] as? String ?? "Proposed update")
                    return ("Change proposed, not applied. The person must review and accept it. Do not claim the output has changed.", false)
                }
                let saved = try store.put(thread: thread, id: id, title: title, kind: kind, content: content,
                                          base: payload["base"] as? String, summary: payload["summary"] as? String ?? "Updated output")
                return ("Draft visible in Cookie: \(saved.id), revision \(saved.current.id). " + store.checks(saved).prefix(5).joined(separator: " "), false)
            default: throw CookieWorkspaceStore.Failure("Unknown workspace action.")
            }
        } catch { return (error.localizedDescription, true) }
    }
}
