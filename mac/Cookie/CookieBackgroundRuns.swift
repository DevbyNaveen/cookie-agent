//
//  CookieBackgroundRuns.swift
//  Cookie
//
//  Cookies working while you do something else: routines that run on their
//  schedule, watchers that only speak up when their condition is true, and
//  hand-offs from one Cookie to another. Each run is its own chat, its own
//  helper, and its own face at the screen edge. A background run reads and
//  researches; it never acts on the Mac, so nothing needs a card.
//

import AppKit
import Combine
import Foundation

@MainActor
final class CookieBackgroundRuns: ObservableObject {
    static let shared = CookieBackgroundRuns()
    static let maxParallel = 3
    static let nothingNew = "NOTHING_NEW"

    enum Kind: String { case routine, watcher, handoff, meeting }

    struct Run: Identifiable, Equatable {
        let id: UUID
        let agentID: UUID
        let threadID: UUID
        let title: String
        let kind: Kind
        var step: String
        var history: [String]
        let startedAt: Date
    }

    @Published private(set) var runs: [Run] = []
    weak var companionManager: CompanionManager?
    private var clients: [UUID: HarnessClient] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var scheduler: Timer?

    /// Starts a run for this Cookie; nil when three are already going (the person sees why in the dock title).
    @discardableResult
    func start(agent: CookieAgent, input: String, title: String, kind: Kind,
               onReply: @escaping (String, UUID) -> Void = { _, _ in }) -> UUID? {
        guard let manager = companionManager, runs.count < Self.maxParallel else { return nil }
        let threadID = manager.startBackgroundThread(agentID: agent.id, userText: input)
        let id = UUID()
        let client = HarnessClient()
        clients[id] = client
        runs.append(Run(id: id, agentID: agent.id, threadID: threadID, title: title, kind: kind, step: "Starting", history: [], startedAt: Date()))
        tasks[id] = Task { [weak self] in
            do {
                let model = CookieModelSettings.model
                if let missing = CookieModelSettings.missing(model: model) { throw HarnessClient.HarnessFailure(message: missing) }
                let reply = try await client.run(
                    model: model, input: input,
                    instructions: CompanionManager.instructions(for: agent, background: true),
                    images: [], history: [],
                    onText: { _ in },
                    onStep: { [weak self] step in self?.update(id) { $0.step = step; $0.history.append(step) } },
                    // Unattended: nothing is approved. The model was told it can't act.
                    onApproval: { approval in if let approval { client.approve(approval, allow: false) } }
                )
                guard !Task.isCancelled else { return }
                let steps = self?.runs.first { $0.id == id }?.history ?? []
                manager.appendBackgroundReply(threadID: threadID, text: reply, steps: steps, failed: false)
                onReply(reply, threadID)
            } catch is CancellationError {
                manager.appendBackgroundReply(threadID: threadID, text: "Stopped by you", steps: [], failed: true)
            } catch {
                manager.appendBackgroundReply(threadID: threadID, text: error.localizedDescription, steps: [], failed: true)
            }
            self?.finish(id)
        }
        return id
    }

    func stop(_ id: UUID) {
        tasks[id]?.cancel()
        clients[id]?.shutdown()
        finish(id)
    }

    private func update(_ id: UUID, _ change: (inout Run) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        change(&runs[index])
    }

    private func finish(_ id: UUID) {
        tasks[id] = nil
        clients[id]?.shutdown()
        clients[id] = nil
        runs.removeAll { $0.id == id }
    }

    // MARK: Routines and watchers

