//
//  DictationController.swift
//  EnkeonVoiceKit
//
//  One dictation, start to finish: ⌃⌘ goes down → the focused field is bound
//  (never a password field, never a blocked app) → the microphone records →
//  the keys come up → the transcript is cleaned (spoken "new line", never a
//  model rewrite) → inserted and verified, or kept with an honest reason.
//  Taken from the dictation path in Cookie's CompanionManager (cookie-harness
//  8ffefde), without Cookie's agent, screen and voice-reply branches.
//
//  The bar's own buttons drive the same path hands-free: start, then ✓ to
//  insert or ✕ to drop what was heard.
//

import AppKit
import Carbon.HIToolbox
import Combine

/// What happened to one dictation, for the history and the bar.
public struct DictationRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case inserted, kept, undone, remembered }
    public let id: UUID
    public let date: Date
    public let app: String
    public let text: String
    public let outcome: Outcome
    /// Why it was kept, or what was undone; nil when inserted.
    public let note: String?
    public let durationSeconds: Double
    /// The app's bundle id (nil from older records or apps without one).
    public var bundleID: String? = nil
    /// The words as heard, when the clean-up changed them (nil otherwise).
    public var heard: String? = nil
    /// What the clean-up did: nil when it didn't run, "cleaned", or why the words were kept as heard.
    public var cleanup: String? = nil

    public var wordCount: Int { text.split { $0.isWhitespace || $0.isNewline }.count }
}

@MainActor
public final class DictationController: ObservableObject {
    public enum Phase: Equatable {
        case idle
        /// Recording; `handsFree` when started from the bar (✓ / ✕ end it), else while ⌃⌘ is held.
        case listening(handsFree: Bool)
        case finishing
        /// The last outcome, shown briefly on the bar.
        case done(message: String, success: Bool)
    }

    @Published public private(set) var phase: Phase = .idle
    /// Recent microphone levels (0…1), newest last, for the waveform.
    @Published public private(set) var levels: [CGFloat] = []
    @Published public private(set) var lastError: String?
    /// The words so far, while the person is still talking (the recognizer's partial result).
    @Published public private(set) var liveText = ""
    /// The microphone's level right now, 0…1, smoothed.
    @Published public private(set) var level: CGFloat = 0
    @Published public private(set) var isMicrophoneReady = false
    /// Every key-down between dictations, before the app sees it; true swallows it.
    public var typingKey: ((CGEvent) -> Bool)?

    /// Where dictation goes when the person dictates into Enkeon's own window. The app's own fields are
    /// not reachable through Accessibility the way other apps' are, so the app takes the words itself.
    public var ownWindowSink: ((String) -> Void)?
    private var intoOwnWindow = false

    /// The dictation being finished goes to Enkeon's memory (⇧ was held), not into the field.
    @Published public private(set) var toMemory = false
    @Published public private(set) var isEditing = false
    @Published public private(set) var editScope: String?
    /// Session-only recovery, independent of history retention. Never stores an edit instruction as a result.
    @Published public private(set) var lastResultText = ""
    @Published public private(set) var recoveryText: String?
    /// An answer from memory ("Enkeon, …"), on a card by the orb until Tab types it or Esc closes it.
    @Published public private(set) var answer: MemoryAnswer.Card?
    private var answerDestination: (target: TextDestination?, paste: PasteDestination?)?
    private var answerClose: Task<Void, Never>?
    /// Answers a spoken question from the person's memory; nil when no memory answers it.
    public var askMemory: ((_ question: String) async throws -> MemoryAnswer.Card?)?
    private var editPlan: VoiceEditPlan?

    /// The clean-up style for the app being dictated into ("neutral", "formal", "casual", "lowercase"), or nil
    /// for no clean-up there. Asked at key-down with the app's bundle id and name.
    public var cleanupStyle: ((_ bundleID: String?, _ app: String) -> String?)?

    /// What a dictation asked to be filled in: a snippet, or a memory. The text is inserted as it is.
    public struct Expansion: Sendable {
        public let text: String
        /// For the record and the Context page: "snippet: …" or "filled from memory (id)".
        public let note: String
        public init(text: String, note: String) { self.text = text; self.note = note }
    }

