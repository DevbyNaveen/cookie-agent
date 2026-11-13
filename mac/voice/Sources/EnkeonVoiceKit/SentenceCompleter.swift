//
//  SentenceCompleter.swift
//  EnkeonVoiceKit
//
//  One faded suggestion at the cursor while you type, from the fastest source that has one:
//    1. a spelling fix the Mac is sure of, or the on-device model's fix for a sentence you just
//       finished, shown as the corrected words;
//    2. the rest of a sentence you've written before, in your words (PhraseMemory, no model);
//    3. the rest of the sentence from the completion model, with facts from your Enkeon memory.
//  Tab takes whatever is shown, Esc drops it. (Changing selected text is the dictation keys' job:
//  select, hold, say "fix it".) Never in password fields, blocked apps or terminals;
//  completion also stays out of code editors.
//

import AppKit
import ApplicationServices
import Carbon
import Foundation

@MainActor
public final class SentenceCompleter: ObservableObject {
    public enum Status: Equatable { case off, noModel, starting, ready, failed(String) }
    public enum Source: Equatable { case phrase, memory, model }

    /// A change to text already typed: a spelling fix, or the model's grammar fix.
    public struct Revision: Equatable {
        public enum Kind: Equatable { case spelling, fix }
        public let kind: Kind
        public let original: String
        /// nil while the model is still writing it.
        public internal(set) var revised: String?
        /// Why nothing will come (the model isn't there, nothing to change…).
        public internal(set) var note: String?
        /// Where `original` sits in the field, in UTF-16; nil when only the selection is known.
        let range: NSRange?
        let element: AXUIElement
        /// The words a spelling fix would change, so Esc can leave them alone from then on.
        let misspelled: [String]

        public static func == (a: Self, b: Self) -> Bool {
            a.kind == b.kind && a.original == b.original && a.revised == b.revised && a.note == b.note && a.range == b.range
        }
    }

    @Published public private(set) var suggestion: String?
    @Published public private(set) var source: Source = .model
    @Published public private(set) var sourceLabel: String?
    @Published public private(set) var revision: Revision?
    @Published public private(set) var caret: CGRect?
    @Published public private(set) var status: Status = .off
    /// Suggestions taken with Tab, and shown, since launch.
    @Published public private(set) var accepted = 0
    @Published public private(set) var shown = 0

    /// Memory lines for the sentence being written (the app decides whether Enkeon is asked).
    public var memoryLookup: ((_ query: String) async -> [String])?
    public var memoryAttribution: ((_ typed: String, _ continuation: String) -> String?)?
    public var usesMemory: () -> Bool = { false }
    /// A few things you wrote yourself, for your style.
    public var styleSamples: () -> [String] = { [] }
    public var writerName = "the writer"
    /// Your own phrases, kept on this Mac.
    public var phrases: PhraseMemory?
    public var learnsPhrases: () -> Bool = { false }
    public var proofreads: () -> Bool = { false }
    /// Words that are yours (vocabulary, project names): never "fixed".
    public var ownWords: () -> Set<String> = { [] }
    /// The on-device grammar fix: (text, "fix", app) → the fixed text, or nil.
    public var rewrite: ((_ text: String, _ mode: String, _ app: String) async -> String?)?