    func startScheduler(store: CookieAgentStore = .shared) {
        scheduler?.invalidate()
        scheduler = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fireDueRoutines(store: store) }
        }
    }

    func fireDueRoutines(store: CookieAgentStore, now: Date = Date()) {
        for agent in store.agents {
            var updated = agent
            for routine in agent.routines where routine.nextRun <= now {
                guard let index = updated.routines.firstIndex(where: { $0.id == routine.id }) else { continue }
                // Advance only after admission; a full worker pool leaves it due.
                guard fire(routine, of: agent) else { continue }
                updated.routines[index].lastRun = now
                updated.routines[index].nextRun = routine.cadence.next(after: now)
                store.update(updated)
            }
        }
    }

    /// The run's words: the instruction, and for a watcher the rule that keeps it quiet.
    static func input(for routine: CookieRoutine) -> String {
        guard !routine.onlyWhen.isEmpty else { return routine.instruction }
        return routine.instruction + "\n\nonly tell me if this is true now: \(routine.onlyWhen). if it is not, reply with exactly \(nothingNew) and nothing else."
    }

    @discardableResult
    private func fire(_ routine: CookieRoutine, of agent: CookieAgent) -> Bool {
        let kind: Kind = routine.onlyWhen.isEmpty ? .routine : .watcher
        let title = "\(agent.name): \(routine.instruction.prefix(60))"
        return start(agent: agent, input: Self.input(for: routine), title: title, kind: kind) { [weak self] reply, threadID in
            guard let self, let manager = self.companionManager else { return }
            if reply.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix(Self.nothingNew) {
                manager.deleteThread(threadID) // quiet: nothing to show
                return
            }
            let item = WorkStore.shared.add(title: title, nextStep: "Read what \(agent.name) found", by: "cookie")
            WorkStore.shared.update(item.id, by: "cookie", note: kind == .watcher ? "\(agent.name) noticed something" : "\(agent.name) ran its routine") { $0.threadID = threadID }
            CookieNotifications.shared.post(.reply, threadID: threadID, title: agent.name, body: reply, panelOpen: false)
            manager.replyFinished.send((threadID, CompanionChatMessage(role: .assistant, text: reply)))
        } != nil
    }
}

/// One Cookie hands work to another: a tool the model calls after the person says yes.
@MainActor
enum CookieHandoff {
    /// Who is handing off: the agent of the reply in flight.
    static var currentAgentName: (() -> String?)?

    static let tool = HarnessRequest.Tool(
        name: "hand_off",
        description: "Hand the work to another of the person's Cookies, with a brief it can start from (what's done, what's needed, where things are). The person says yes first. The other Cookie works in its own chat and the Board shows the chain.",
        effect: "outbound",
        schema: .init(properties: ["agent": .init(description: "The other Cookie's name, exactly as it appears."),
                                   "brief": .init(description: "Everything it needs to start, in plain words.")],
                      required: ["agent", "brief"]),
        parallel_safe: false)

    static func question(for action: HarnessAction) -> String? {
        guard action.tool == tool.name else { return nil }
        return "Hand this to \(MacOperator.args(of: action)["agent"] as? String ?? "another Cookie")?"
    }

    static func perform(_ args: [String: Any], from agentName: String?) -> (String, Bool) {
        let name = (args["agent"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let brief = (args["brief"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let agent = CookieAgentStore.shared.agents.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return ("No Cookie is called \(name.isEmpty ? "that" : name). The person's Cookies: " + CookieAgentStore.shared.agents.map(\.name).joined(separator: ", ") + ".", true)
        }
        guard !brief.isEmpty else { return ("hand_off needs a brief.", true) }
        let from = agentName ?? "Cookie"
        let input = "\(from) handed this to you:\n\n\(brief)\n\nTake it from here. Say what you did and what's left."
        let title = "\(agent.name): \(brief.split(separator: "\n").first.map(String.init)?.prefix(60) ?? "handed off")"
        guard let runID = CookieBackgroundRuns.shared.start(agent: agent, input: input, title: title, kind: .handoff, onReply: { reply, threadID in
            CookieNotifications.shared.post(.reply, threadID: threadID, title: agent.name, body: reply, panelOpen: false)
            CookieBackgroundRuns.shared.companionManager?.replyFinished.send((threadID, CompanionChatMessage(role: .assistant, text: reply)))
        }) else {
            return ("Three Cookies are already working; try again when one finishes.", true)
        }
        let threadID = CookieBackgroundRuns.shared.runs.first { $0.id == runID }?.threadID
        let item = WorkStore.shared.add(title: title, nextStep: "Read what \(agent.name) did", column: .cookie, by: "cookie")
        WorkStore.shared.update(item.id, by: "cookie", note: "Handed off from \(from)") { $0.threadID = threadID }
        return ("Handed to \(agent.name). It's working in its own chat; the Board shows it under Cookie's on it.", false)
    }
}
