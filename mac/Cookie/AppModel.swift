import AppKit
import Combine
import EnkeonVoiceKit
import SwiftUI

/// Your words, from Enkeon Voice: the dictation engine Cookie hosts, its history, vocabulary, snippets,
/// styles and Pen (sentence completion). Cookie owns the one DictationController and hands it in;
/// the sign-in is Cookie's.
@MainActor
final class AppModel: ObservableObject {
    static let onboardedKey = "enkeon.onboarding.done"
    static let barWhenIdleKey = "enkeon.bar.showWhenIdle"
    static let cleanupKey = "enkeon.cleanup.enabled"
    static let stylesKey = "enkeon.styles"
    static let learnedKey = "enkeon.dictation.learned"
    static let completeKey = "enkeon.complete.enabled"
    static let completeMemoryKey = "enkeon.complete.memory"
    static let editorProviderKey = "enkeon.editor.provider"
    static let phrasesKey = "enkeon.phrases.enabled"
    static let proofreadKey = "enkeon.proofread.enabled"

    let dictation: DictationController
    /// Finishes the sentence you're typing, in any app.
    let completer = SentenceCompleter()
    let history = HistoryStore()
    let permissions: DictationPermissionCenter
    let account = CookieAccount.shared
    let snippets = SnippetStore()
    /// Sentences you've typed, on this Mac only, so your own phrases come back.
    let phrases = PhraseMemory(file: PhraseMemory.defaultFile)

    /// Branch names from Enkeon, as said aloud ("enkeon-voice" → "enkeon voice"); empty when signed out.
    @Published private(set) var enkeonTerms: [String] = []
    @Published private(set) var enkeonTermsUpdated: Date?
    @Published private(set) var enkeonTermsError: String?
    /// Apple's on-device model, as the helper sees it: nil until asked (or no helper).
    @Published private(set) var cleanupModel: (available: Bool, note: String)?
    @Published private(set) var cleanupChecked = false
    /// Terms the person corrected by hand, waiting for Add or Dismiss in Dictionary.
    @Published private(set) var learned: [String] = UserDefaults.standard.stringArray(forKey: AppModel.learnedKey) ?? []
    /// The style per app, keyed by bundle id (or the app's name when it has none).
    @Published private(set) var styles: [String: String]

    /// nil: no speech helper in this build (the engine uses SFSpeechRecognizer instead).
    @Published private(set) var speechModelReady: Bool?
    @Published private(set) var speechModelNote = "Preparing the speech model…"
    @Published private(set) var editorConnected = false
    private var editorKey: String?
    private var credentialGeneration = UUID()
    private let cloudEditor = CloudVoiceEditor()
    @Published private(set) var shortcutIsLive = false
    /// What macOS does with the 🌐/Fn key on its own (System Settings → Keyboard). Anything but
    /// "Do Nothing" fires alongside Fn dictation. nil: never set here, which macOS treats as the emoji picker.
    @Published private(set) var fnKeyUsage: Int?
    var fnKeyIsFree: Bool { fnKeyUsage == 0 }
    @Published var showOnboarding: Bool
    /// What was dictated into Enkeon's own window (Home's practice field, onboarding's try-it box).
    @Published var practiceText = ""
    /// The page in the window; any page can send the person to another.
    @Published var page: Page = .home

    private var cancellables: Set<AnyCancellable> = []
    private var poll: Timer?
    private var completionEvidence: [String: String] = [:]
    /// Cookie's console shows a page when asked (Your words · Memory).
    var showPage: ((Page) -> Void)?

