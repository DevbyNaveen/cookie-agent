//
//  CookieMac.swift
//  Cookie
//
//  Cookie operates the Mac when the person asks (SECURITY.md "Acting",
//  amended 2026-10-13). Order of tools, most precise first: the app's own
//  scripting (Excel, Word, PowerPoint, Numbers, Keynote, Pages), then the
//  accessibility tree (press / set a value), then synthetic input (type,
//  keys, scroll, drag, a click at screenshot coordinates) for what neither
//  reaches. Teach mode points at the next control and waits for the person.
//
//  Enforced here, whatever the model asks:
//  - nothing acts without a task the person approved (`start_task`), and only
//    in the apps that task named;
//  - a press on anything that sends, pays, deletes, buys or publishes gets its
//    own card (never covered by the task);
//  - nothing runs while a password is being typed or in a blocked, finance or
//    medical app;
//  - Esc stops the task at once;
//  - at most 60 actions a minute and 300 a task; every action is logged
//    (never the text typed) to ~/Library/Application Support/Cookie/actions.jsonl.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

// MARK: - Pure pieces (checked by the interaction tests)

enum MacKeys {
    /// "cmd+shift+s" → key code and modifier flags; nil for an unknown key.
    /// Escape is refused: it is the person's stop key.
    static func parse(_ combo: String) -> (code: CGKeyCode, flags: CGEventFlags)? {
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }
        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: return nil
            }
        }
        guard let code = codes[keyName] else { return nil }
        return (code, flags)
    }

    static let codes: [String: CGKeyCode] = {
        var table: [String: CGKeyCode] = [
            "a": CGKeyCode(kVK_ANSI_A), "b": CGKeyCode(kVK_ANSI_B), "c": CGKeyCode(kVK_ANSI_C), "d": CGKeyCode(kVK_ANSI_D),
            "e": CGKeyCode(kVK_ANSI_E), "f": CGKeyCode(kVK_ANSI_F), "g": CGKeyCode(kVK_ANSI_G), "h": CGKeyCode(kVK_ANSI_H),
            "i": CGKeyCode(kVK_ANSI_I), "j": CGKeyCode(kVK_ANSI_J), "k": CGKeyCode(kVK_ANSI_K), "l": CGKeyCode(kVK_ANSI_L),
            "m": CGKeyCode(kVK_ANSI_M), "n": CGKeyCode(kVK_ANSI_N), "o": CGKeyCode(kVK_ANSI_O), "p": CGKeyCode(kVK_ANSI_P),
            "q": CGKeyCode(kVK_ANSI_Q), "r": CGKeyCode(kVK_ANSI_R), "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T),
            "u": CGKeyCode(kVK_ANSI_U), "v": CGKeyCode(kVK_ANSI_V), "w": CGKeyCode(kVK_ANSI_W), "x": CGKeyCode(kVK_ANSI_X),
            "y": CGKeyCode(kVK_ANSI_Y), "z": CGKeyCode(kVK_ANSI_Z),
            "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1), "2": CGKeyCode(kVK_ANSI_2), "3": CGKeyCode(kVK_ANSI_3),
            "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5), "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7),
            "8": CGKeyCode(kVK_ANSI_8), "9": CGKeyCode(kVK_ANSI_9),
            "return": CGKeyCode(kVK_Return), "enter": CGKeyCode(kVK_Return), "tab": CGKeyCode(kVK_Tab),
            "space": CGKeyCode(kVK_Space), "delete": CGKeyCode(kVK_Delete), "backspace": CGKeyCode(kVK_Delete),
            "forwarddelete": CGKeyCode(kVK_ForwardDelete),
            "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow), "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
            "home": CGKeyCode(kVK_Home), "end": CGKeyCode(kVK_End), "pageup": CGKeyCode(kVK_PageUp), "pagedown": CGKeyCode(kVK_PageDown),
            "-": CGKeyCode(kVK_ANSI_Minus), "=": CGKeyCode(kVK_ANSI_Equal), ",": CGKeyCode(kVK_ANSI_Comma), ".": CGKeyCode(kVK_ANSI_Period),
            "/": CGKeyCode(kVK_ANSI_Slash), ";": CGKeyCode(kVK_ANSI_Semicolon), "'": CGKeyCode(kVK_ANSI_Quote),
            "[": CGKeyCode(kVK_ANSI_LeftBracket), "]": CGKeyCode(kVK_ANSI_RightBracket), "\\": CGKeyCode(kVK_ANSI_Backslash),
            "`": CGKeyCode(kVK_ANSI_Grave),
        ]
        let functionKeys: [Int] = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in functionKeys.enumerated() { table["f\(index + 1)"] = CGKeyCode(code) }
        return table
    }()

    /// Key code → the name `parse` understands ("return", "s"); the first name wins for aliases.
    static func name(for code: CGKeyCode) -> String? {
        names[code]
    }

    private static let names: [CGKeyCode: String] = {
        var table: [CGKeyCode: String] = [:]
        for (name, code) in codes.sorted(by: { $0.key < $1.key }) where table[code] == nil || ["return", "delete"].contains(name) {
            table[code] = name
        }
        return table
    }()
}

