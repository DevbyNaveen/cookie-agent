import AppKit
import SwiftUI

struct CookieNewAgentView: View {
    @ObservedObject var store: CookieAgentStore
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var navigation: CookieNavigation
    @ObservedObject private var session: CookieCreationSession
    @ObservedObject private var dictation: BuddyDictationManager
    @State private var holding = false
    @State private var routineText = ""
    @State private var routineProblem: String?

    init(store: CookieAgentStore, companionManager: CompanionManager, navigation: CookieNavigation) {
        self.store = store
        self.companionManager = companionManager
        self.navigation = navigation
        self.session = navigation.agentCreation
        self.dictation = companionManager.buddyDictationManager
    }

    private var existing: CookieAgent? {
        if case .profile(let id)? = navigation.agentPage { return store.agent(id) }
        return nil
    }

    private var phase: CookieComposerPhase {
        if companionManager.voiceState == .listening || holding { return .listening }
        if dictation.isDictationInProgress { return .thinking }
        return session.phase
    }

    var body: some View {
        CookieCreationSurface(identity: session.identity, agent: session.draft, isProfile: existing != nil,
                              phase: phase, preparingSpeech: session.preparingSpeech,
                              audioLevel: companionManager.currentAudioPowerLevel,
                              line: session.line, speechProgress: session.speechProgress,
                              lastAnswer: session.lastAnswer, problem: session.problem ?? dictation.lastErrorMessage ?? store.problem,
                              typed: $session.typed, back: { navigation.agentPage = nil },
                              submit: { answer(session.typed) }, beginHolding: beginHolding, endHolding: endHolding,
                              stop: stop, replay: { session.greet(speech: speak) }) {
            if let agent = session.draft { editor(agent) }
        } actions: {
            if let agent = session.draft {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { editorActions(agent) }
                    VStack(alignment: .leading, spacing: 10) { editorActions(agent) }
                }
            }
        } 
        .onAppear(perform: prepare)
        .onDisappear {
            companionManager.transcriptInterceptor = nil
            stop()
        }
        .onChange(of: navigation.agentPage) { _, page in
            if page != nil { prepare() }
        }
        .onReceive(companionManager.globalPushToTalkShortcutMonitor.cancellationPublisher) { _ in stop() }
        .onReceive(companionManager.globalPushToTalkShortcutMonitor.shortcutTransitionPublisher) { transition in
            if transition == .pressed { session.stop() }
        }
    }

    private func prepare() {
        let fresh = session.prepare(page: navigation.agentPage, profile: existing)
        companionManager.transcriptInterceptor = existing == nil ? { answer($0) } : nil
        if fresh { session.greet(speech: speak) }
    }

    private func beginHolding() {
        guard !holding, session.phase != .thinking else { return }
        session.stop()
        companionManager.stopSpeaking()
        holding = true
        companionManager.startTalkingFromButton()
    }

    private func endHolding() {
        guard holding else { return }
        holding = false
        companionManager.stopTalkingFromButton()
    }

    private func stop() {
        session.stop()
        holding = false
        companionManager.stopSpeaking()
        if dictation.isDictationInProgress { companionManager.cancelCurrentInteraction() }
    }

    private func answer(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, session.phase != .thinking else { return }
        companionManager.stopSpeaking()
        session.answer(text, conversation: { history, answer, identity in
            try await companionManager.converseForNewAgent(history: history, answer: answer, id: identity)
        }, speech: speak)
    }

    private func speak(_ text: String, started: @escaping () -> Void, progress: @escaping (Double) -> Void) async {
        await companionManager.speak(text, onPlaybackStarted: started, onPlaybackProgress: progress)
    }

    private func editor(_ agent: CookieAgent) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 20)], alignment: .leading, spacing: 16) {
                field("NAME", placeholder: "A name to call it", path: \.name)
                field("ROLE", placeholder: "Your research companion", path: \.role)
            }
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("WHAT IT HELPS WITH")
                TextField("Describe the help you want.", text: binding(\.detail), axis: .vertical)
                    .font(.system(size: 13)).foregroundStyle(CK.text).lineLimit(2...5)
                    .accessibilityLabel("What this Cookie helps with")
            }
            Rectangle().fill(CK.hairline).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 10) {
                fieldLabel("A NATURAL FIT FOR")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(CookieSpecialist.allCases, id: \.self) { kind in
                        Button { session.draft?.kind = kind } label: {
                            Label(kind.title, systemImage: kind.symbol).font(.system(size: 11, weight: .medium))
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(agent.kind == kind ? CK.accent.opacity(0.16) : .clear, in: Capsule())
                                .overlay(Capsule().strokeBorder(agent.kind == kind ? CK.accent.opacity(0.45) : .clear, lineWidth: 0.75))
                        }
                        .buttonStyle(CookieCreationButtonStyle())
                        .accessibilityAddTraits(agent.kind == kind ? .isSelected : [])
                    }
                }
            }
            if !agent.builtIn {
                Rectangle().fill(CK.hairline).frame(height: 0.5)
                VStack(alignment: .leading, spacing: 10) {
                    fieldLabel("ANSWERS WHEN YOU HOLD THE KEYS IN")
                    Text(agent.apps.isEmpty ? "No apps yet. Pick the apps where this Cookie should take over." : "Hold Control + Option in these apps and this Cookie answers, with what's on screen.")
                        .font(.system(size: 11.5)).foregroundStyle(CK.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(agent.apps, id: \.self) { app in
                            Button { session.draft?.apps.removeAll { $0 == app } } label: {
                                HStack(spacing: 5) {
                                    Text(app).lineLimit(1)
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                                }
                                .font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 7)
                                .background(CK.accent.opacity(0.14), in: Capsule())
                            }
                            .buttonStyle(CookieCreationButtonStyle())
                            .accessibilityLabel("Stop answering in \(app)")
                        }
                        CookieMenu("Add an app", items: runningAppNames.map { name in
                            CookieMenuItem(name, symbol: "app", checked: agent.apps.contains(name)) {
                                if !agent.apps.contains(name) { session.draft?.apps.append(name) }
                            }
                        }) {
                            CookieMenuLabel(title: "Add app", symbol: "plus")
                                .padding(.horizontal, 10).frame(height: 30)
                                .background(CK.fill, in: Capsule())
                        }
                        .help("Apps running now")
                    }
                }
                Rectangle().fill(CK.hairline).frame(height: 0.5)
                VStack(alignment: .leading, spacing: 10) {
                    fieldLabel("ON REPEAT")
                    ForEach(agent.routines) { routine in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: routine.onlyWhen.isEmpty ? "clock.arrow.circlepath" : "eye").font(.system(size: 11)).foregroundStyle(CK.accent).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(routine.instruction).font(.system(size: 12.5)).foregroundStyle(CK.text)
                                Text(routine.cadence.title + (routine.onlyWhen.isEmpty ? "" : " · only when \(routine.onlyWhen)") + " · next \(routine.nextRun.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11)).foregroundStyle(CK.secondary)
                            }
                            Spacer(minLength: 0)
                            IslandButton(symbol: "xmark", help: "Remove this routine", size: 22) {
                                session.draft?.routines.removeAll { $0.id == routine.id }
                            }
                        }
                        .padding(10).background(CK.fill, in: RoundedRectangle(cornerRadius: 10))
                    }
                    TextField("every morning, check what changed with these five companies", text: $routineText, axis: .vertical)
                        .font(.system(size: 12.5)).lineLimit(1...3)
                        .onSubmit(addRoutine)
                        .accessibilityLabel("A new routine: what, and when")
                    Text(routineProblem ?? "Say when: every morning, weekdays at 9, every Monday, every 15 minutes. Add “only when …” to make it a watcher that stays quiet otherwise.")
                        .font(.system(size: 11)).foregroundStyle(routineProblem == nil ? CK.tertiary : WorkColumn.waiting.tint)
                }
            }
        }
        .textFieldStyle(.plain)
        .padding(.horizontal, 4)
    }

    private func addRoutine() {
        guard let routine = CookieRoutine(parsing: routineText) else {
            routineProblem = "I need to know when. Try “every morning”, “weekdays at 9”, “every Monday” or “every 15 minutes”."
            return
        }
        session.draft?.routines.append(routine)
        routineText = ""
        routineProblem = nil
    }

    /// Apps with a window, by name, for the picker.
    private var runningAppNames: [String] {
        Array(Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap(\.localizedName))).sorted()
    }

    private func field(_ title: String, placeholder: String, path: WritableKeyPath<CookieAgent, String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel(title)
            TextField(placeholder, text: binding(path)).font(.system(size: 15, weight: .medium))
                .accessibilityLabel(title.capitalized)
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(CK.secondary)
    }

    @ViewBuilder private func editorActions(_ agent: CookieAgent) -> some View {
        Button {
            guard save() else { return }
            let wish = session.wish
            companionManager.newThread(agent: agent.id)
            navigation.section = .chats
            navigation.agentPage = nil
            session.finish()
            // A new Cookie starts on what the person asked for, right away; a profile just opens the chat.
            if existing == nil, !wish.isEmpty {
                companionManager.sendTypedMessage("You're \(agent.name). Here's what I want from you: \(wish)\n\nStart now. Do the first useful thing, and tell me what you found and what you'd do next.")
            }
        } label: {
            Label(existing == nil ? "Start \(agent.name.isEmpty ? "it" : agent.name) working" : "Chat with \(agent.name.isEmpty ? "your Cookie" : agent.name)", systemImage: "arrow.right")
                .lineLimit(1)
        }
        .buttonStyle(WorkButtonStyle(primary: true))
        .disabled(agent.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if existing != nil {
            Button("Save changes") { if save() { navigation.agentPage = nil; session.finish() } }
                .buttonStyle(WorkButtonStyle(quiet: true))
            if let existing, !existing.builtIn {
                Button {
                    store.remove(existing.id)
                    if store.problem == nil { navigation.agentPage = nil }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(WorkButtonStyle(quiet: true)).help("Delete this Cookie").accessibilityLabel("Delete this Cookie")
            }
        } else {
            Button("Start over") {
                stop()
                session.reset()
                session.greet(speech: speak)
            }
            .buttonStyle(WorkButtonStyle(quiet: true))
        }
    }

    private func binding(_ path: WritableKeyPath<CookieAgent, String>) -> Binding<String> {
        Binding(get: { session.draft?[keyPath: path] ?? "" }, set: { session.draft?[keyPath: path] = $0 })
    }

    private func save() -> Bool {
        guard var agent = session.draft else { return false }
        agent.name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agent.name.isEmpty else { return false }
        if store.agent(agent.id) == nil { store.add(agent) } else { store.update(agent) }
        return store.problem == nil
    }
}