    nonisolated public static let modelFile = "gemma-3-1b-pt-Q4_K_M.gguf"
    nonisolated public static var modelURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Enkeon/models/\(modelFile)")
    }

    /// Code editors get their own completion; never compete with it.
    static let codeEditors: Set<String> = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode",
                                           "dev.zed.Zed", "com.sublimetext.4", "com.exafunction.windsurf"]

    private var lifecycle = UUID()
    private var startup: Task<Void, Never>?
    private var suggestionDestination: TextDestination?
    private var server: CompletionServer?
    private var pending: Task<Void, Never>?
    private var field: AXUIElement?
    private var memory: [String] = []
    private var memoryTask: Task<Void, Never>?
    /// What the last memory lookup was about: the sentence being written.
    private var memoryQuery = ""
    private var rejections = 0
    /// How much of the field's text has been learned from (UTF-16), and the text last seen.
    private var learnedUpTo = 0
    private var lastText = ""
    /// Words you turned a fix down for, this session.
    private var ignored: Set<String> = []
    /// Finished sentences the model already checked, and its fix ("" for none).
    private var checked: [String: String] = [:]

    public init() {}

    public func setEnabled(_ on: Bool) {
        guard on else {
            dismiss()
            revision = nil
            resetMemory()
            lifecycle = UUID()
            startup?.cancel()
            let previous = server
            server = nil
            Task { await previous?.stop() }
            status = .off
            return
        }
        guard server == nil else { return }
        guard FileManager.default.fileExists(atPath: Self.modelURL.path) else { status = .noModel; return }
        let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/enkeon-complete")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { status = .failed("enkeon-complete is missing"); return }
        let server = CompletionServer(binary: binary, model: Self.modelURL)
        self.server = server
        lifecycle = UUID()
        let generation = lifecycle
        status = .starting
        startup = Task {
            do {
                try await server.start()
                guard !Task.isCancelled, lifecycle == generation else { return }
                status = .ready
                print("✍️ Sentence completion: ready")
            } catch {
                guard !Task.isCancelled, lifecycle == generation else { return }
                self.server = nil
                status = .failed(error.localizedDescription)
                print("⚠️ Sentence completion: \(error.localizedDescription)")
            }
        }
    }

    public func stop() { setEnabled(false) }

    public func resetMemory() {
        memoryTask?.cancel()
        memoryTask = nil
        memory = []
        memoryQuery = ""
        dismiss()
    }

    // MARK: Keys

    /// Every key-down, before the app sees it. True swallows the key.
    public func key(_ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let command = !flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate])
        let plainTab = code == 48 && !command && !flags.contains(.maskShift)
        if code == 53, revision == nil, suggestion == nil {
            pending?.cancel()
            memoryTask?.cancel()
            memoryTask = nil
            return false
        }
        if let revision {
            if plainTab {
                if revision.revised != nil { apply(revision) }
                return true
            }
            if code == 53 {
                dropRevision()
                return true
            }
            dropRevision()
        }
        if let suggestion {
            if plainTab {
                accept(suggestion)
                return true
            }
            if code == 53 {
                dismiss(rejected: true)
                return true
            }
            // Typing the suggestion's next letters keeps it, shorter.
            if !command, let typed = Self.characters(event), !typed.isEmpty, suggestion.hasPrefix(typed) {
                let rest = String(suggestion.dropFirst(typed.count))
                self.suggestion = rest.trimmingCharacters(in: .whitespaces).isEmpty ? nil : rest
                dismiss()
                schedule()
                return false
            }
            dismiss(rejected: false)
        }
        if command { return false }
        schedule()
        return false
    }

    private static func characters(_ event: CGEvent) -> String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &buffer)
        return length > 0 ? String(utf16CodeUnits: buffer, count: length) : nil
    }

    public func dismiss(rejected: Bool = false) {
        pending?.cancel()
        if rejected { memoryTask?.cancel(); memoryTask = nil }
        if let suggestion, rejected {
            rejections += 1
            if source == .phrase, !lastText.isEmpty { phrases?.feedback(suggestion, after: lastText, accepted: false) }
        }
        suggestion = nil
        suggestionDestination = nil
    }

    /// A spelling fix seen and passed over isn't offered again this session.
    private func dropRevision() {
        if let revision { ignored.formUnion(revision.misspelled.map { $0.lowercased() }) }
        revision = nil
    }

    // MARK: Suggesting

    /// After a short pause in typing: read the field, then the first source with something to offer.
    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            // Back off after rejections: two in a row and it waits longer before offering again.
            let pause = 110 + min(self?.rejections ?? 0, 4) * 150
            try? await Task.sleep(for: .milliseconds(pause))
            guard !Task.isCancelled else { return }
            await self?.suggest()
        }
    }

    private func suggest() async {
        let modelReady = status == .ready
        guard modelReady || usesMemory() || learnsPhrases() || proofreads() else { return }
        guard let context = readField() else { return debug("no eligible text box here") }
        let (element, text, app, bundleID) = context
        if field == nil || !CFEqual(field!, element) {
            field = element
            memoryTask?.cancel()
            memoryTask = nil
            memory = []
            memoryQuery = ""
            rejections = 0
            // What was in the box before you came isn't yours to learn: start at this sentence.
            learnedUpTo = text.utf16.count - PhraseMemory.currentSentence(text).utf16.count
            lastText = text
        }
        if learnsPhrases() { learn(text, app: app) }
        lastText = text

        // 1. A fix for what's already typed.
        if proofreads() {
            if let fix = spellingRevision(text, element: element) { return show(fix) }
            checkFinishedSentence(text, element: element, app: app)
        }
        // 2. Your own words.
        if learnsPhrases(), let rest = phrases?.continuation(after: text) {
            debug("phrase: \(rest.debugDescription)")
            return show(rest, from: .phrase, text: text, element: element)
        }
        // 3. The model, in code editors never.
        guard !Self.codeEditors.contains(bundleID) else { return }
        // Memory follows the sentence being written: a new sentence, or two more words, asks again.
        let sentence = Self.currentSentence(text)
        let newWords = sentence.split(separator: " ").count - memoryQuery.split(separator: " ").count
        if usesMemory(), sentence.count >= 8, sentence != memoryQuery, memoryQuery.isEmpty || !sentence.hasPrefix(memoryQuery) || newWords >= 2 {
            memoryQuery = sentence
            lookUpMemory(sentence)
        }
        // The first pause waits briefly for memory, so facts can be backed.
        if let memoryTask { _ = await Self.within(0.9) { await memoryTask.value } }
        guard !Task.isCancelled else { return }
        if usesMemory() {
            if let rest = MemorySentenceCompletion.continuation(after: text, memories: memory) {
                show(rest, from: .memory, text: text, element: element)
            }
            // Do not let a generative model fill missing personal facts or recombine true facts into a false claim.
            return
        }
        guard modelReady, let server else { return }
        let typed = String(text.suffix(600))
        let prompt = prompt(app: app) + typed
        let started = Date()
        guard let pieces = try? await server.complete(prompt), !Task.isCancelled else { return }
        let shown = CompletionGate.gate(pieces, typed: typed, memory: memory, isWord: Self.isWord)
        debug("\(app), \(memory.count) memories, \(Int(Date().timeIntervalSince(started) * 1000)) ms: "
              + "model \(pieces.map(\.text).joined().debugDescription) → shown \(shown.debugDescription)")
        guard !shown.isEmpty else { return }
        show(shown, from: .model, text: text, element: element)
    }

    /// Shows a continuation if the person hasn't typed on while it was found.
    private func show(_ text: String, from source: Source, text typed: String, element: AXUIElement) {
        guard revision == nil, let now = readField(), CFEqual(now.0, element), now.1 == typed else { return }
        caret = TextFieldAccess.caretRect()
        guard caret != nil else { return debug("the app doesn't say where its cursor is") }
        guard let destination = TextDestination.capture(), CFEqual(destination.element, element) else { return }
        suggestionDestination = destination
        self.source = source
        sourceLabel = source == .memory ? memoryAttribution?(typed, text) : nil
        suggestion = text
        shown += 1
    }

    private func show(_ fix: Revision) {
        caret = TextFieldAccess.caretRect()
        guard caret != nil else { return }
        suggestion = nil
        revision = fix
        shown += 1
        debug("fix: \(fix.original.debugDescription) → \((fix.revised ?? "").debugDescription)")
    }

    // MARK: 1. Fixes

    /// The part of the text that's settled: the sentence the cursor is in (or the one just finished),
    /// without the word still being typed. Its start is in UTF-16.
    nonisolated static func settledRegion(_ text: String) -> (start: Int, text: String) {
        var head = Substring(text)
        if let last = head.last, !last.isWhitespace, !".,!?;:".contains(last) {
            head = head[..<(head.lastIndex(where: \.isWhitespace) ?? head.startIndex)]
        }
        let trimmed = String(head.reversed().drop(while: \.isWhitespace).reversed())
        let sentence = PhraseMemory.currentSentence(trimmed)
        return (trimmed.utf16.count - sentence.utf16.count, sentence)
    }

    private func spellingRevision(_ text: String, element: AXUIElement) -> Revision? {
        let (start, region) = Self.settledRegion(text)
        guard region.contains(" ") || region.count >= 4 else { return nil }
        let mine = ownWords()
        let fixes = Proofreader.spelling(in: region) { [phrases, ignored] word in
            let lower = word.lowercased()
            return ignored.contains(lower) || mine.contains(lower) || phrases?.knows(word) == true
        }
        guard !fixes.isEmpty else { return nil }
        let words = fixes.map { (region as NSString).substring(with: $0.range) }
        return Revision(kind: .spelling, original: region, revised: Proofreader.apply(fixes, to: region), note: nil,
                        range: NSRange(location: start, length: region.utf16.count), element: element, misspelled: words)
    }

    /// Right after a sentence ends, the on-device model reads it once for grammar the spell checker
    /// can't see ("their is", "you're help"). Shown only for a small fix, and only if you paused.
    private func checkFinishedSentence(_ text: String, element: AXUIElement, app: String) {
        guard let rewrite, text.last?.isWhitespace == true,
              text.trimmingCharacters(in: .whitespaces).last.map({ ".!?".contains($0) }) == true else { return }
        let (start, sentence) = Self.settledRegion(text)
        guard sentence.split(separator: " ").count >= 3, checked[sentence] == nil else { return }
        checked[sentence] = ""
        Task { [weak self] in
            guard let fixed = await rewrite(sentence, "fix", app), let self else { return }
            let share = Proofreader.editShare(from: sentence, to: fixed)
            guard fixed != sentence, share > 0, share <= 0.34 else { return }
            self.checked[sentence] = fixed
            // Still paused right there?
            guard self.proofreads(), self.revision == nil, let now = self.readField(), CFEqual(now.0, element), now.1 == text else { return }
            let changed = Proofreader.changes(from: sentence, to: fixed).filter(\.changed).map(\.text)
            self.show(Revision(kind: .fix, original: sentence, revised: fixed, note: nil,
                               range: NSRange(location: start, length: sentence.utf16.count), element: element, misspelled: changed))
        }
    }

    // MARK: 2. Learning your phrases

    /// Learns each sentence once, when it's finished. A message sent without a full stop (the box
    /// empties after Return) is learned when the next one starts.
    private func learn(_ text: String, app: String) {
        guard let phrases else { return }
        let ns = text as NSString, last = lastText as NSString
        let learned = last.substring(to: min(learnedUpTo, last.length))
        if learnedUpTo > ns.length || !text.hasPrefix(learned) {
            let pending = last.substring(from: min(learnedUpTo, last.length)).trimmingCharacters(in: .whitespacesAndNewlines)
            // Sent and replaced by a new message, not deleted back to here.
            if !lastText.hasPrefix(text), !text.hasPrefix(pending) { phrases.learn(pending, app: app) }
            learnedUpTo = 0
        }
        let fresh = ns.substring(from: learnedUpTo)
        let (sentences, end) = PhraseMemory.finishedSentences(fresh)
        for sentence in sentences { phrases.learn(sentence, app: app) }
        learnedUpTo += end
    }

    // MARK: 3. The model

    static func isWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }

    private func debug(_ line: @autoclosure () -> String) {
        #if DEBUG
        print("✍️ \(line())")
        #endif
    }

    /// Runs `work`, giving up after `limit`; true when it finished in time.
    static func within(_ seconds: Double, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        await SpeechHelper.first(within: seconds) { await work(); return "done" } != nil
    }

    private func prompt(app: String) -> String {
        var prompt = ""
        if !memory.isEmpty {
            prompt += "Notes \(writerName) keeps about their work:\n" + memory.map { "- \($0)\n" }.joined() + "\n"
        }
        let samples = styleSamples().prefix(4)
        if !samples.isEmpty {
            prompt += "How \(writerName) writes:\n" + samples.map { "\"\($0)\"\n" }.joined() + "\n"
        }
        return prompt + "A message \(writerName) is writing in \(app):\n"
    }

    /// The sentence the cursor is in (from the last . ! ? or line break), trimmed.
    nonisolated static func currentSentence(_ text: String) -> String {
        let tail = text.suffix(300)
        let start = tail.lastIndex { ".!?\n".contains($0) }.map { tail.index(after: $0) } ?? tail.startIndex
        let sentence = tail[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.isEmpty ? String(tail).trimmingCharacters(in: .whitespacesAndNewlines) : sentence
    }

    private func lookUpMemory(_ query: String) {
        memoryTask?.cancel()
        memory = []
        guard let memoryLookup else { return }
        memoryTask = Task { [weak self] in
            let lines = await memoryLookup(query)
            guard !Task.isCancelled else { return }
            self?.memory = Array(lines.prefix(6))
            self?.memoryTask = nil
            self?.schedule()
            self?.debug("memory lookup: \(min(lines.count, 6)) eligible statements")
        }
    }

    // MARK: Taking it

    private func accept(_ text: String) {
        guard let target = suggestionDestination, target.unchanged() else { dismiss(); return }
        let wasPhrase = source == .phrase
        let typed = lastText
        dismiss()
        Task {
            guard await TextInsertion.shared.insert(text, into: target).success else { return }
            if wasPhrase { phrases?.feedback(text, after: typed, accepted: true) }
            rejections = 0
            accepted += 1
        }
    }

    /// Selects the original words again, checks they're still there, and replaces them; the cursor
    /// goes back to where it was, after the change.
    private func apply(_ revision: Revision) {
        guard let revised = revision.revised else { return }
        self.revision = nil
        accepted += 1
        Task { [weak self] in
            let element = revision.element
            guard let focused = self?.focusedField()?.0, CFEqual(focused, element) else { return }
            var cursor: CFRange?
            if let range = revision.range {
                guard let value = TextFieldAccess.string(element, kAXValueAttribute), NSMaxRange(range) <= (value as NSString).length,
                      (value as NSString).substring(with: range) == revision.original else {
                    self?.debug("the text moved; nothing replaced"); return
                }
                cursor = TextDestination.selectionRange(element)
                var select = CFRange(location: range.location, length: range.length)
                guard let axRange = AXValueCreate(.cfRange, &select),
                      AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success else {
                    self?.debug("couldn’t select the original words"); return
                }
            }
            if let target = TextDestination.capture(), target.selected == revision.original {
                guard await TextInsertion.shared.insert(revised, into: target).success else { return }
            } else {
                return
            }
            // Back to where the cursor was (it was after the change: shift it by the change in length).
            if let range = revision.range, let old = cursor, old.location >= NSMaxRange(range) {
                var back = CFRange(location: old.location + revised.utf16.count - range.length, length: 0)
                if let axRange = AXValueCreate(.cfRange, &back) {
                    AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
                }
            }
        }
    }

    // MARK: The text box

    /// The focused text box and its app, where writing help is welcome (not passwords, blocked apps
    /// or terminals).
    private func focusedField() -> (AXUIElement, String, String)? {
        guard !IsSecureEventInputEnabled(), !TextFieldAccess.focusedElementIsSecure(),
              let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              !TextFieldAccess.blocked(bundleID: app.bundleIdentifier, category: TextFieldAccess.category(app)),
              let element = TextFieldAccess.focusedElement(),
              !TextFieldAccess.isTerminal(pid: app.processIdentifier, element: element) else { return nil }
        return (element, app.localizedName ?? "an app", app.bundleIdentifier ?? "")
    }

    /// The focused text box, its text up to the cursor, the app and its bundle id; only with the
    /// cursor at the end of the text, after a few words, never on a fresh line.
    private func readField() -> (AXUIElement, String, String, String)? {
        guard let (element, app, bundleID) = focusedField().map({ $0 }),
              let value = TextFieldAccess.string(element, kAXValueAttribute), value.utf16.count < 100_000,
              let range = TextDestination.selectionRange(element), range.length == 0 else { return nil }
        let utf16 = Array(value.utf16)
        guard range.location >= 0, range.location <= utf16.count else { return nil }
        let before = String(decoding: utf16[..<range.location], as: UTF16.self)
        let after = String(decoding: utf16[range.location...], as: UTF16.self)
        guard after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              before.trimmingCharacters(in: .whitespaces).count >= 6, before.last != "\n" else { return nil }
        return (element, before, app, bundleID)
    }

    private func refreshCaret() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(25))  // the app moves its cursor after the key
            self?.caret = TextFieldAccess.caretRect()
        }
    }
}
