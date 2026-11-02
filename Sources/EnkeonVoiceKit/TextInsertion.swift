import AppKit
import Carbon.HIToolbox

public enum DictationText {
    /// Personal vocabulary, one term per line: spelled as written and passed to the recognizer.
    public static let vocabularyKey = "enkeon.dictation.vocabulary"
    static var vocabulary: [String] {
        Array((UserDefaults.standard.string(forKey: vocabularyKey) ?? "").split(separator: "\n")
            .map { String($0.prefix(80)).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(100))
    }
    /// Recognition hints are used only after Option explicitly selects editing.
    static let commandHints = ["fix it", "make it shorter", "make it longer", "make it more formal", "make it casual",
                               "sound like me", "translate", "rewrite", "bullet points", "proofread"]

    /// "Sound like me", "in my voice", "more human", "less like AI": a rewrite in the person's own voice.
    public static func asksForOwnVoice(_ instruction: String) -> Bool {
        instruction.range(of: #"\b(like me|my voice|my style|how i (write|talk)|more human|humani[sz]e|less (like )?(an )?ai|less robotic)\b"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isUndo(_ text: String) -> Bool {
        ["scratch that", "undo that", "undo dictation"].contains(text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))
    }
    /// `terminal`: the destination runs what it's given, so a line break would be Return. Enkeon never
    /// sends Return; spoken line breaks become spaces there.
    static func clean(_ text: String, terminal: Bool = false, vocabulary: [String] = vocabulary) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.lowercased().hasPrefix("literal ") { result = String(result.dropFirst(8)) } else {
            // Only explicit formatting commands; never rewrite someone's wording through a model.
            // A command ends the utterance or is followed by a new sentence ("…thanks new line Best,"),
            // so "a new line of credit" stays words.
            for (phrase, replacement) in [("new paragraph", "\n\n"), ("new line", "\n")] {
                // Case-insensitive for the phrase only: under a global flag \p{Lu} would match lowercase too.
                result = result.replacingOccurrences(of: "(?i:\\b" + phrase + "\\b)[.,!?]?(?:\\s*$| +(?=\\p{Lu}))", with: replacement,
                                                     options: .regularExpression)
            }
        }
        if terminal {
            result = result.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        for term in vocabulary {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}])"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let matches = expression.matches(in: result, range: NSRange(location: 0, length: result.utf16.count))
            for match in matches.reversed() { result = (result as NSString).replacingCharacters(in: match.range, with: term) }
        }
        return NameCorrection.apply(to: result, terms: vocabulary)
    }
}

/// A text destination is bound at key-down, never rediscovered after a model response.
@MainActor
struct TextDestination {
    let element: AXUIElement
    let pid: pid_t
    let app: String
    let value: String
    let range: CFRange

    var selected: String { (value as NSString).substring(with: NSRange(location: range.location, length: range.length)) }