    /// Terms the person fixed by hand after an insertion ("Halverson" → "Halvorsen"), to offer for the dictionary.
    public var onLearned: (([String]) -> Void)?
    private var learnTask: Task<Void, Never>?

    /// Asked with the words as heard; nil when they don't ask for a snippet or a memory.
    public var expand: ((_ transcript: String) async -> Expansion?)?

    /// Names from Enkeon (branches), passed to the recognizer as hints next to the personal vocabulary.
    public var enkeonTerms: [String] = []

    /// Saves a memory dictation to Enkeon. nil: not signed in, so the words are kept here.
    public var saveToMemory: ((_ text: String, _ app: String) async -> (message: String, success: Bool))?
    /// Text selected and an edit said over it ("fix it", "make it shorter"): the selection, changed.
    public var editSelection: ((_ selected: String, _ instruction: String, _ app: String) async throws -> String?)?

    /// Called on the main actor with every finished dictation (inserted, kept or undone).
    public var onRecord: ((DictationRecord) -> Void)?

    /// The engine's speech recognizer, for Settings ("Apple Speech").
    public var engineName: String { dictation.transcriptionProviderDisplayName }
    public var requiresSpeechRecognitionPermission: Bool { dictation.requiresSpeechRecognitionPermission }
    /// Whether ⌃⌘ is being listened for right now.
    public var shortcutIsLive: Bool { shortcuts.isRunning }

    private let dictation = BuddyDictationManager()
    private let shortcuts = GlobalPushToTalkShortcutMonitor()
    private var cancellables: Set<AnyCancellable> = []
    private var interaction = UUID()
    private var startTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var startedAt = Date()
    private var appAtPress = ""
    private var styleAtPress: String?
    private var bundleAtPress: String?
    /// What was selected at key-down, if anything: what a spoken edit acts on.
    private var selectionAtPress = ""
    /// Started by the keys (⌃⌘ or Fn), even if Fn+Space later made it hands-free.
    private var fromKeys = false
    /// ✓-to-memory on the bar.
    private var memoryChosen = false