enum MacSafety {
    /// Words on a control that mean the press sends, pays, deletes, buys or
    /// publishes: such a press gets its own card, never covered by the task.
    static let riskyWords = ["send", "pay", "buy", "purchase", "order", "checkout", "delete", "remove", "erase", "trash",
                             "publish", "post", "submit", "transfer", "confirm", "sign", "subscribe", "unsubscribe",
                             "share", "invite", "empty", "discard", "wire", "donate"]

    static func isRisky(label: String) -> Bool {
        let words = label.lowercased().split { !$0.isLetter }.map(String.init)
        return words.contains { riskyWords.contains($0) }
    }

    /// ⌘↩ sends in most mail and chat apps; ⌘⌫ deletes in Finder and lists.
    static func isRiskyKey(_ combo: String) -> Bool {
        guard let (code, flags) = MacKeys.parse(combo) else { return false }
        return flags.contains(.maskCommand) && [CGKeyCode(kVK_Return), CGKeyCode(kVK_Delete), CGKeyCode(kVK_ForwardDelete)].contains(code)
    }

    /// Apps a script may drive, by name as macOS knows them.
    static let scriptableApps = ["Microsoft Excel", "Microsoft Word", "Microsoft PowerPoint", "Numbers", "Keynote", "Pages"]

    /// Why this script must not run, or nil. A script drives one allowed app
    /// and nothing that reaches the shell, other apps, macros or the network.
    static func vetScript(app: String, script: String) -> String? {
        guard scriptableApps.contains(app) else {
            return "Scripts can only drive \(scriptableApps.joined(separator: ", "))."
        }
        let lower = script.lowercased()
        let forbidden = ["do shell script", "visual basic", "vb macro", "run script", "load script", "store script",
                         "system events", "open location", "do javascript", "osascript", "path to", "call method",
                         "«event", "<<event", "run macro", "applescript's"]
        if let hit = forbidden.first(where: { lower.contains($0) }) {
            return "Scripts can't use “\(hit)”."
        }
        let tells = lower.components(separatedBy: "tell application").count - 1
        guard tells == 1, lower.contains("tell application \"\(app.lowercased())\"") else {
            return "A script must be one `tell application \"\(app)\"` block."
        }
        return nil
    }

    /// Bundle ids and App Store categories Cookie never operates.
    static func blocked(bundleID: String?, category: String?) -> Bool {
        if let bundleID, CaptureGuard.blockedBundleIDs.contains(bundleID) { return true }
        return ["public.app-category.finance", "public.app-category.medical"].contains(category ?? "")
    }
}

/// The task the person approved: the plan, and the apps it may act in.
struct MacGrant: Equatable {
    let plan: String
    let apps: [String]
    let started: Date
    var actions: Int = 0

    static let maxActions = 300

    func covers(appName: String?, bundleID: String?) -> Bool {
        let names = [appName, bundleID].compactMap { $0?.lowercased() }
        return apps.contains { wanted in
            let wanted = wanted.lowercased()
            return names.contains { $0 == wanted || $0.hasSuffix(" " + wanted) || $0.hasSuffix("." + wanted) }
        }
    }
}

/// At most `limit` actions in any `window` seconds.
struct MacRateLimit {
    var limit = 60
    var window: TimeInterval = 60
    private(set) var stamps: [Date] = []

    mutating func allow(at now: Date = Date()) -> Bool {
        stamps.removeAll { now.timeIntervalSince($0) >= window }
        guard stamps.count < limit else { return false }
        stamps.append(now)
        return true
    }
}

/// A point in a screenshot's pixels (top-left origin) → CG global display
/// coordinates (top-left origin of the main display), the space CGEvent uses.
func screenshotPointToGlobal(x: Double, y: Double, pixelWidth: Int, pixelHeight: Int, displayFrame: CGRect, mainHeight: CGFloat) -> CGPoint {
    let cx = max(0, min(x, Double(pixelWidth)))
    let cy = max(0, min(y, Double(pixelHeight)))
    let localX = CGFloat(cx) * displayFrame.width / CGFloat(pixelWidth)
    let localY = CGFloat(cy) * displayFrame.height / CGFloat(pixelHeight)
    // AppKit frames have a bottom-left origin; CG global has top-left on the main display.
    let topOfDisplay = mainHeight - displayFrame.maxY
    return CGPoint(x: displayFrame.minX + localX, y: topOfDisplay + localY)
}

// MARK: - The operator

/// One screenshot Cookie sent this run, kept so `click_at` can map its pixels.
struct MacScreen {
    let pixelWidth: Int
    let pixelHeight: Int
    let displayFrame: CGRect
    let isCursorScreen: Bool
}

@MainActor
final class MacOperator {
    static let shared = MacOperator()

    /// Moves Cookie's pointer: AppKit global point, its display, a short sentence.
    var point: ((CGPoint, CGRect, String) -> Void)?
    /// Stops the whole run (Esc).
    var stopRun: (() -> Void)?
    /// The screenshots of the current run, for `click_at`.
    var screens: [MacScreen] = []

