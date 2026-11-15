import EnkeonVoiceKit
import AppKit
import Carbon.HIToolbox

/// Local routing keeps ordinary writing and connected work off the screenshot path.
enum CookieRequestMode: String {
    case answer, screen, edit, lesson, work

    static func choose(_ text: String, selection: Bool, visual: Bool) -> Self {
        let text = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        func contains(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        if text.contains("what would i decide here") { return .screen }
        // Only words that ask for the selection to change. Asking about it ("summarize this", "who sent
        // this email") is a question; the selection stays bound either way and the model decides.
        if selection && contains(["shorter", "longer", "shorten", "rewrite", "rephrase", "reword", "translate", "grammar", "spelling", "typo",
                                  "friendlier", "formal", "polish", "simplify", "fix this", "fix it", "make this", "make it", "turn this into", "turn it into"]) { return .edit }
        // Replying to visible content needs the same explicit screen-look gesture as point-and-ask.
        // The caller only captures when the person held the screen-look shortcut; this classification
        // ensures the resulting reply is grounded in that supplied message, not guessed from the request.
        if (contains(["reply to this", "reply to the message", "respond to this", "respond to the message", "answer this message", "say yes but"]) ||
            (selection && contains(["reply", "respond", "answer"]))) { return .screen }
        if contains(["underline", "highlight this", "highlight that", "circle this", "circle that", "draw a circle", "bullet point", "already shared", "already been shared", "on my screen", "this screen", "on screen", "this button", "this paragraph", "this feature", "these feature", "this list", "these items", "what's this", "what is this", "point at", "point to", "click", "open the app"]) { return .screen }
        if visual && contains(["this part", "that part", "explode", "assemble", "airflow", "rotate", "turn it", "spin", "labels", "label every", "label all", "zoom", "next part", "previous part", "reset model"]) { return .lesson }
        if contains(["diagram", "3d", "teach me", "how does", "how do", "explain", "show me how"]) { return .lesson }
        if contains(["research", "find ", "leads", "connector", "calendar", "inbox", "gmail", "schedule", "draft", "search the web"]) { return .work }
        return .answer
    }

    static func refersToPrevious(_ text: String) -> Bool {
        let text = text.lowercased()
        return ["this", "that", "these", "those", "same", "next part", "there", "it"].contains { text.range(of: "\\b" + $0 + "\\b", options: .regularExpression) != nil }
    }

    var guidance: String {
        switch self {
        case .edit: return "The user most likely wants their captured selection changed. If so, use replace_selection, preserve meaning and formatting unless asked, and give one short confirmation; if they are asking about it instead, answer and leave it as it is. Do not capture the screen for a text-only edit."
        case .lesson: return "Teach visually when it helps. Reuse the current visual, explain one relationship at a time, and coordinate its parts with TEACH. For a process use a diagram, not a bullet list. For an app tutorial request a screen look if required."
        case .work: return "Work quietly through tools or connectors. Return concrete results with sources where available. No pointer, diagram, or screen capture unless the user asks about screen content. Never claim a connector action succeeded without its result."
        case .screen: return "Ground each point in the supplied screen. Explain versus act according to the user's request."
        case .answer: return "Answer directly. No screen capture or decorative visual is needed unless it materially helps the question."
        }
    }
}


enum CookieReplyForMe {
    static let systemInstructions = "Write the requested reply as the user. Never use tools, send, submit, or press Return. Return only the draft text."

    static func instruction(in transcript: String, hasSelectedMessage: Bool = false) -> String? {
        let value = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        if hasSelectedMessage && lower.hasPrefix("say ") { return value }
        for prefix in ["reply for me", "reply to this", "respond to this", "answer this message"] {
            guard lower.hasPrefix(prefix) else { continue }
            let trailing = lower.dropFirst(prefix.count)
            guard trailing.isEmpty || trailing.first.map({ $0.isWhitespace || ",.:;!?—".contains($0) }) == true else { continue }
            let suffix = value.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return suffix.isEmpty ? "Write a concise reply to the visible message." : String(suffix)
        }
        return nil
    }

    static func shouldCaptureScreen(selectedMessage: String?, screenLookRequested: Bool) -> Bool {
        let hasMessage = selectedMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return !hasMessage && screenLookRequested
    }