    public init() {
        // Chrome and Electron apps hide their fields until asked; ask as each app comes to the front,
        // so the field is there by the time the key goes down.
        NSWorkspace.shared.frontmostApplication.map(TextFieldAccess.exposeFields)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { TextFieldAccess.exposeFields($0) }
            .store(in: &cancellables)
        dictation.$isMicrophoneReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isMicrophoneReady = $0 }
            .store(in: &cancellables)
        dictation.$recordedAudioPowerHistory
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.levels = $0 }
            .store(in: &cancellables)
        dictation.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.level = $0 }
            .store(in: &cancellables)
        dictation.$lastErrorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self else { return }
                self.lastError = error
                guard let error else { return }
                switch self.phase {
                case .listening, .finishing:
                    self.resultTask?.cancel()
                    self.show(error, success: false)
                default: break
                }
            }
            .store(in: &cancellables)
        shortcuts.shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                guard let self else { return }
                switch transition {
                // Fn (or ⌃⌘) again during a hands-free dictation ends it.
                case .pressed where self.shortcuts.isDictationShortcut && self.phase == .listening(handsFree: true): self.finish()
                case .pressed where self.shortcuts.isDictationShortcut: self.begin(handsFree: false)
                case .released where self.phase == .listening(handsFree: false): self.finish()
                default: break
                }
            }
            .store(in: &cancellables)
        shortcuts.lateEditModifierPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.cancel()
                self?.show("Hold Option before Fn to ask, or Control before Fn to edit. Nothing was typed.", success: false)
            }
            .store(in: &cancellables)
        shortcuts.recoveryPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self else { return }
                // The chord may have armed recording before C/V arrived.
                if case .listening(handsFree: false) = self.phase { self.cancel() }
                switch action { case .copy: self.copyLast(); case .paste: self.pasteLast() }
            }
            .store(in: &cancellables)
        shortcuts.handsFreePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self, self.phase == .listening(handsFree: false) else { return }
                self.phase = .listening(handsFree: true)
            }
            .store(in: &cancellables)
        // Escape, or ⌃⌘ that turned into a Mac shortcut (⌃⌘Q…): drop what was heard, type nothing.
        shortcuts.previewKey = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return false }
                if self.answer != nil, self.phase == .idle {
                    switch event.getIntegerValueField(.keyboardEventKeycode) {
                    case 48: self.insertAnswer(); return true   // Tab types it
                    case 53: self.closeAnswer(); return true    // Esc closes it
                    default: self.closeAnswer()                 // typing on closes it quietly
                    }
                }
                // Between dictations, keys go to whoever watches typing (sentence completion).
                return self.phase == .idle ? (self.typingKey?(event) ?? false) : false
            }
        }
        Publishers.Merge(shortcuts.cancellationPublisher, shortcuts.dictationAbortPublisher)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.cancel() }
            .store(in: &cancellables)
    }

    /// Listens for ⌃⌘. Needs Accessibility and Input Monitoring; call again once they are granted.
    public func start() {
        shortcuts.start()
        SpeechHelper.shared.start()
    }

    public func stop() {
        cancel()
        shortcuts.stop()
    }

    // MARK: The bar's buttons

    @Published public private(set) var isAskingMemory = false
    public func startMemoryQuestion() { begin(handsFree: true, askingMemory: true) }
    public func startHandsFree() { begin(handsFree: true) }
    public func finishHandsFree() { if phase == .listening(handsFree: true) { finish() } }
    /// Hands-free started from the bar can be sent to memory instead of the field.
    public func finishToMemory() {
        guard !isEditing, !isAskingMemory, phase == .listening(handsFree: true) else { return }
        memoryChosen = true
        finish()
    }

    /// Drops what was heard; nothing is typed.
    public func cancel() {
        guard phase != .idle || startTask != nil else { return }
        interaction = UUID()
        startTask?.cancel()
        startTask = nil
        resultTask?.cancel()
        resultTask = nil
        learnTask?.cancel()
        closeAnswer()
        dictation.cancelCurrentDictation(preserveDraftText: false)
        if case .done = phase { return }
        phase = .idle
    }

    // MARK: One dictation

    private func begin(handsFree: Bool, askingMemory: Bool = false) {
        guard phase != .finishing else { return }
        guard !dictation.isDictationInProgress else { return }
        if case .listening = phase { return }
        clearTask?.cancel()
        resultTask?.cancel()
        learnTask?.cancel()
        closeAnswer()
        interaction = UUID()
        let id = interaction
        let front = NSWorkspace.shared.frontmostApplication
        appAtPress = front?.localizedName ?? "the app"
        bundleAtPress = front?.bundleIdentifier
        styleAtPress = cleanupStyle?(front?.bundleIdentifier, appAtPress)
        if IsSecureEventInputEnabled() || TextFieldAccess.focusedElementIsSecure()
            || TextFieldAccess.blocked(bundleID: front?.bundleIdentifier, category: front.flatMap(TextFieldAccess.category)) {
            show("Dictation is off in password fields and private apps.", success: false)
            return
        }
        isAskingMemory = askingMemory || (!handsFree && shortcuts.askRequested)
        isEditing = !handsFree && shortcuts.editRequested
        editScope = nil
        editPlan = nil
        recoveryText = nil
        if !handsFree && shortcuts.conflictingModifiers {
            show("Use one mode: Option+Fn to ask, Control+Fn to edit, or Shift to save.", success: false)
            return
        }
        // Bound now, at key-down: the field the person was in, never whatever is focused later.
        intoOwnWindow = front?.processIdentifier == getpid() && ownWindowSink != nil
        let target = intoOwnWindow ? nil : TextDestination.capture(forEditing: isEditing)
        let pasteTarget = intoOwnWindow || target != nil ? nil : PasteDestination.capture()
        liveText = ""
        selectionAtPress = target.map(\.selected)
            ?? pasteTarget.flatMap { TextFieldAccess.string($0.element, kAXSelectedTextAttribute) } ?? ""
        if isEditing {
            editPlan = target.flatMap { VoiceEditPlan(value: $0.value, selection: $0.range) }
            if let plan = editPlan {
                guard plan.text.utf16.count <= VoiceEditPlan.maximumLength else {
                    show("Select a shorter passage to edit (up to 6,000 characters).", success: false)
                    return
                }
                editScope = plan.scope.rawValue
            } else if !selectionAtPress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                editScope = "Editing selection"
            } else if target == nil, let pasteTarget,
                      !TextFieldAccess.isTerminal(pid: pasteTarget.pid, element: pasteTarget.element) {
                editScope = "Editing selection · copy only"
            } else {
                show("Select text or focus an editable message before using the edit shortcut.", success: false)
                return
            }
        }
        startedAt = Date()
        fromKeys = !handsFree
        toMemory = false
        memoryChosen = false
        phase = .listening(handsFree: handsFree)
        dictation.updateContextualKeyterms(MemoryAnswer.recognitionHints + DictationText.vocabulary + enkeonTerms + (isEditing ? DictationText.commandHints : []))
        if isEditing { SpeechHelper.shared.warmRewrite(mode: "edit") }
        else if let style = styleAtPress { SpeechHelper.shared.warmCleanup(style: style) }
        let asking = isAskingMemory
        let submit: (String) -> Void = { [weak self] transcript in
            print("🎙️ Dictation: transcript of \(transcript.count) characters reached the controller at \(Date().timeIntervalSince1970)")
            guard let self, self.interaction == id else { return print("🎙️ Dictation: transcript dropped, a newer dictation started") }
            if asking {
                self.ask(transcript, target: target, pasteTarget: pasteTarget, id: id)
            } else if self.toMemory {
                self.remember(transcript, id: id)
            } else {
                self.insert(transcript, into: target, pasteTarget: pasteTarget, id: id)
            }
        }
        let live: (String) -> Void = { [weak self] text in
            guard let self, self.interaction == id else { return }
            self.liveText = text
        }
        startTask = Task {
            if handsFree {
                await dictation.startPersistentDictationFromMicrophoneButton(currentDraftText: "", updateDraftText: live, submitDraftText: submit)
            } else {
                await dictation.startPushToTalkFromKeyboardShortcut(currentDraftText: "", updateDraftText: live, submitDraftText: submit)
            }
            if interaction == id { startTask = nil }
            // The engine couldn't start (permission, microphone): say so instead of a silent bar.
            if interaction == id, !dictation.isDictationInProgress, phase == .listening(handsFree: handsFree) {
                show(dictation.lastErrorMessage ?? "Dictation couldn't start.", success: false)
            }
        }
    }

    private func finish() {
        guard case .listening = phase else { return }
        toMemory = !isEditing && !isAskingMemory && (memoryChosen || (fromKeys && shortcuts.memoryRequested))
        phase = .finishing
        if fromKeys {
            // A press shorter than the engine's start: the start must not outlive the release.
            if !dictation.isMicrophoneReady { startTask?.cancel() }
            startTask = nil
            dictation.stopPushToTalkFromKeyboardShortcut()
        } else {
            dictation.stopPersistentDictationFromMicrophoneButton()
        }
        // The provider owns recognition's deadline. An absent partial is not evidence of
        // silence (batch/sliding-window engines may only publish the final result).
        let id = interaction
        print("🎙️ Dictation: key released at \(Date().timeIntervalSince1970)")
        resultTask = Self.finalTranscriptWatchdog { [weak self] in
            guard let self, self.interaction == id, self.phase == .finishing else { return }
            self.interaction = UUID()
            self.dictation.cancelCurrentDictation(preserveDraftText: false)
            self.show("The transcript didn't arrive, so nothing was typed.", success: false)
        }
    }

    /// Cancellation on a successful final must never execute the timeout action.
    static func finalTranscriptWatchdog(seconds: Double = 30, expired: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled else { return }
            expired()
        }
    }

    private func insert(_ transcript: String, into target: TextDestination?, pasteTarget: PasteDestination?, id: UUID) {
        resultTask?.cancel()
        let app = appAtPress, style = styleAtPress, bundle = bundleAtPress
        let duration = Date().timeIntervalSince(startedAt)
        let editing = isEditing, plan = editPlan, capturedSelection = selectionAtPress
        resultTask = Task {
            guard !Task.isCancelled, interaction == id else { return }
            if editing {
                await performEdit(transcript, target: target, pasteTarget: pasteTarget, plan: plan,
                                  selection: capturedSelection, app: app, bundle: bundle, duration: duration, id: id)
                return
            }
            let undo = DictationText.isUndo(transcript)
            var inserted = transcript
            var tidied = Tidied(text: transcript, heard: nil, note: nil)
            let result: (message: String, success: Bool)
            if undo {
                result = await TextInsertion.shared.undo()
            } else {
                if let expansion = await expand?(transcript) {
                    let replaced = expansion.note.hasPrefix("snippet") || expansion.note.hasPrefix("filled")
                    tidied = Tidied(text: expansion.text, heard: replaced ? transcript : nil, note: expansion.note)
                } else { tidied = await Self.tidy(transcript, style: style) }
                guard !Task.isCancelled, interaction == id else { return }
                let filled = tidied.note.map { $0.hasPrefix("snippet") || $0.hasPrefix("filled") } ?? false
                let terminal = target.map { TextFieldAccess.isTerminal(pid: $0.pid, element: $0.element) }
                    ?? pasteTarget.map { TextFieldAccess.isTerminal(pid: $0.pid, element: $0.element) } ?? false
                inserted = filled ? tidied.text : DictationText.clean(tidied.text, terminal: terminal)
                if terminal { inserted = TextInsertion.terminalSafe(inserted) }
                lastResultText = inserted
                if intoOwnWindow, let sink = ownWindowSink {
                    sink(inserted)
                    result = ("Inserted here.", true)
                } else if let target {
                    result = await TextInsertion.shared.insert(inserted, into: target)
                    if result.success { watchCorrections(target, typed: inserted) }
                } else if let pasteTarget {
                    result = await TextInsertion.shared.insert(inserted, into: pasteTarget)
                } else {
                    result = ("This field doesn't take dictation. Copy your words below.", false)
                }
            }
            guard !Task.isCancelled, interaction == id else { return }
            if !undo, !result.success { recoveryText = inserted }
            var record = DictationRecord(id: UUID(), date: Date(), app: app, text: inserted,
                outcome: undo && result.success ? .undone : (result.success ? .inserted : .kept),
                note: result.success && !undo ? nil : result.message, durationSeconds: duration)
            record.heard = tidied.heard; record.cleanup = tidied.note; record.bundleID = bundle
            onRecord?(record)
            show(result.message, success: result.success)
        }
    }

    private func performEdit(_ instruction: String, target: TextDestination?, pasteTarget: PasteDestination?,
                             plan: VoiceEditPlan?, selection: String, app: String, bundle: String?, duration: Double, id: UUID) async {
        guard instruction.utf16.count <= 2_000 else {
            show("The editing instruction is too long. Try a shorter instruction.", success: false)
            return
        }
        var original = plan?.text ?? selection
        // Copy is a read-only fallback after the keys are released, never permission to replace.
        if original.isEmpty, let pasteTarget, pasteTarget.unchanged(),
           !TextFieldAccess.isTerminal(pid: pasteTarget.pid, element: pasteTarget.element) {
            original = await TextInsertion.copySelection(whileValid: { pasteTarget.unchanged() }) ?? ""
        }
        guard !Task.isCancelled, interaction == id else { return }
        if let target, !target.unchanged() {
            show("The original text or cursor changed. Nothing was edited.", success: false)
            return
        }
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            show("No readable text was selected. Select text or focus an editable message and try again.", success: false)
            return
        }
        guard original.utf16.count <= VoiceEditPlan.maximumLength else {
            show("Select a shorter passage to edit (up to 6,000 characters).", success: false)
            return
        }
        let edited: String?
        do { edited = try await editSelection?(original, instruction, app) }
        catch {
            guard !Task.isCancelled, interaction == id else { return }
            show(error.localizedDescription + " Your original text is unchanged.", success: false)
            return
        }
        guard let revised = edited,
              !revised.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            guard !Task.isCancelled, interaction == id else { return }
            show("The editor couldn't finish. Your original text is unchanged.", success: false)
            return
        }
        guard !Task.isCancelled, interaction == id else { return }
        if revised == original {
            show("No change returned. Your original text is unchanged.", success: false)
            return
        }
        lastResultText = revised
        let result: (message: String, success: Bool)
        if let target, let plan {
            result = await TextInsertion.shared.replace(revised, in: target, plan: plan)
        } else {
            result = ("The revision is ready. This app doesn't expose a safe replacement; copy it below.", false)
        }
        guard !Task.isCancelled, interaction == id else { return }
        if !result.success { recoveryText = revised }
        var record = DictationRecord(id: UUID(), date: Date(), app: app, text: revised,
                                     outcome: result.success ? .inserted : .kept, note: result.message, durationSeconds: duration)
        record.heard = instruction; record.cleanup = "edited by voice"; record.bundleID = bundle
        onRecord?(record)
        show(result.message, success: result.success)
    }

    public func copyLast() {
        guard phase != .finishing else { return }
        if case .listening = phase { return }
        guard !lastResultText.isEmpty else { show("No result to copy yet.", success: false); return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(lastResultText, forType: .string) else {
            show("Couldn't write to the clipboard. Your result is still available here.", success: false)
            return
        }
        recoveryText = nil
        show("Copied. Paste it where you want it.", success: true)
    }

    public func dismissRecovery() {
        recoveryText = nil
        clearTask?.cancel()
        if case .done = phase { phase = .idle }
    }

    public func pasteLast() {
        guard phase != .finishing else { return }
        if case .listening = phase { return }
        guard !lastResultText.isEmpty else { show("No result to paste yet.", success: false); return }
        resultTask?.cancel()
        interaction = UUID()
        isEditing = false
        editScope = nil
        let target = TextDestination.capture()
        let paste = target == nil ? PasteDestination.capture() : nil
        let terminal = target.map { TextFieldAccess.isTerminal(pid: $0.pid, element: $0.element) }
            ?? paste.map { TextFieldAccess.isTerminal(pid: $0.pid, element: $0.element) } ?? false
        let text = terminal ? TextInsertion.terminalSafe(lastResultText) : lastResultText
        clearTask?.cancel()
        phase = .finishing
        let id = interaction
        resultTask = Task {
            guard await TextInsertion.waitForModifierRelease(), !Task.isCancelled, interaction == id else {
                if !Task.isCancelled, interaction == id { show("Release the shortcut keys, then try Paste last again.", success: false) }
                return
            }
            let result: (message: String, success: Bool)
            if let target { result = await TextInsertion.shared.insert(text, into: target) }
            else if let paste { result = await TextInsertion.shared.insert(text, into: paste) }
            else { result = ("Focus an editable field to paste. You can also use Copy last.", false) }
            guard !Task.isCancelled, interaction == id else { return }
            recoveryText = result.success ? nil : text
            show(result.message, success: result.success)
        }
    }

    // MARK: Asking memory

    /// The question is never typed. The orb keeps thinking while memory is asked, then the answer waits
    /// on its card for Tab; it closes on its own after eight seconds.
    private func ask(_ question: String, target: TextDestination?, pasteTarget: PasteDestination?, id: UUID) {
        resultTask?.cancel()
        resultTask = Task {
            let card: MemoryAnswer.Card?
            do { card = try await askMemory?(question) }
            catch {
                guard !Task.isCancelled, interaction == id else { return }
                return show(error.localizedDescription, success: false)
            }
            guard !Task.isCancelled, interaction == id else { return }
            guard let card else { return show("I couldn't find a clear answer in your saved memory.", success: false) }
            answerDestination = (target, pasteTarget)
            answer = card
            phase = .idle
            answerClose?.cancel()
            answerClose = Task {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, answer == card else { return }
                closeAnswer()
            }
        }
    }

    public func closeAnswer() {
        answerClose?.cancel()
        answerClose = nil
        answer = nil
        answerDestination = nil
    }

    /// Tab: the answer goes where the cursor was when the question was asked.
    public func insertAnswer() {
        guard let card = answer, let destination = answerDestination else { return }
        closeAnswer()
        interaction = UUID()
        let id = interaction
        lastResultText = card.text
        resultTask = Task {
            // The Tab is swallowed; give its key-up a moment before typing.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, interaction == id else { return }
            let terminal = destination.target.map { TextFieldAccess.isTerminal(pid: $0.pid, element: $0.element) }
                ?? destination.paste.map { TextFieldAccess.isTerminal(pid: $0.pid, element: $0.element) } ?? false
            let text = terminal ? TextInsertion.terminalSafe(card.text) : card.text
            let result: (message: String, success: Bool)
            if let target = destination.target { result = await TextInsertion.shared.insert(text, into: target) }
            else if let paste = destination.paste { result = await TextInsertion.shared.insert(text, into: paste) }
            else { result = ("This field doesn't take text. Copy the answer with ⌃⌘C.", false) }
            guard !Task.isCancelled, interaction == id else { return }
            if !result.success { recoveryText = text }
            show(result.message, success: result.success)
        }
    }

    private func remember(_ transcript: String, id: UUID) {
        resultTask?.cancel()
        let app = appAtPress
        let style = styleAtPress
        let duration = Date().timeIntervalSince(startedAt)
        resultTask = Task {
            let tidied = await Self.tidy(transcript, style: style)
            guard !Task.isCancelled, interaction == id else { return }
            let text = DictationText.clean(tidied.text)
            lastResultText = text
            let result: (message: String, success: Bool) = await saveToMemory?(text, app)
                ?? ("Sign in to Enkeon to save this to memory. Your words are kept here.", false)
            guard interaction == id else { return }
            if !result.success { recoveryText = text }
            var record = DictationRecord(id: UUID(), date: Date(), app: app, text: text, outcome: result.success ? .remembered : .kept,
                                         note: result.message, durationSeconds: duration)
            record.heard = tidied.heard
            record.cleanup = tidied.note
            record.bundleID = bundleAtPress
            onRecord?(record)
            show(result.message, success: result.success)
        }
    }

    /// One watch at a time: a new dictation replaces the last one's.
    private func watchCorrections(_ target: TextDestination, typed: String) {
        learnTask?.cancel()
        learnTask = Task { [weak self] in
            let terms = await Corrections.watch(target, typed: typed)
            guard !Task.isCancelled, !terms.isEmpty else { return }
            self?.onLearned?(terms)
        }
    }

    struct Tidied {
        let text: String
        let heard: String?
        let note: String?
    }

    /// The model's clean-up when there is a style for this app, the dictation is long enough to need one,
    /// and the result passes `CleanupGuard`; otherwise the words as heard, with the reason.
    static func tidy(_ transcript: String, style: String?) async -> Tidied {
        guard let style else { return Tidied(text: transcript, heard: nil, note: nil) }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Short phrases and "literal …" are typed as said; the commands are handled after.
        if trimmed.split(separator: " ").count < 4 || trimmed.lowercased().hasPrefix("literal ") {
            return Tidied(text: transcript, heard: nil, note: nil)
        }
        guard let cleaned = await SpeechHelper.shared.cleanup(trimmed, style: style), !cleaned.isEmpty else {
            return Tidied(text: transcript, heard: nil, note: "kept as heard: the clean-up model didn't answer in time")
        }
        switch CleanupGuard.check(heard: trimmed, cleaned: cleaned) {
        case .accepted:
            return Tidied(text: cleaned, heard: cleaned == trimmed ? nil : trimmed, note: "cleaned")
        case .rejected(let why):
            return Tidied(text: transcript, heard: nil, note: "kept as heard: the clean-up \(why)")
        }
    }

    private func show(_ message: String, success: Bool) {
        phase = .done(message: message, success: success)
        clearTask?.cancel()
        if recoveryText != nil { return } // Recovery stays until copied or dismissed.
        clearTask = Task {
            try? await Task.sleep(for: .seconds(success ? 1.6 : 4))
            guard !Task.isCancelled, case .done = phase else { return }
            phase = .idle
        }
    }
}