    private(set) var grant: MacGrant?
    private var rate = MacRateLimit()
    private var elements: [Int: AXUIElement] = [:]
    private var labels: [Int: String] = [:]
    private var lookedAt: pid_t?
    private var escMonitors: [Any] = []

    // MARK: Tools

    static let writeTools: Set<String> = ["press", "set_value", "type_text", "key", "scroll", "drag", "choose_menu", "click_at", "run_script", "replace_selection"]

    /// The frame (CG global, top-left origin) of an element from the latest look, for drawing on it.
    func frameOfElement(_ id: Int) -> CGRect? {
        elements[id].flatMap(Self.frame)
    }

    /// What Cookie last typed, and into which element, until the person moves on.
    private(set) var lastTyped: (element: AXUIElement, draft: CookieTypedDraft)?
    /// The chat a typed draft belongs to; the manager fills it in.
    var currentThreadID: (() -> UUID?)?
    static let names: Set<String> = writeTools.union(["start_task", "finish_task", "look", "point_at", "wait_for_step"])

    static var tools: [HarnessRequest.Tool] {
        func tool(_ name: String, _ effect: String, _ description: String, _ props: [String: String], _ required: [String]) -> HarnessRequest.Tool {
            HarnessRequest.Tool(name: name, description: description, effect: effect,
                                schema: .init(properties: props.mapValues { .init(description: $0) }, required: required),
                                parallel_safe: false)
        }
        return [
            // `outbound` so the harness always asks: the person approves the plan once.
            tool("start_task", "outbound",
                 "Before acting on the screen, show the person your plan in plain words and the apps you will act in; they approve once. Required before press, set_value, type_text, key, scroll, drag, choose_menu, click_at or run_script. Inside the approved task, actions in those apps run without asking again; anything that sends, pays, deletes or publishes still asks.",
                 ["plan": "What you will do, step by step, in plain words the person can check.",
                  "apps": "The apps you will act in, comma-separated, as their names appear (e.g. \"Microsoft Excel, Finder\")."], ["plan", "apps"]),
            tool("finish_task", "read", "End the approved task when the work is done, with a one-line summary of what you did.",
                 ["summary": "What was done."], ["summary"]),
            tool("look", "read",
                 "Read the front app's window: its accessibility elements as [id] role \"label\" value, with frames. Ids are valid until the next look. Look again after acting, to check what happened.",
                 ["app": "Optional: an app name to read instead of the front app.",
                  "max_elements": "Optional: how many elements (default 150, at most 400)."], []),
            tool("press", "write", "Press a button, link, checkbox, menu item or tab by its id from look.", ["id": "Element id from the latest look."], ["id"]),
            tool("set_value", "write", "Set a text field's or control's value by id (replaces its contents).",
                 ["id": "Element id from the latest look.", "value": "The new value."], ["id", "value"]),
            tool("type_text", "write", "Type text into whatever has keyboard focus, as if typed.", ["text": "The text to type."], ["text"]),
            tool("replace_selection", "write", "Replace the text the person has selected in the front app with new text (a quick fix: shorter, a list, fixed grammar). Only when they asked to change their selection.",
                 ["text": "The whole replacement text."], ["text"]),
            tool("key", "write", "Press a key or shortcut, e.g. \"cmd+s\", \"tab\", \"return\", \"cmd+shift+4\". Escape is the person's stop key and can't be pressed.",
                 ["keys": "The key or shortcut."], ["keys"]),
            tool("scroll", "write", "Scroll at an element (or the front window).",
                 ["id": "Optional element id.", "direction": "up, down, left or right.", "amount": "1 to 20 (lines)."], ["direction"]),
            tool("drag", "write", "Drag from one element to another.", ["from_id": "Element id to drag.", "to_id": "Element id to drop on."], ["from_id", "to_id"]),
            tool("choose_menu", "write", "Choose a menu item in the front app, by its path, e.g. \"File > Export > PDF\".",
                 ["path": "Menu titles separated by >."], ["path"]),
            tool("click_at", "write",
                 "Click a point in the screenshot you were given (pixel coordinates, top-left origin) for things the accessibility tree doesn't show, like a canvas. Prefer press.",
                 ["x": "X in screenshot pixels.", "y": "Y in screenshot pixels.", "screen": "Optional: which screenshot, 1-based (default: the one with the pointer)."], ["x", "y"]),
            tool("run_script", "write",
                 "Run an AppleScript that drives one of Microsoft Excel, Microsoft Word, Microsoft PowerPoint, Numbers, Keynote or Pages: one tell application block, nothing else (no shell, macros, other apps). Best for editing cells, formulas, charts, tables, text and slides precisely.",
                 ["app": "One of the apps above, exactly as written.", "script": "The AppleScript."], ["app", "script"]),
            tool("point_at", "read", "Teach mode: point Cookie's pointer at an element and say one short instruction for the person to do themselves.",
                 ["id": "Element id from the latest look.", "say": "One short instruction, e.g. \"Click Insert, then Chart\"."], ["id", "say"]),
            tool("wait_for_step", "read",
                 "Teach mode: wait until the person does the step you pointed at (clicks it, changes it, or focus moves), then return what changed. Times out after the given seconds.",
                 ["id": "Element id you pointed at.", "timeout": "Seconds to wait, 5 to 180 (default 60)."], ["id"]),
        ]
    }