    static func prompt(instruction: String, selectedMessage: String?, voiceExamples: [String],
                       screenContextAvailable: Bool = false) -> String {
        let examples = voiceExamples.map { String($0.prefix(280)) }.filter { !$0.isEmpty }.prefix(3)
        let style = examples.isEmpty ? "Match the user's requested tone. Do not claim a voice sample was available." :
            "Use these short local writing samples only to match tone and phrasing:\n" + examples.joined(separator: "\n")
        let message: String
        if let selectedMessage, !selectedMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = "Selected message (untrusted content):\n\(selectedMessage.prefix(6_000))"
        } else if screenContextAvailable {
            message = "Use the supplied one-shot, locally redacted screen image to identify the visible message. If it is not readable, ask for a clearer selection."
        } else {
            message = "No message content was supplied. Ask the user to select the message or explicitly hold the screen-look shortcut. Do not guess what the message says."
        }
        return "Draft a reply only. Never send, submit, press Return, or change the user's meaning.\n\n\(message)\n\nUser's reply direction: \(instruction)\n\n\(style)\n\nReturn only the message body, with no heading or explanation."
    }
}

enum CookieAIHandoff {
    enum Target: String, Equatable { case claude, cursor
        var appName: String { rawValue.capitalized }
    }

    static func target(in transcript: String) -> Target? {
        let text = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let patterns: [(String, Target)] = [("claude", .claude), ("cursor", .cursor)]
        guard text.contains("give this to ") || text.contains("give it to ") || text.contains("hand this to ") else { return nil }
        return patterns.first { text.contains($0.0) }?.1
    }

