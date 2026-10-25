import Foundation

struct CookieChangeProposal: Codable, Equatable {
    var outputID: String
    var base: String
    var title: String
    var content: CookieArtifact.Content
    var summary: String
}

enum CookieAssistance: String, Codable, CaseIterable {
    case teach = "Teach me", together = "With me", delegate = "For me"
    var guidance: String {
        switch self {
        case .teach: return "Teach one step at a time, explain why, then wait for the person before the next step. Propose changes for review."
        case .together: return "Collaborate on the selected target. Propose existing-output changes for review and explain the difference briefly."
        case .delegate: return "Complete the requested draft work with minimal narration. Show useful results early. Existing-output changes still require review."
        }
    }
}

extension CookieWorkspaceStore {
    func propose(thread: UUID, artifact: CookieArtifact, content: CookieArtifact.Content, base: String?, title: String, summary: String) throws {
        guard artifact.threadID == thread, artifact.current.id == base else { throw Failure("Read the latest output before proposing a change.") }
        try Self.validateBounds(content, kind: artifact.kind)
        guard session(thread).proposal == nil else { throw Failure("A change is already awaiting review. Ask the person to accept or dismiss it first.") }
        setSession(thread) { $0.proposal = CookieChangeProposal(outputID: artifact.id, base: artifact.current.id, title: title, content: content, summary: summary); $0.showing = true; $0.artifactID = artifact.id }
    }
    func acceptProposal(_ thread: UUID) throws {
        guard let proposal = session(thread).proposal, let artifact = project(thread).first(where: { $0.id == proposal.outputID }) else { throw Failure("No change is awaiting review.") }
        _ = try put(thread: thread, id: artifact.id, title: proposal.title, kind: artifact.kind, content: proposal.content, base: proposal.base, summary: proposal.summary)
        setSession(thread) { $0.proposal = nil; $0.activity = "Accepted: " + proposal.summary }
    }
    func referenceIsCurrent(_ thread: UUID) -> Bool {
        let state = session(thread)
        guard let artifact = selected(thread), !state.selection.isEmpty else { return false }
        if state.selectionRevision == artifact.current.id { return true }
        guard let previous = artifact.revisions.first(where: { $0.id == state.selectionRevision }) else { return false }
        let target = state.selection.components(separatedBy: " | ")[0]
        let before = previous.content, after = artifact.current.content
        switch artifact.kind {
        case .sheet:
            guard let (row, column) = CookieSheet.coordinate(target), before.grid.indices.contains(row), after.grid.indices.contains(row), before.grid[row].indices.contains(column), after.grid[row].indices.contains(column) else { return false }
            // A row insertion or reorder invalidates the reference even if the same value exists elsewhere.
            return before.grid[row] == after.grid[row]
        case .document: return before.blocks.first { $0.id == target } != nil && before.blocks.first { $0.id == target } == after.blocks.first { $0.id == target }
        case .diagram: return before.nodes.first { $0.id == target } != nil && before.nodes.first { $0.id == target } == after.nodes.first { $0.id == target }
        case .html, .scene: return before.body == after.body
        }
    }
    func projectGuidance(_ thread: UUID) -> String {
        let state = session(thread)
        let preference = state.formatPreference ?? ""
        return "\nAssistance: \((state.assistance ?? .together).guidance)\nBuild requested outputs with workspace before a long explanation. When a diagram is requested, create it through workspace and check it before saying it is visible. For leads/research, create a table early and update with retrieved sources; keep unverified entries visibly marked. For linked outputs, record actual dependency revisions; do not claim stale outputs are current.\nUNTRUSTED scratchpad boxes: \(state.scratchNodes?.map(\.label).joined(separator: " → ") ?? "none")\nUNTRUSTED project checkpoint: \(state.checkpoint ?? "none saved yet")\nUNTRUSTED latest activity: \(state.activity.map { String($0.prefix(500)) } ?? "none")\nUser-approved format preference (data): \(preference)\nNext step: \(state.nextStep ?? "none")\nPending change: \(state.proposal?.summary ?? "none"). A proposal is not applied until accepted."
    }
}

/// Foreground and background use separate harnesses. Pausing cancels execution;
/// resuming starts a fresh run from saved outputs and the progress checkpoint.
@MainActor
final class CookieProjectJobs: ObservableObject {
    static let shared = CookieProjectJobs()
    @Published var approvals: [UUID: HarnessApproval] = [:]
    @Published var active: Set<UUID> = []
    private var clients: [UUID: HarnessClient] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UUID] = [:]

    func start(thread: UUID, brief: String) {
        guard !active.contains(thread), active.count < 2, !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let store = CookieWorkspaceStore.shared, generation = UUID(), client = HarnessClient()
        generations[thread] = generation; clients[thread] = client; active.insert(thread); store.quietThreads.insert(thread)
        store.setSession(thread) { $0.jobBrief = brief; $0.jobState = "Running" }
        tasks[thread] = Task { [weak self] in
            do {
                let reply = try await client.run(model: CookieModelSettings.model,
                    input: brief + store.context(thread) + store.projectGuidance(thread),
                    instructions: "Work on this Cookie project quietly. Use workspace for visible outputs. Research through available tools and attach real evidence. Never claim an action succeeded without its result. Record progress using workspace checkpoint. Existing output edits are proposals. Stop after proposing a change until it is reviewed.",
                    images: [], history: [], workspaceThreadID: thread, backgroundProject: true,
                    onText: { _ in }, onStep: { step in
                        guard self?.generations[thread] == generation else { return }
                        store.setSession(thread) { $0.activity = step }
                    }, onApproval: { approval in
                        guard self?.generations[thread] == generation else { return }
                        if let approval, approval.actions.allSatisfy({ $0.tool == "workspace" }) { client.approve(approval, allow: true) }
                        else {
                            self?.approvals[thread] = approval
                            store.setSession(thread) { $0.jobState = approval == nil ? "Running" : "Needs your decision" }
                            if approval != nil { CookieNotifications.shared.post(.reply, threadID: thread, title: "Project needs your decision", body: "Open Project controls to review the requested action.", panelOpen: false) }
                        }
                    })
                guard !Task.isCancelled, self?.generations[thread] == generation else { return }
                store.setSession(thread) { $0.jobState = "Finished"; $0.activity = String(CompanionManager.visibleReply(reply).prefix(2000)) }
                CookieNotifications.shared.post(.reply, threadID: thread, title: "Project ready", body: "Open Cookie to review the result.", panelOpen: false)
            } catch {
                guard !Task.isCancelled, self?.generations[thread] == generation else { return }
                store.setSession(thread) { $0.jobState = "Needs attention"; $0.activity = error.localizedDescription }
            }
            guard self?.generations[thread] == generation else { return }
            self?.finish(thread)
        }
    }
    func answer(_ thread: UUID, answers: [Bool]) {
        guard let approval = approvals[thread] else { return }
        clients[thread]?.approve(approval, answers: answers)
        approvals[thread] = nil
        CookieWorkspaceStore.shared.setSession(thread) { $0.jobState = "Running" }
    }
    func stop(_ thread: UUID, pause: Bool) {
        generations[thread] = UUID(); tasks[thread]?.cancel(); clients[thread]?.shutdown(); finish(thread)
        CookieWorkspaceStore.shared.setSession(thread) { $0.jobState = pause ? "Paused" : "Cancelled" }
    }
    private func finish(_ thread: UUID) {
        clients[thread]?.shutdown(); clients[thread] = nil; tasks[thread] = nil; approvals[thread] = nil; active.remove(thread)
        CookieWorkspaceStore.shared.quietThreads.remove(thread)
    }
}