    // MARK: Approvals

    /// Whether this approval is one the approved task covers: a write action
    /// in a granted app, on nothing risky, with no value the person didn't write.
    func taskCovers(_ approval: HarnessApproval) -> Bool {
        approval.actions.allSatisfy { action in
            guard Self.writeTools.contains(action.tool), action.fromData.isEmpty, let grant else { return false }
            let front = NSWorkspace.shared.frontmostApplication
            let args = Self.args(of: action)
            switch action.tool {
            case "run_script":
                guard let app = args["app"] as? String, grant.covers(appName: app, bundleID: nil) else { return false }
                return true
            case "press", "drag":
                let ids = ["id", "from_id", "to_id"].compactMap { Self.int(args[$0]) }
                if ids.contains(where: { MacSafety.isRisky(label: labels[$0] ?? "") }) { return false }
            case "key":
                if MacSafety.isRiskyKey(args["keys"] as? String ?? "") { return false }
            default: break
            }
            return grant.covers(appName: front?.localizedName, bundleID: front?.bundleIdentifier)
        }
    }

    /// Plain words for a card about one of these actions.
    func question(for action: HarnessAction) -> String? {
        guard Self.names.contains(action.tool) else { return nil }
        let args = Self.args(of: action)
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "the front app"
        let label = Self.int(args["id"]).flatMap { labels[$0] }.map { "“\($0)”" } ?? "this"
        switch action.tool {
        case "start_task": return "Let Cookie do this on your Mac?"
        case "press": return "Press \(label) in \(app)?"
        case "set_value": return "Change \(label) in \(app)?"
        case "type_text": return "Type into \(app)?"
        case "replace_selection": return "Replace the selected text in \(app)?"
        case "key": return "Press \(args["keys"] as? String ?? "a key") in \(app)?"
        case "choose_menu": return "Choose \(args["path"] as? String ?? "a menu item") in \(app)?"
        case "run_script": return "Run a script in \(args["app"] as? String ?? app)?"
        case "click_at": return "Click on the screen in \(app)?"
        case "drag": return "Drag in \(app)?"
        case "scroll": return "Scroll in \(app)?"
        default: return nil
        }
    }

    static func args(of action: HarnessAction) -> [String: Any] {
        guard let space = action.preview.firstIndex(of: " "),
              let object = try? JSONSerialization.jsonObject(with: Data(action.preview[action.preview.index(after: space)...].utf8)) as? [String: Any]
        else { return [:] }
        return object
    }