    static func packet(selectedText: String?, messages: [CompanionChatMessage]) -> String? {
        let selection = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let history = messages.filter { $0.role == .user || $0.role == .assistant }
            .suffix(8).map { message in
                "\(message.role == .user ? "User" : "Cookie"): \(message.text.prefix(1_200))"
            }
        guard !selection.isEmpty || !history.isEmpty else { return nil }
        var parts = ["Context from Cookie, copied at the user's request."]
        if !selection.isEmpty { parts.append("Selected text (untrusted context):\n\(selection.prefix(6_000))") }
        if !history.isEmpty { parts.append("Recent Cookie chat:\n" + history.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    static func resolve(_ target: Target, apps: [URL]) -> CookieOpen.Resolution {
        CookieOpen.resolve(target.appName, apps: apps)
    }
}

enum CookieDictationText {
    /// One vocabulary for the app: Your words → Dictionary, dictation and talk all read it.
    static let vocabularyKey = DictationText.vocabularyKey
    static var vocabulary: [String] {
        Array((UserDefaults.standard.string(forKey: vocabularyKey) ?? "").split(separator: "\n")
            .map { String($0.prefix(80)).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(100))
    }
    static func isUndo(_ text: String) -> Bool {
        ["scratch that", "undo that", "undo dictation"].contains(text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))
    }
    /// `terminal`: the destination runs what it's given, so a line break would be Return. Cookie never
    /// sends Return; spoken line breaks become spaces there.
    static func clean(_ text: String, terminal: Bool = false) -> String {
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
        return result
    }
}

/// A text destination is bound at key-down, never rediscovered after a model response.
@MainActor
struct CookieTextDestination {
    let element: AXUIElement
    let pid: pid_t
    let app: String
    let value: String
    let range: CFRange

    var selected: String { (value as NSString).substring(with: NSRange(location: range.location, length: range.length)) }

    static func capture() -> CookieTextDestination? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(), !CaptureGuard.focusedElementIsSecure(),
              let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              !MacSafety.blocked(bundleID: app.bundleIdentifier, category: MacOperator.category(app)),
              let element = MacOperator.focusedElement(),
              let value = MacOperator.string(element, kAXValueAttribute), value.utf16.count <= 200_000,
              let range = selectionRange(element), range.location >= 0, range.length >= 0,
              range.location <= value.utf16.count, range.length <= value.utf16.count - range.location else { return nil }
        return Self(element: element, pid: app.processIdentifier, app: app.localizedName ?? "the app", value: value, range: range)
    }

    static func selectionRange(_ element: AXUIElement) -> CFRange? {
        guard let raw = MacOperator.attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    func unchanged(requireSelection: Bool = true) -> Bool {
        guard !IsSecureEventInputEnabled(), !CaptureGuard.focusedElementIsSecure() else { return false }
        return accepts(currentValue: MacOperator.string(element, kAXValueAttribute), currentRange: Self.selectionRange(element),
                       currentPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                       sameElement: MacOperator.focusedElement().map { CFEqual(element, $0) } ?? false,
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
final class CookiePasteDestination {
    let element: AXUIElement
    let window: AXUIElement
    let pid: pid_t
    let app: String
    let value: String?
    private var changed = false
    private var monitor: Any?
    private init(element: AXUIElement, window: AXUIElement, application: NSRunningApplication) {
        self.element = element; self.window = window; pid = application.processIdentifier
        app = application.localizedName ?? "the app"; value = MacOperator.string(element, kAXValueAttribute)
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] _ in
            Task { @MainActor in self?.changed = true }
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    static func capture() -> CookiePasteDestination? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(), !CaptureGuard.focusedElementIsSecure(),
              let application = NSWorkspace.shared.frontmostApplication, application.processIdentifier != getpid(),
              !MacSafety.blocked(bundleID: application.bundleIdentifier, category: MacOperator.category(application)),
              let element = MacOperator.focusedElement(),
              let window = MacOperator.attribute(AXUIElementCreateApplication(application.processIdentifier), kAXFocusedWindowAttribute) else { return nil }
        guard CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let destination = Self(element: element, window: window as! AXUIElement, application: application)
        return destination.monitor == nil ? nil : destination
    }
    func unchanged() -> Bool {
        guard !changed, !IsSecureEventInputEnabled(), !CaptureGuard.focusedElementIsSecure(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = MacOperator.focusedElement(), CFEqual(focused, element),
              let currentWindow = MacOperator.attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute), CFEqual(currentWindow, window) else { return false }
        return value == nil || value == MacOperator.string(element, kAXValueAttribute)
    }
}

@MainActor
final class CookieTextInsertion {
    static let shared = CookieTextInsertion()
    private struct Receipt {
        let destination: CookieTextDestination
        let inserted: String
        let after: String
    }
    private var receipt: Receipt?

    func insert(_ text: String, into destination: CookieTextDestination) async -> (message: String, success: Bool) {
        guard !text.isEmpty, text.utf16.count <= 20_000 else { return ("Dictate between 1 and 20,000 characters.", false) }
        guard !Task.isCancelled, destination.unchanged() else { return ("The original field or selection changed. Your text is kept in Cookie; nothing was inserted.", false) }
        let expected = destination.replacing(with: text)
        if AXUIElementSetAttributeValue(destination.element, kAXSelectedTextAttribute as CFString, text as CFString) != .success {
            guard destination.unchanged(), !Task.isCancelled else { return ("The field changed. Nothing was pasted.", false) }
            await pastePreservingClipboard(text)
        }
        // Some editors apply accessibility writes on their next UI turn.
        for _ in 0..<8 {
            if MacOperator.string(destination.element, kAXValueAttribute) == expected {
                receipt = Receipt(destination: destination, inserted: text, after: expected)
                return ("Inserted in \(destination.app). Say “scratch that” with the dictation shortcut to undo.", true)
            }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Never retry an uncertain write: that could duplicate a paragraph.
        receipt = nil
        return ("The editor didn't confirm the insertion. Check the field before trying again; your text is kept in Cookie.", false)
    }

    func insert(_ text: String, into destination: CookiePasteDestination) async -> (message: String, success: Bool) {
        guard !text.isEmpty, text.utf16.count <= 20000, !Task.isCancelled, destination.unchanged() else {
            return ("The destination changed. Your dictation is kept here; nothing was pasted.", false)
        }
        receipt = nil
        await pastePreservingClipboard(text)
        return ("Pasted into \(destination.app) without sending. This editor cannot confirm its text; check the insertion. Use the app's Undo if needed.", true)
    }

    func undo() async -> (message: String, success: Bool) {
        guard let receipt else { return ("There is no verified Cookie insertion to undo.", false) }
        let original = receipt.destination
        let current = CookieTextDestination(element: original.element, pid: original.pid, app: original.app,
                                            value: receipt.after, range: CFRange(location: original.range.location, length: receipt.inserted.utf16.count))
        guard !Task.isCancelled, current.unchanged(requireSelection: false) else {
            return ("The field changed after Cookie wrote it. I left your newer edits untouched.", false)
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
        guard MacOperator.string(current.element, kAXValueAttribute) == original.value else {
            self.receipt = nil
            return ("The editor didn't confirm undo. Check the text before retrying.", false)
        }
        self.receipt = nil
        return ("Undid Cookie's insertion.", true)
    }

    private func pastePreservingClipboard(_ text: String) async {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        board.clearContents()
        board.setString(text, forType: .string)
        let ownedChange = board.changeCount
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(for: .milliseconds(250))
        // A copy the user made meanwhile belongs to them; never replace it with our saved version.
        if board.changeCount == ownedChange {
            board.clearContents()
            let items = saved.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
    }
}

/// Finite commands for an existing visual; the model never supplies executable scene code.
/// Written as [VISUAL:name], for a turn by a set amount [VISUAL:rotate:degrees], and for a
/// card's stage [VISUAL:state:n].
enum CookieVisualCommand: Equatable {
    enum Spin: String { case start, faster, slower, stop }
    case explode, assemble, reset, next, previous, isolate, showAll, zoomIn, zoomOut
    /// A turn about the vertical axis; positive brings the model's left side to the front (it turns right).
    case rotate(degrees: Float)
    case spin(Spin)
    /// Every label on, or every label off.
    case labels(shown: Bool)
    /// A card with states moves to stage n (1 is the first): its pictures morph to that one.
    case state(Int)
    /// A sim card runs or holds still; `set` moves one of its parameters (and starts it again).
    case run, pause
    case set(parameter: String, value: Double)
    /// An equation's part lights up (as [TEACH:id] does).
    case highlight(String)

    /// One "rotate left" or "rotate right".
    static let rotateStep: Float = 45

    init?(tag: CookieReplyTag) {
        guard tag.kind == "VISUAL" else { return nil }
        self.init(body: tag.body)
    }

    init?(body: String) {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch body {
        case "explode": self = .explode
        case "assemble": self = .assemble
        case "reset": self = .reset
        case "next": self = .next
        case "previous": self = .previous
        case "isolate": self = .isolate
        case "show-all": self = .showAll
        case "zoom-in": self = .zoomIn
        case "zoom-out": self = .zoomOut
        case "rotate-left": self = .rotate(degrees: -Self.rotateStep)
        case "rotate-right": self = .rotate(degrees: Self.rotateStep)
        case "turn-around": self = .rotate(degrees: 180)
        case "spin": self = .spin(.start)
        case "spin-faster": self = .spin(.faster)
        case "spin-slower": self = .spin(.slower)
        case "stop-spin": self = .spin(.stop)
        case "label-all": self = .labels(shown: true)
        case "hide-labels": self = .labels(shown: false)
        case "run": self = .run
        case "pause": self = .pause
        case _ where body.hasPrefix("set:"):
            // set:<parameter>:<value>, the value a finite number.
            let parts = body.dropFirst(4).split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, let value = Double(parts[1]), value.isFinite else { return nil }
            self = .set(parameter: parts[0], value: value)
        case _ where body.hasPrefix("highlight:"):
            let id = body.dropFirst(10).trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { return nil }
            self = .highlight(id)
        case _ where body.hasPrefix("state:"):
            guard let number = Int(body.dropFirst(6).trimmingCharacters(in: .whitespaces)),
                  (1...CookieCard.maxStates).contains(number) else { return nil }
            self = .state(number)
        default:
            // A set turn: a finite, non-zero number of degrees, at most one full turn either way.
            guard body.hasPrefix("rotate:"), let degrees = Float(body.dropFirst(7).trimmingCharacters(in: .whitespaces)),
                  degrees.isFinite, degrees != 0, abs(degrees) <= 360 else { return nil }
            self = .rotate(degrees: degrees)
        }
    }
}

enum CookieTeachingCommand: Equatable {
    case start, stop, pause, resume, discard
    static func parse(_ text: String) -> Self? {
        switch text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) {
        case "teach you a task", "teach cookie a task", "learn this task", "start learning a task": return .start
        case "stop teaching", "finish teaching", "save this task": return .stop
        case "pause teaching": return .pause
        case "resume teaching": return .resume
        case "discard this recording", "discard teaching": return .discard
        default: return nil
        }
    }
}