    init(dictation: DictationController) {
        self.dictation = dictation
        permissions = DictationPermissionCenter(requiresSpeechRecognition: dictation.requiresSpeechRecognitionPermission)
        UserDefaults.standard.register(defaults: [Self.barWhenIdleKey: true])
        if !UserDefaults.standard.bool(forKey: "enkeon.bar.clickLauncherV1") {
            UserDefaults.standard.set(true, forKey: Self.barWhenIdleKey)
            UserDefaults.standard.set(true, forKey: "enkeon.bar.clickLauncherV1")
        }
        showOnboarding = !UserDefaults.standard.bool(forKey: Self.onboardedKey)
        UserDefaults.standard.register(defaults: [Self.cleanupKey: true])
        styles = UserDefaults.standard.dictionary(forKey: Self.stylesKey) as? [String: String] ?? [:]
        dictation.onRecord = { [weak self] in self?.history.add($0) }
        UserDefaults.standard.register(defaults: [Self.completeKey: true, Self.completeMemoryKey: true,
                                                  Self.phrasesKey: true, Self.proofreadKey: true])
        dictation.typingKey = { [weak self] event in self?.completer.key(event) ?? false }
        completer.writerName = NSFullUserName().split(separator: " ").first.map(String.init) ?? "the writer"
        // Your style: things you said and kept, a sentence or more each.
        completer.styleSamples = { [weak self] in
            (self?.history.records ?? []).filter { $0.outcome == .inserted && $0.wordCount >= 4 }.prefix(4).map(\.text)
        }
        // Your memory for the sentence being written, only when you're signed in and allowed it.
        completer.memoryLookup = { [weak self] query in
            guard let self, self.account.isSignedIn, UserDefaults.standard.bool(forKey: Self.completeMemoryKey) else { return [] }
            let branch = UserDefaults.standard.string(forKey: "enkeon.memory.writingBranch") ?? ""
            let reply: String
            do {
                reply = try await branch.isEmpty ? EnkeonClient.shared.recall(query: query, topK: 8)
                    : EnkeonClient.shared.recallMeeting(query: query, branch: branch)
            } catch { return [] }
            guard !Task.isCancelled else { return [] }
            self.completionEvidence = EnkeonClient.completionEvidence(fromRecall: reply)
            return EnkeonClient.completionStatements(fromRecall: reply)
        }
        completer.memoryAttribution = { [weak self] typed, continuation in
            guard let self else { return nil }
            let matches = self.completionEvidence.filter {
                MemorySentenceCompletion.continuation(after: typed, memories: [$0.key]) == continuation
            }
            guard matches.count == 1, let id = matches.first?.value else { return nil }
            return "Enkeon · \(id.suffix(6))"
        }
        completer.usesMemory = { [weak self] in
            self?.account.isSignedIn == true && UserDefaults.standard.bool(forKey: Self.completeMemoryKey)
                && UserDefaults.standard.bool(forKey: Self.completeKey)
        }
        completer.phrases = phrases
        completer.learnsPhrases = { UserDefaults.standard.bool(forKey: Self.phrasesKey) }
        completer.proofreads = { UserDefaults.standard.bool(forKey: Self.proofreadKey) }
        completer.ownWords = { [weak self] in
            guard let self else { return [] }
            return Set((self.vocabularyTerms + self.enkeonTerms).flatMap { $0.lowercased().split(separator: " ").map(String.init) })
        }
        // A finished sentence checked for grammar: Apple's on-device model, in the speech helper.
        completer.rewrite = { [weak self] text, mode, _ in
            guard let self, self.cleanupModel?.available == true else { return nil }
            return await SpeechHelper.shared.rewrite(text, mode: mode)
        }
        // Control+Fn (or Option+Control+Command) explicitly edits the selection or whole message.
        // "Sound like me" takes out the stiff, assistant-sounding phrasing. No samples of your writing go
        // with it: the on-device model copied their words into the text (measured 2026-10-31).
        if UserDefaults.standard.string(forKey: Self.editorProviderKey) == "openai" {
            UserDefaults.standard.set("anthropic", forKey: Self.editorProviderKey)
        }
        refreshEditorCredential()
        dictation.editSelection = { [weak self] selected, instruction, _ in
            guard let self else { return nil }
            if UserDefaults.standard.string(forKey: Self.editorProviderKey) == "apple" {
                guard self.cleanupModel?.available == true else {
                    throw CloudVoiceEditor.Failure("Apple Intelligence is unavailable for editing.")
                }
                return await SpeechHelper.shared.rewrite(selected, mode: "edit", instruction: instruction, deadline: 8)
            }
            return try await self.cloudEditor.edit(selected, instruction: instruction, apiKey: self.editorCredential())
        }
        // Sentence completion follows its switch in Settings.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in UserDefaults.standard.bool(forKey: Self.completeKey) }
            .prepend(UserDefaults.standard.bool(forKey: Self.completeKey))
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.completer.setEnabled(on) }
            .store(in: &cancellables)
        completer.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        dictation.ownWindowSink = { [weak self] text in
            guard let self else { return }
            self.practiceText = self.practiceText.isEmpty ? text : self.practiceText + " " + text
        }
        dictation.onLearned = { [weak self] terms in
            guard let self else { return }
            let known = Set(self.vocabularyTerms.map { $0.lowercased() } + self.learned.map { $0.lowercased() })
            self.setLearned(self.learned + terms.filter { !known.contains($0.lowercased()) })
        }
        dictation.expand = { [weak self] transcript in
            guard let self, let request = self.snippets.request(in: transcript) else { return nil }
            switch request {
            case .snippet(let snippet) where snippet.kind == .text:
                return .init(text: snippet.body, note: "snippet: \(snippet.cue)")
            case .snippet(let snippet):
                return await self.fill(query: snippet.body, from: transcript, label: "snippet “\(snippet.cue)”")
            case .memory(let query):
                return await self.fill(query: query, from: transcript, label: "“\(query)”")
            }
        }
        // "Enkeon, what did we decide about …": answered from memory on a card, typed only on Tab.
        dictation.askMemory = { [weak self] question in
            guard let self else { return nil }
            guard self.account.isSignedIn else { throw CloudVoiceEditor.Failure("Sign in to Enkeon in Connections to ask your memory.") }
            let recall: String
            do { recall = try await EnkeonClient.shared.recall(query: question, topK: 5) }
            catch { throw CloudVoiceEditor.Failure("Can't reach your memory right now.") }
            return try await MemoryAnswer.answer(question, memories: MemoryAnswer.memories(fromRecall: recall), apiKey: self.editorCredential())
        }
        dictation.cleanupStyle = { [weak self] bundleID, app in
            guard let self, UserDefaults.standard.bool(forKey: Self.cleanupKey), self.cleanupModel?.available == true else { return nil }
            let style = self.style(for: bundleID, app: app)
            return style == Style.off.rawValue ? nil : style
        }
        dictation.saveToMemory = { [weak self] text, app in
            guard let self, self.account.isSignedIn else {
                return ("Sign in to Enkeon in Connections to save to memory. Your words are kept here.", false)
            }
            do {
                let reply = try await EnkeonClient.shared.rememberNote(text, app: app)
                let id = EnkeonClient.memoryID(fromReply: reply)
                return (id.map { "Saved to your Enkeon memory (\($0))." } ?? "Saved to your Enkeon memory.", true)
            } catch {
                return ("Couldn't save to Enkeon: \(error.localizedDescription) Your words are kept here.", false)
            }
        }
        account.$phase.receive(on: DispatchQueue.main).sink { [weak self] phase in
            guard let self else { return }
            self.completer.resetMemory()
            self.completionEvidence = [:]
            if phase == .signedIn { Task { await self.refreshEnkeonTerms() } }
            if phase == .signedOut { self.setEnkeonTerms([]) }
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: EnkeonClient.memoryDidChange)
            .sink { [weak self] _ in
                self?.completionEvidence = [:]
                self?.completer.resetMemory()
            }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in UserDefaults.standard.bool(forKey: Self.completeMemoryKey) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.completer.resetMemory() }
            .store(in: &cancellables)
        // Nested objects don't republish on their own: Home and Settings read through this model.
        for publisher in [history.objectWillChange.eraseToAnyPublisher(), permissions.objectWillChange.eraseToAnyPublisher(),
                          dictation.objectWillChange.eraseToAnyPublisher(), account.objectWillChange.eraseToAnyPublisher(),
                          snippets.objectWillChange.eraseToAnyPublisher()] {
            publisher.receive(on: DispatchQueue.main).sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        }
    }

    var isSetUp: Bool { permissions.allAllowed && speechModelReady != false && shortcutIsLive }

    func openPage(_ destination: Page) {
        page = destination
        showPage?(destination)
    }

    /// Cookie's permission poller starts the keyboard; this prepares speech and Enkeon's names.
    func launch() {
        refresh()
        Task { await checkSpeechModel() }
        Task { await refreshEnkeonTerms() }
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshEnkeonTerms() }
        }
    }

    func refresh() {
        permissions.refresh()
        // The shortcut needs Accessibility and Input Monitoring; start() is a no-op while it runs.
        if permissions.shortcutsReady { dictation.start() }
        if shortcutIsLive != dictation.shortcutIsLive { shortcutIsLive = dictation.shortcutIsLive }
        let usage = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
        if fnKeyUsage != usage { fnKeyUsage = usage }
    }

    /// Asks until the model is installed: asking is what starts the install for this app.
    func checkSpeechModel() async {
        speechModelReady = false
        do { try await SpeechHelper.shared.prepareSpeechModel() }
        catch {
            speechModelNote = "The speech model could not load. Check your connection and disk space, then retry."
            return
        }
        for _ in 0..<120 {
            let ready = await SpeechHelper.shared.speechModelReady()
            speechModelReady = ready
            speechModelNote = ready == true ? "Ready on this Mac." : "Preparing the speech model…"
            if ready != false {
                cleanupModel = await SpeechHelper.shared.cleanupAvailability()
                cleanupChecked = true
                if cleanupModel?.available == true { SpeechHelper.shared.warmRewrite(mode: "edit") }
                // The first rewrite would wait seconds for the model to load: load it now.
                if cleanupModel?.available == true, UserDefaults.standard.bool(forKey: Self.proofreadKey) {
                    SpeechHelper.shared.warmRewrite(mode: "fix")
                }
                return
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func refreshEditorCredential() {
        let generation = UUID(); credentialGeneration = generation
        Task { [weak self] in
            let value = await Task.detached { try? VoiceEditorCredentials.read(interactive: false) }.value
            guard let self, self.credentialGeneration == generation else { return }
            self.editorKey = value; self.editorConnected = value?.isEmpty == false
        }
    }

    private func editorCredential() async throws -> String {
        if let editorKey { return editorKey }
        let generation = credentialGeneration
        let value = try await Task.detached { try VoiceEditorCredentials.read() }.value
        try Task.checkCancellation()
        guard credentialGeneration == generation else { throw CancellationError() }
        editorKey = value; editorConnected = value?.isEmpty == false
        return value ?? ""
    }

    func saveEditorKey(_ value: String) throws {
        try VoiceEditorCredentials.save(value)
        refreshEditorCredential()
    }

    func removeEditorKey() {
        VoiceEditorCredentials.remove()
        refreshEditorCredential()
    }

    var vocabularyTerms: [String] {
        (UserDefaults.standard.string(forKey: DictationText.vocabularyKey) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Adds a learned term to the personal vocabulary (the first 100 terms are used).
    func acceptLearned(_ term: String) {
        let vocabulary = UserDefaults.standard.string(forKey: DictationText.vocabularyKey) ?? ""
        UserDefaults.standard.set(vocabulary.isEmpty ? term : vocabulary + "\n" + term, forKey: DictationText.vocabularyKey)
        dismissLearned(term)
    }

    func dismissLearned(_ term: String) { setLearned(learned.filter { $0 != term }) }

    private func setLearned(_ terms: [String]) {
        learned = Array(terms.suffix(50))
        UserDefaults.standard.set(learned, forKey: Self.learnedKey)
    }

    /// The strongest memory on `query`, word for word; the words as heard (with why) when there is none.
    private func fill(query: String, from transcript: String, label: String) async -> DictationController.Expansion {
        guard account.isSignedIn else {
            return .init(text: transcript, note: "kept as heard: sign in to Enkeon to fill \(label) from memory")
        }
        do {
            guard let memory = try await EnkeonClient.shared.strongMemory(for: query) else {
                return .init(text: transcript, note: "kept as heard: nothing in your memory is a strong match for \(label)")
            }
            return .init(text: memory.statement, note: "filled from memory (\(memory.id)) for \(label)")
        } catch {
            return .init(text: transcript, note: "kept as heard: couldn't reach Enkeon (\(error.localizedDescription))")
        }
    }

    /// Asks Enkeon for the branch names again; every half hour while the app runs, and on demand.
    func refreshEnkeonTerms() async {
        guard account.isSignedIn else { return setEnkeonTerms([]) }
        do {
            let names = try await EnkeonClient.shared.branchNames()
            guard account.isSignedIn, !Task.isCancelled else { return }
            setEnkeonTerms(names.map { $0.replacingOccurrences(of: "[-_.]+", with: " ", options: .regularExpression) })
            enkeonTermsUpdated = Date()
            enkeonTermsError = nil
            print("🧠 Enkeon: \(names.count) project names for dictation")
        } catch {
            enkeonTermsError = error.localizedDescription
            print("⚠️ Enkeon: couldn't read project names (\(error.localizedDescription))")
        }
    }

    private func setEnkeonTerms(_ terms: [String]) {
        enkeonTerms = terms
        dictation.enkeonTerms = terms
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardedKey)
        showOnboarding = false
    }

    /// The clean-up step's state, for Connections and Settings.
    var cleanupStatus: String {
        guard UserDefaults.standard.bool(forKey: Self.cleanupKey) else { return "Off: your words are typed as heard" }
        switch cleanupModel {
        case .none: return cleanupChecked ? "Not in this build (no speech helper): typed as heard" : "Checking…"
        case .some(let model) where model.available: return "Apple's on-device model · on this Mac"
        case .some(let model): return "Unavailable here (\(model.note)): typed as heard"
        }
    }

    // MARK: Styles

    enum Style: String, CaseIterable, Identifiable {
        case neutral, formal, casual, lowercase, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .neutral: return "Clean"
            case .formal: return "Formal"
            case .casual: return "Casual"
            case .lowercase: return "lowercase"
            case .off: return "As heard"
            }
        }
        var detail: String {
            switch self {
            case .neutral: return "Fillers out, punctuation in, your tone kept."
            case .formal: return "Complete sentences, for email and documents."
            case .casual: return "Light, like a chat message."
            case .lowercase: return "all lowercase, like a quick text."
            case .off: return "Typed exactly as heard. Best for code and terminals."
            }
        }
    }

    /// Apps whose style is obvious before anyone picks one.
    /// Kinds of app, each with one style; an app's own choice (in `styles`) overrides its group's.
    enum StyleGroup: String, CaseIterable, Identifiable {
        case messages, work, email, code, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .messages: return "Personal messages"
            case .work: return "Work chat"
            case .email: return "Email"
            case .code: return "Code"
            case .other: return "Other"
            }
        }
        /// Bundle ids, verified on a Mac where noted; an app not listed is "Other".
        var bundleIDs: [String] {
            switch self {
            case .messages: return ["com.apple.MobileSMS", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.hnc.Discord"]
            case .work: return ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.anthropic.claudefordesktop"]
            case .email: return ["com.apple.mail", "com.microsoft.Outlook"]
            case .code: return ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                                "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.todesktop.230313mzl4w4u92"]
            case .other: return []
            }
        }
        var defaultStyle: Style {
            switch self {
            case .messages, .work: return .casual
            case .email: return .formal
            case .code: return .off
            case .other: return .neutral
            }
        }
        static func of(_ bundleID: String?) -> StyleGroup {
            allCases.first { $0.bundleIDs.contains(bundleID ?? "") } ?? .other
        }
    }

    static let groupStylesKey = "enkeon.styleGroups"

    func groupStyle(_ group: StyleGroup) -> Style {
        (UserDefaults.standard.dictionary(forKey: Self.groupStylesKey)?[group.rawValue] as? String).flatMap(Style.init(rawValue:))
            ?? group.defaultStyle
    }

    func setGroupStyle(_ style: Style, for group: StyleGroup) {
        var all = UserDefaults.standard.dictionary(forKey: Self.groupStylesKey) as? [String: String] ?? [:]
        all[group.rawValue] = style.rawValue
        UserDefaults.standard.set(all, forKey: Self.groupStylesKey)
        objectWillChange.send()
    }

    func style(for bundleID: String?, app: String) -> String {
        styles[bundleID ?? app] ?? groupStyle(StyleGroup.of(bundleID)).rawValue
    }

    func setStyle(_ style: Style, for key: String) {
        styles[key] = style.rawValue
        UserDefaults.standard.set(styles, forKey: Self.stylesKey)
    }

    // MARK: Vocabulary, a word at a time

    func addTerm(_ term: String) {
        let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !vocabularyTerms.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else { return }
        UserDefaults.standard.set((vocabularyTerms + [clean]).joined(separator: "\n"), forKey: DictationText.vocabularyKey)
        objectWillChange.send()
    }

    func removeTerm(_ term: String) {
        UserDefaults.standard.set(vocabularyTerms.filter { $0 != term }.joined(separator: "\n"), forKey: DictationText.vocabularyKey)
        objectWillChange.send()
    }

    func openConsole() { NSWorkspace.shared.open(Theme.consoleURL) }

    /// System Settings → Keyboard, where "Press 🌐 key to" lives.
    func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
}