    static func int(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    // MARK: Running a call

    /// Runs one approved call; the text goes back to the model.
    func perform(_ name: String, _ args: [String: Any]) async -> (output: String, isError: Bool) {
        if name == "start_task" { return startTask(args) }
        if name == "finish_task" { return finishTask(args) }
        if name == "look" { return look(args) }

        // Everything below touches the screen.
        guard AXIsProcessTrusted() else {
            return ("Cookie needs Accessibility access to act (System Settings → Privacy & Security → Accessibility). Ask the person to turn it on.", true)
        }
        if IsSecureEventInputEnabled() || CaptureGuard.focusedElementIsSecure() {
            return ("A password is being typed or a password field is selected. Cookie doesn't act now.", true)
        }
        let front = NSWorkspace.shared.frontmostApplication
        if MacSafety.blocked(bundleID: front?.bundleIdentifier, category: front.flatMap(Self.category)) {
            return ("Cookie never operates \(front?.localizedName ?? "this app") (a blocked, finance or medical app).", true)
        }

        if name == "point_at" { return pointAt(args) }
        if name == "wait_for_step" { return await waitForStep(args) }

        guard var grant else { return ("Call start_task first: show the person your plan and the apps.", true) }
        let target = name == "run_script" ? (args["app"] as? String) : front?.localizedName
        guard grant.covers(appName: target, bundleID: name == "run_script" ? nil : front?.bundleIdentifier) else {
            return ("\(target ?? "This app") isn't in the approved task (\(grant.apps.joined(separator: ", "))). Ask the person, with a new start_task.", true)
        }
        guard grant.actions < MacGrant.maxActions else { return ("This task reached \(MacGrant.maxActions) actions. Finish it and start a new one.", true) }
        guard rate.allow() else { return ("Too many actions in a minute. Wait a moment, then look again.", true) }
        grant.actions += 1
        self.grant = grant

        let result: (String, Bool)
        switch name {
        case "press": result = press(args)
        case "set_value": result = setValue(args)
        case "type_text": result = typeText(args)
        case "replace_selection": result = replaceSelection(args)
        case "key": result = key(args)
        case "scroll": result = scroll(args)
        case "drag": result = drag(args)
        case "choose_menu": result = chooseMenu(args)
        case "click_at": result = clickAt(args)
        case "run_script": result = runScript(args)
        default: result = ("Cookie has no tool named \(name).", true)
        }
        log(name, app: target, element: Self.int(args["id"]).flatMap { labels[$0] }, ok: !result.1)
        guard !result.1 else { return result }
        try? await Task.sleep(for: .milliseconds(250))
        return ("\(result.0)\n\(afterState())", false)
    }

    /// The run ended: the task ends with it.
    func endRun() {
        grant = nil
        screens = []
        elements = [:]
        labels = [:]
        stopEscWatch()
    }

    // MARK: Task

    private func startTask(_ args: [String: Any]) -> (String, Bool) {
        let plan = (args["plan"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let apps = (args["apps"] as? String ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !plan.isEmpty, !apps.isEmpty else { return ("start_task needs a plan and at least one app.", true) }
        grant = MacGrant(plan: plan, apps: apps, started: Date())
        rate = MacRateLimit()
        startEscWatch()
        log("start_task", app: apps.joined(separator: ", "), element: nil, ok: true)
        return ("The person approved the task. You may act in: \(apps.joined(separator: ", ")). Look before each step and check after it. Esc stops you.", false)
    }

    private func finishTask(_ args: [String: Any]) -> (String, Bool) {
        log("finish_task", app: grant?.apps.joined(separator: ", "), element: nil, ok: true)
        grant = nil
        stopEscWatch()
        return ("Task finished.", false)
    }

    private func startEscWatch() {
        stopEscWatch()
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape), event.type == .keyDown else { return }
            MainActor.assumeIsolated {
                guard let self, self.grant != nil else { return }
                self.log("stopped_by_person", app: self.grant?.apps.joined(separator: ", "), element: nil, ok: true)
                self.grant = nil
                self.stopEscWatch()
                self.stopRun?()
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { escMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handler($0); return $0 }) { escMonitors.append(local) }
    }

    private func stopEscWatch() {
        escMonitors.forEach(NSEvent.removeMonitor)
        escMonitors = []
    }

    // MARK: Reading

    private func look(_ args: [String: Any]) -> (String, Bool) {
        guard AXIsProcessTrusted() else {
            return ("Cookie needs Accessibility access to read apps (System Settings → Privacy & Security → Accessibility).", true)
        }
        let app: NSRunningApplication?
        if let name = args["app"] as? String, !name.isEmpty {
            app = NSWorkspace.shared.runningApplications.first { $0.localizedName?.lowercased() == name.lowercased() }
        } else {
            app = NSWorkspace.shared.frontmostApplication
        }
        guard let app else { return ("That app isn't running.", true) }
        if MacSafety.blocked(bundleID: app.bundleIdentifier, category: Self.category(app)) {
            return ("Cookie never reads \(app.localizedName ?? "this app").", true)
        }
        let limit = min(400, max(20, Self.int(args["max_elements"]) ?? 150))
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // Electron and Chromium apps build their tree only when asked.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        elements = [:]
        labels = [:]
        lookedAt = app.processIdentifier

        var lines = ["App: \(app.localizedName ?? "?")"]
        let window = Self.attribute(root, kAXFocusedWindowAttribute) as! AXUIElement?
        if let window, let title = Self.string(window, kAXTitleAttribute), !title.isEmpty { lines.append("Window: \(title)") }
        if let focused = Self.attribute(root, kAXFocusedUIElementAttribute) as! AXUIElement? {
            lines.append("Focused: \(Self.describe(focused))")
        }
        var queue: [(AXUIElement, Int)] = [(window ?? root, 0)]
        if let menuBar = Self.attribute(root, kAXMenuBarAttribute) as! AXUIElement? { _ = menuBar } // menus are reached with choose_menu
        var nextID = 1
        while !queue.isEmpty, elements.count < limit {
            let (element, depth) = queue.removeFirst()
            let role = Self.string(element, kAXRoleAttribute) ?? ""
            if Self.worthShowing(element, role: role) {
                elements[nextID] = element
                let label = Self.label(element)
                labels[nextID] = label
                lines.append("[\(nextID)] \(Self.describe(element))")
                nextID += 1
            }
            guard depth < 30, let children = Self.attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            queue.append(contentsOf: children.prefix(200).map { ($0, depth + 1) })
        }
        if elements.count >= limit { lines.append("(more elements not shown; ask for max_elements up to 400, or look at a smaller area after scrolling)") }
        if elements.isEmpty { lines.append("(no accessible elements: this app may draw on a canvas; use click_at with the screenshot)") }
        return (lines.joined(separator: "\n"), false)
    }

    private static func worthShowing(_ element: AXUIElement, role: String) -> Bool {
        let interesting: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField",
                                        "AXTextArea", "AXComboBox", "AXLink", "AXTab", "AXSlider", "AXCell", "AXMenuItem",
                                        "AXStaticText", "AXHeading", "AXImage", "AXRow", "AXDisclosureTriangle", "AXIncrementor",
                                        "AXSearchField", "AXSegmentedControl", "AXToolbar"]
        guard interesting.contains(role) else { return false }
        if role == "AXStaticText" || role == "AXImage" { return !(label(element).isEmpty) }
        return true
    }

    static func label(_ element: AXUIElement) -> String {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute, "AXIdentifier"] {
            if let text = string(element, key), !text.isEmpty { return String(text.prefix(80)) }
        }
        if let value = string(element, kAXValueAttribute), !value.isEmpty, value.count <= 80 { return value }
        return ""
    }

    private static func describe(_ element: AXUIElement) -> String {
        let role = (string(element, kAXRoleAttribute) ?? "?").replacingOccurrences(of: "AX", with: "")
        var text = role
        let label = label(element)
        if !label.isEmpty { text += " \"\(label)\"" }
        if let value = string(element, kAXValueAttribute), !value.isEmpty, value != label {
            text += " = \"\(value.prefix(60))\(value.count > 60 ? "…" : "")\""
        }
        if (attribute(element, kAXEnabledAttribute) as? Bool) == false { text += " (disabled)" }
        if let frame = frame(element) { text += " @\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))" }
        return text
    }

    // MARK: Acting

    private func element(_ args: [String: Any], _ key: String = "id") -> AXUIElement? {
        guard let id = Self.int(args[key]) else { return nil }
        return elements[id]
    }

    private func press(_ args: [String: Any]) -> (String, Bool) {
        guard let element = element(args) else { return ("No element with that id. Look again first.", true) }
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return ("Pressed.", false) }
        guard let center = Self.center(element) else { return ("That element can't be pressed.", true) }
        return Self.click(at: center) ? ("Clicked it.", false) : ("Couldn't click there.", true)
    }