    static func capture(forEditing: Bool = false) -> TextDestination? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(), !TextFieldAccess.focusedElementIsSecure(),
              let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              !TextFieldAccess.blocked(bundleID: app.bundleIdentifier, category: TextFieldAccess.category(app)),
              let element = TextFieldAccess.focusedElement(),
              (!forEditing || TextFieldAccess.isVerifiedEditable(element)),
              // A terminal shows its whole screen as read-only text; writing to it changes nothing,
              // so terminals take the paste path instead.
              (!TextFieldAccess.isTerminal(pid: app.processIdentifier, element: element)
                || (forEditing && TextFieldAccess.isVerifiedEditable(element))),
              let value = TextFieldAccess.string(element, kAXValueAttribute), value.utf16.count <= 200_000,
              let range = selectionRange(element), range.location >= 0, range.length >= 0,
              range.location <= value.utf16.count, range.length <= value.utf16.count - range.location else { return nil }
        return Self(element: element, pid: app.processIdentifier, app: app.localizedName ?? "the app", value: value, range: range)
    }

    static func selectionRange(_ element: AXUIElement) -> CFRange? {
        guard let raw = TextFieldAccess.attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    func unchanged(requireSelection: Bool = true) -> Bool {
        guard !IsSecureEventInputEnabled(), !TextFieldAccess.focusedElementIsSecure() else { return false }
        return accepts(currentValue: TextFieldAccess.string(element, kAXValueAttribute), currentRange: Self.selectionRange(element),
                       currentPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                       sameElement: TextFieldAccess.focusedElement().map { CFEqual(element, $0) } ?? false,
                       requireSelection: requireSelection)
    }

    func accepts(currentValue: String?, currentRange: CFRange?, currentPID: pid_t?, sameElement: Bool, requireSelection: Bool = true) -> Bool {
        guard currentPID == pid, sameElement, currentValue == value else { return false }
        guard requireSelection else { return true }
        return currentRange?.location == range.location && currentRange?.length == range.length
    }

    func replacing(with text: String) -> String {
        (value as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
    }
}

/// Editors such as web composers and terminals may accept paste without exposing a text range.
@MainActor
final class PasteDestination {
    let element: AXUIElement
    let window: AXUIElement
    let pid: pid_t
    let app: String
    let value: String?
    private var changed = false
    private var monitor: Any?
    private init(element: AXUIElement, window: AXUIElement, application: NSRunningApplication) {
        self.element = element; self.window = window; pid = application.processIdentifier
        app = application.localizedName ?? "the app"; value = TextFieldAccess.string(element, kAXValueAttribute)
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            // Enkeon's own key presses (⌘C to read a selection) aren't the person changing anything.
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == TextInsertion.ownEventMark { return }
            Task { @MainActor in self?.changed = true }
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    static func capture() -> PasteDestination? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(), !TextFieldAccess.focusedElementIsSecure(),
              let application = NSWorkspace.shared.frontmostApplication, application.processIdentifier != getpid(),
              !TextFieldAccess.blocked(bundleID: application.bundleIdentifier, category: TextFieldAccess.category(application)),
              let element = TextFieldAccess.focusedElement(),
              let window = TextFieldAccess.attribute(AXUIElementCreateApplication(application.processIdentifier), kAXFocusedWindowAttribute) else { return nil }
        guard CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let destination = Self(element: element, window: window as! AXUIElement, application: application)
        return destination.monitor == nil ? nil : destination
    }
    func unchanged() -> Bool {
        guard !changed, !IsSecureEventInputEnabled(), !TextFieldAccess.focusedElementIsSecure(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = TextFieldAccess.focusedElement(), CFEqual(focused, element),
              let currentWindow = TextFieldAccess.attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute), CFEqual(currentWindow, window) else { return false }
        return value == nil || value == TextFieldAccess.string(element, kAXValueAttribute)
    }
}

@MainActor
final class TextInsertion {
    static let shared = TextInsertion()
    private struct Receipt {
        let destination: TextDestination
        let inserted: String
        let after: String
    }
    private var receipt: Receipt?

    /// Recheck the original cursor as well as the value before selecting the edit span.
    /// Terminal writes must be direct AX writes; never fall back to appending a paste.
    func replace(_ text: String, in original: TextDestination, plan: VoiceEditPlan) async -> (message: String, success: Bool) {
        guard !Task.isCancelled, original.unchanged(),
              VoiceEditPlan(value: original.value, selection: original.range) == plan else {
            return ("The original text or cursor changed. Your revision is ready to copy.", false)
        }
        guard !text.isEmpty, text.utf16.count <= 20_000 else {
            return ("The revision is too long to insert. Your original text is unchanged.", false)
        }
        var range = CFRange(location: plan.range.location, length: plan.range.length)
        // An existing selection needs no range write. Requiring one excluded
        // editors that allow replacing selected text but expose read-only ranges.
        if range.location != original.range.location || range.length != original.range.length {
            guard let axRange = AXValueCreate(.cfRange, &range),
                  AXUIElementSetAttributeValue(original.element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success else {
                return ("This editor cannot select the original text safely. Copy the revision instead.", false)
            }
        }
        let target = TextDestination(element: original.element, pid: original.pid, app: original.app, value: original.value, range: range)
        let terminal = TextFieldAccess.isTerminal(pid: original.pid, element: original.element)
        let result = await insert(terminal ? Self.terminalSafe(text) : text, into: target, allowPaste: !terminal)
        if !result.success, target.unchanged() {
            var previous = original.range
            if let ax = AXValueCreate(.cfRange, &previous) {
                AXUIElementSetAttributeValue(original.element, kAXSelectedTextRangeAttribute as CFString, ax)
            }
        }
        return result
    }

    static func terminalSafe(_ text: String) -> String {
        text.components(separatedBy: .controlCharacters.union(.newlines)).joined(separator: " ")
    }

    func insert(_ text: String, into destination: TextDestination, allowPaste: Bool = true) async -> (message: String, success: Bool) {
        guard !text.isEmpty, text.utf16.count <= 20_000 else { return ("Dictate between 1 and 20,000 characters.", false) }
        guard !Task.isCancelled, destination.unchanged() else { return ("The original field or selection changed. Your text is kept in Enkeon; nothing was inserted.", false) }
        let expected = destination.replacing(with: text)
        if AXUIElementSetAttributeValue(destination.element, kAXSelectedTextAttribute as CFString, text as CFString) != .success {
            guard allowPaste else { return ("This terminal could not replace the input safely. Copy the revision instead.", false) }
            guard destination.unchanged(), !Task.isCancelled else { return ("The field changed. Nothing was pasted.", false) }
            await pastePreservingClipboard(text)
        }
        // Some editors apply accessibility writes on their next UI turn.
        for _ in 0..<8 {
            if TextFieldAccess.string(destination.element, kAXValueAttribute) == expected {
                receipt = Receipt(destination: destination, inserted: text, after: expected)
                return ("Inserted in \(destination.app). Say “scratch that” with the dictation shortcut to undo.", true)
            }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Never retry an uncertain write: that could duplicate a paragraph.
        receipt = nil
        return ("The editor didn't confirm the insertion. Check the field before trying again; your text is kept in Enkeon.", false)
    }

    func insert(_ text: String, into destination: PasteDestination) async -> (message: String, success: Bool) {
        guard !text.isEmpty, text.utf16.count <= 20000, !Task.isCancelled, destination.unchanged() else {
            return ("The destination changed. Your dictation is kept here; nothing was pasted.", false)
        }
        receipt = nil
        await pastePreservingClipboard(text)
        return ("Pasted into \(destination.app) without sending. This editor cannot confirm its text; check the insertion. Use the app's Undo if needed.", true)
    }

    func undo() async -> (message: String, success: Bool) {
        guard let receipt else { return ("There is no verified dictation to undo.", false) }
        let original = receipt.destination
        let current = TextDestination(element: original.element, pid: original.pid, app: original.app,
                                            value: receipt.after, range: CFRange(location: original.range.location, length: receipt.inserted.utf16.count))
        guard !Task.isCancelled, current.unchanged(requireSelection: false) else {
            return ("The field changed after Enkeon wrote it. I left your newer edits untouched.", false)
        }
        var range = current.range
        guard let axRange = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(current.element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success else {
            return ("This editor doesn't expose an undoable text range. Use its Undo command.", false)
        }
        // Empty replacements are valid for undo, including an insertion into an empty field.
        if AXUIElementSetAttributeValue(current.element, kAXSelectedTextAttribute as CFString, original.selected as CFString) != .success {
            return ("This editor doesn't support direct text undo. Use its Undo command.", false)
        }
        try? await Task.sleep(for: .milliseconds(80))
        guard TextFieldAccess.string(current.element, kAXValueAttribute) == original.value else {
            self.receipt = nil
            return ("The editor didn't confirm undo. Check the text before retrying.", false)
        }
        self.receipt = nil
        return ("Undid the last dictation.", true)
    }

    private func pastePreservingClipboard(_ text: String) async {
        let board = NSPasteboard.general
        let saved = Self.snapshot(board)
        board.clearContents()
        board.setString(text, forType: .string)
        let ownedChange = board.changeCount
        Self.press(kVK_ANSI_V, flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(250))
        // A copy the user made meanwhile belongs to them; never replace it with our saved version.
        if board.changeCount == ownedChange { Self.restore(saved, to: board) }
    }

    // MARK: Any text box: the selection, and replacing it

    /// The selected text in whatever is focused, when Accessibility doesn't say (browsers, Electron
    /// apps, terminals): Enkeon presses ⌘C for you, takes the text, and puts your clipboard back as it
    /// was, images and files included. nil when nothing was selected (the clipboard never changed).
    /// Pressed only after the dictation keys are up, so it can't turn into ⌃⌘C.
    static func copySelection(whileValid: () -> Bool = { true }) async -> String? {
        guard await waitForModifierRelease(), whileValid() else { return nil }
        let board = NSPasteboard.general
        let saved = snapshot(board)
        let before = board.changeCount
        press(kVK_ANSI_C, flags: .maskCommand)
        for _ in 0..<15 where board.changeCount == before {
            guard !Task.isCancelled else { return nil }
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Multiple writes may include a user copy. Preserve the newest clipboard
        // instead of replacing it with the old snapshot or guessing its origin.
        guard !Task.isCancelled, board.changeCount == before + 1 else { return nil }
        let text = board.string(forType: .string)
        restore(saved, to: board)
        return whileValid() && text?.isEmpty == false ? text : nil
    }

    static func waitForModifierRelease() async -> Bool {
        for _ in 0..<100 {
            guard !Task.isCancelled else { return false }
            if CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: [.maskControl, .maskCommand, .maskAlternate, .maskShift, .maskSecondaryFn]) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// Stamped on every key Enkeon presses, so its own watchers can tell them from the person's.
    nonisolated static let ownEventMark: Int64 = 0x456E6B656F6E

    static func press(_ key: Int, flags: CGEventFlags = []) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down)
            event?.flags = flags
            event?.setIntegerValueField(.eventSourceUserData, value: ownEventMark)
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Every item on the clipboard with every type it carries, so nothing is lost putting it back.
    static func snapshot(_ board: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    static func restore(_ saved: [[(NSPasteboard.PasteboardType, Data)]], to board: NSPasteboard) {
        board.clearContents()
        let items = saved.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }
}