    private func setValue(_ args: [String: Any]) -> (String, Bool) {
        guard let element = element(args) else { return ("No element with that id. Look again first.", true) }
        let value = args["value"] as? String ?? String(describing: args["value"] ?? "")
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success else {
            return ("That element's value can't be set; focus it with press and use type_text.", true)
        }
        let now = Self.string(element, kAXValueAttribute) ?? ""
        return (now == value ? "Set." : "Set, but it now reads \"\(now.prefix(80))\".", false)
    }

    private func typeText(_ args: [String: Any]) -> (String, Bool) {
        let text = args["text"] as? String ?? ""
        guard !text.isEmpty, text.count <= 5_000 else { return ("Type between 1 and 5,000 characters.", true) }
        guard Self.canPost() else { return ("Cookie needs permission to control the keyboard and mouse (Accessibility).", true) }
        let target = Self.focusedElement()
        let before = target.flatMap { Self.string($0, kAXValueAttribute) } ?? ""
        Self.postKeystrokes(text)
        // Some fields (web editors, canvases) drop synthetic keystrokes: check, then paste instead.
        usleep(120_000)
        let after = target.flatMap { Self.string($0, kAXValueAttribute) }
        var how = "Typed"
        if let after, !after.contains(text.prefix(40)), after == before {
            Self.paste(text)
            how = "Pasted"
        }
        remember(typed: text, into: target)
        return ("\(how) \(text.count) characters.", false)
    }

    private func replaceSelection(_ args: [String: Any]) -> (String, Bool) {
        let text = args["text"] as? String ?? ""
        guard !text.isEmpty, text.count <= 5_000 else { return ("Replace with between 1 and 5,000 characters.", true) }
        guard let target = Self.focusedElement() else { return ("Nothing has keyboard focus to replace in.", true) }
        let selected = Self.string(target, kAXSelectedTextAttribute) ?? ""
        guard !selected.isEmpty else { return ("Nothing is selected in the front app.", true) }
        if AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute as CFString, text as CFString) != .success {
            guard Self.canPost() else { return ("Cookie needs permission to control the keyboard and mouse (Accessibility).", true) }
            Self.paste(text)
        }
        remember(typed: text, into: target)
        return ("Replaced the selection (\(selected.count) → \(text.count) characters).", false)
    }

    private func remember(typed text: String, into element: AXUIElement?) {
        guard let element else { lastTyped = nil; return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "the app"
        lastTyped = (element, CookieTypedDraft(app: app, text: text, date: Date(), threadID: currentThreadID?()))
    }

    /// If the person changed what Cookie typed, what they changed it to; clears the draft either way.
    func takeCorrection() -> (draft: CookieTypedDraft, after: String)? {
        guard let (element, draft) = lastTyped else { return nil }
        lastTyped = nil
        guard Date().timeIntervalSince(draft.date) < 3600,
              let now = Self.string(element, kAXValueAttribute), CookieCorrections.isEdit(before: draft.text, after: now) else { return nil }
        return (draft, now)
    }

    /// The text selected in the front app, for a quick fix; nothing from secure fields or blocked apps.
    static func selectedTextInFrontApp() -> (app: String, text: String)? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              !MacSafety.blocked(bundleID: app.bundleIdentifier, category: category(app)),
              let element = focusedElement(), string(element, kAXRoleAttribute) != "AXSecureTextField",
              let text = string(element, kAXSelectedTextAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 4_000 else { return nil }
        return (app.localizedName ?? "the app", text)
    }

    static func focusedElement() -> AXUIElement? {
        attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) as! AXUIElement?
    }

    private static func postKeystrokes(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        var index = 0
        while index < utf16.count {
            let chunk = Array(utf16[index..<min(index + 16, utf16.count)])
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                chunk.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                event?.post(tap: .cghidEventTap)
            }
            index += 16
            usleep(8_000)
        }
    }

    /// Puts the text on the pasteboard, presses ⌘V, and gives the person their clipboard back.
    private static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
        }
    }

    private func key(_ args: [String: Any]) -> (String, Bool) {
        let combo = args["keys"] as? String ?? ""
        if combo.lowercased().contains("esc") { return ("Escape is the person's stop key; Cookie can't press it.", true) }
        guard let (code, flags) = MacKeys.parse(combo) else { return ("Unknown key \"\(combo)\".", true) }
        guard Self.canPost() else { return ("Cookie needs permission to control the keyboard and mouse (Accessibility).", true) }
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        return ("Pressed \(combo).", false)
    }

    private func scroll(_ args: [String: Any]) -> (String, Bool) {
        let amount = Int32(min(20, max(1, Self.int(args["amount"]) ?? 3)))
        let (dy, dx): (Int32, Int32) = switch (args["direction"] as? String ?? "down").lowercased() {
        case "up": (amount, 0)
        case "left": (0, amount)
        case "right": (0, -amount)
        default: (-amount, 0)
        }
        if let element = element(args), let center = Self.center(element) { CGWarpMouseCursorPosition(center) }
        guard Self.canPost() else { return ("Cookie needs permission to control the keyboard and mouse (Accessibility).", true) }
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?.post(tap: .cghidEventTap)
        return ("Scrolled.", false)
    }

    private func drag(_ args: [String: Any]) -> (String, Bool) {
        guard let from = element(args, "from_id").flatMap(Self.center), let to = element(args, "to_id").flatMap(Self.center) else {
            return ("No element with one of those ids. Look again first.", true)
        }
        guard Self.canPost() else { return ("Cookie needs permission to control the keyboard and mouse (Accessibility).", true) }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)?.post(tap: .cghidEventTap)
        for step in 1...12 {
            let t = CGFloat(step) / 12
            let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(12_000)
        }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)?.post(tap: .cghidEventTap)
        return ("Dragged.", false)
    }

    private func chooseMenu(_ args: [String: Any]) -> (String, Bool) {
        let path = (args["path"] as? String ?? "").split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !path.isEmpty, let app = NSWorkspace.shared.frontmostApplication else { return ("Give a menu path like \"File > Save\".", true) }
        if path.contains(where: { MacSafety.isRisky(label: $0) }) && !(grant?.plan.lowercased().contains(path.last!.lowercased()) ?? false) {
            return ("“\(path.last!)” can send, delete or publish; it needs its own yes. Ask the person first.", true)
        }
        guard let menuBar = Self.attribute(AXUIElementCreateApplication(app.processIdentifier), kAXMenuBarAttribute) as! AXUIElement? else {
            return ("This app has no menu bar Cookie can read.", true)
        }
        var current = menuBar
        for (index, title) in path.enumerated() {
            guard let item = Self.menuChild(current, titled: title) else {
                return ("No menu item “\(title)”. Menus here: \(Self.menuTitles(current).prefix(25).joined(separator: ", ")).", true)
            }
            if index == path.count - 1 {
                return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success ? ("Chose \(path.joined(separator: " > ")).", false) : ("Couldn't choose that item.", true)
            }
            // Open the submenu so its items exist, then walk into it.
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            usleep(120_000)
            guard let submenu = (Self.attribute(item, kAXChildrenAttribute) as? [AXUIElement])?.first else {
                return ("“\(title)” has no submenu.", true)
            }
            current = submenu
        }
        return ("Couldn't choose that item.", true)
    }

    private static func menuChild(_ menu: AXUIElement, titled title: String) -> AXUIElement? {
        let wanted = title.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".… "))
        return (attribute(menu, kAXChildrenAttribute) as? [AXUIElement])?.first {
            (string($0, kAXTitleAttribute) ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".… ")) == wanted
        }
    }

    private static func menuTitles(_ menu: AXUIElement) -> [String] {
        (attribute(menu, kAXChildrenAttribute) as? [AXUIElement])?.compactMap { string($0, kAXTitleAttribute) }.filter { !$0.isEmpty } ?? []
    }

    private func clickAt(_ args: [String: Any]) -> (String, Bool) {
        guard let x = (args["x"] as? Double) ?? Self.int(args["x"]).map(Double.init),
              let y = (args["y"] as? Double) ?? Self.int(args["y"]).map(Double.init) else { return ("Give x and y in screenshot pixels.", true) }
        let screen: MacScreen?
        if let index = Self.int(args["screen"]), index >= 1, index <= screens.count { screen = screens[index - 1] } else { screen = screens.first { $0.isCursorScreen } ?? screens.first }
        guard let screen else { return ("There's no screenshot in this run to click on. Ask the person to share their screen.", true) }
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.displayFrame.height
        let point = screenshotPointToGlobal(x: x, y: y, pixelWidth: screen.pixelWidth, pixelHeight: screen.pixelHeight,
                                            displayFrame: screen.displayFrame, mainHeight: mainHeight)
        return Self.click(at: point) ? ("Clicked.", false) : ("Couldn't click there.", true)
    }

    private func runScript(_ args: [String: Any]) -> (String, Bool) {
        let app = args["app"] as? String ?? ""
        let source = args["script"] as? String ?? ""
        if let why = MacSafety.vetScript(app: app, script: source) { return (why, true) }
        guard let script = NSAppleScript(source: source) else { return ("That script doesn't compile.", true) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "unknown error"
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                return ("macOS hasn't allowed Cookie to control \(app) (Privacy & Security → Automation). Ask the person to allow it.", true)
            }
            return ("The script failed: \(message)", true)
        }
        let output = result.stringValue ?? ""
        return (output.isEmpty ? "Done." : "Done: \(output.prefix(2_000))", false)
    }

    // MARK: Teach

    private func pointAt(_ args: [String: Any]) -> (String, Bool) {
        guard let element = element(args), let frame = Self.frame(element) else { return ("No element with that id. Look again first.", true) }
        let say = (args["say"] as? String ?? "").prefix(140)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        // AX frames are CG global (top-left origin); the overlay uses AppKit (bottom-left).
        let center = CGPoint(x: frame.midX, y: mainHeight - frame.midY)
        let display = NSScreen.screens.first { $0.frame.contains(center) }?.frame ?? NSScreen.main?.frame ?? .zero
        point?(center, display, String(say))
        return ("Pointing at it.", false)
    }

    private func waitForStep(_ args: [String: Any]) async -> (String, Bool) {
        guard let element = element(args) else { return ("No element with that id. Look again first.", true) }
        let timeout = Double(min(180, max(5, Self.int(args["timeout"]) ?? 60)))
        let startValue = Self.string(element, kAXValueAttribute)
        let frame = Self.frame(element)
        let app = lookedAt.map(AXUIElementCreateApplication)
        let startWindow = app.flatMap { Self.attribute($0, kAXFocusedWindowAttribute) as! AXUIElement? }.flatMap { Self.string($0, kAXTitleAttribute) }
        var clicked = false
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            let location = NSEvent.mouseLocation
            let cg = CGPoint(x: location.x, y: mainHeight - location.y)
            if let frame, frame.insetBy(dx: -4, dy: -4).contains(cg) { clicked = true }
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return ("Stopped.", true) }
            if clicked { return ("The person clicked it.\n\(afterState())", false) }
            if Self.string(element, kAXValueAttribute) != startValue { return ("The person changed it.\n\(afterState())", false) }
            if let app, let focused = Self.attribute(app, kAXFocusedUIElementAttribute) as! AXUIElement?, CFEqual(focused, element) {
                return ("The person moved focus to it.\n\(afterState())", false)
            }
            let window = app.flatMap { Self.attribute($0, kAXFocusedWindowAttribute) as! AXUIElement? }.flatMap { Self.string($0, kAXTitleAttribute) }
            if window != startWindow { return ("A different window is in front now.\n\(afterState())", false) }
        }
        return ("The person hasn't done it yet (waited \(Int(timeout)) s). Ask if they need help, or point again.", false)
    }

    // MARK: After each step

    private func afterState() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "" }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var parts = ["Now: \(app.localizedName ?? "?")"]
        if let window = Self.attribute(root, kAXFocusedWindowAttribute) as! AXUIElement?, let title = Self.string(window, kAXTitleAttribute), !title.isEmpty {
            parts.append("window “\(title)”")
        }
        if let focused = Self.attribute(root, kAXFocusedUIElementAttribute) as! AXUIElement? {
            parts.append("focus: \(Self.describe(focused))")
        }
        return parts.joined(separator: ", ") + ". Look again to check the result before saying it worked."
    }

    // MARK: Log

    /// One line per action: never the text typed or values set.
    private func log(_ tool: String, app: String?, element: String?, ok: Bool) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cookie")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("actions.jsonl")
        let entry: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "tool": tool, "app": app ?? "",
                                    "element": element ?? "", "ok": ok, "task": grant?.plan.prefix(200).description ?? ""]
        guard var line = try? JSONSerialization.data(withJSONObject: entry) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    // MARK: AX helpers

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        let value = attribute(element, name)
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    static func center(_ element: AXUIElement) -> CGPoint? {
        frame(element).map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    static func click(at point: CGPoint) -> Bool {
        guard canPost() else { return false }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
        return true
    }

    static func canPost() -> Bool {
        CGPreflightPostEventAccess() || CGRequestPostEventAccess()
    }

    static func category(_ app: NSRunningApplication) -> String? {
        guard let url = app.bundleURL, let bundle = Bundle(url: url) else { return nil }
        return bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
    }
}
