//
//  CookieTeach.swift
//  Cookie
//
//  Teach by doing. Start teaching from Cookie's menu, do the task once in
//  any app, stop, give it a name: Cookie writes a skill from what you did
//  (which app, which control, what was typed, which shortcut) and can replay
//  it on request. Typing into a password field is noted, never kept.
//

import AppKit
import Carbon.HIToolbox
import Foundation

/// One thing the person did while teaching.
enum CookieTeachStep: Equatable {
    case press(app: String, role: String, label: String)
    case type(app: String, field: String, text: String)
    case key(app: String, combo: String)
    case typedSomethingPrivate(app: String)

    var app: String {
        switch self {
        case .press(let app, _, _), .type(let app, _, _), .key(let app, _), .typedSomethingPrivate(let app): return app
        }
    }

    var line: String {
        switch self {
        case .press(let app, let role, let label):
            return "In \(app): press the \(role.lowercased())\(label.isEmpty ? "" : " \"\(label)\"") (find it with look)."
        case .type(let app, let field, let text):
            return "In \(app): type \"\(text)\"\(field.isEmpty ? "" : " into \"\(field)\"") (type_text; if the value should differ for this run, ask)."
        case .key(let app, let combo):
            return "In \(app): press \(combo) (key)."
        case .typedSomethingPrivate(let app):
            return "In \(app): the person typed something private here; ask them to do this step themselves."
        }
    }
}

enum CookieSkillWriter {
    /// A folder name the harness accepts: lowercase words and dashes.
    static func slug(_ name: String) -> String {
        let cleaned = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let parts = cleaned.split(separator: "-").filter { !$0.isEmpty }
        return parts.isEmpty ? "taught-skill" : "taught-" + parts.prefix(6).joined(separator: "-")
    }

    /// The SKILL.md the harness loads: frontmatter, then the steps as the person did them.
    static func markdown(name: String, steps: [CookieTeachStep], taughtOn: Date = Date()) -> String {
        let apps = Array(NSOrderedSet(array: steps.map(\.app))) as? [String] ?? []
        let date = taughtOn.formatted(date: .long, time: .omitted)
        var lines = [
            "---",
            "name: \(slug(name))",
            "description: \(name) — taught by the person on \(date): \(steps.count) step\(steps.count == 1 ? "" : "s") in \(apps.joined(separator: ", ")).",
            "---",
            "# \(name)",
            "",
            "The person showed Cookie this once, by doing it. Replay it the same way.",
            "",
            "## Before",
            "- `start_task` with the plan \"\(name)\" and the apps: \(apps.joined(separator: ", ")).",
            "- `look` before each step; `look` again after it. If the screen doesn't match what a step expects, stop and ask.",
            "- Values typed below were right that day; if this run needs others (a name, a date, an amount), ask first.",
            "",
            "## Steps",
        ]
        for (index, step) in steps.enumerated() { lines.append("\(index + 1). \(step.line)") }
        lines += ["", "## After", "- `finish_task` with one line on what was done."]
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Cookie's skills on this Mac: the ones in the app, plus the ones the person taught.
enum CookieSkills {
    static let userDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cookie/skills", isDirectory: true)
    private static let mergedDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cookie/skills-merged", isDirectory: true)

    /// The folder the helper reads: the app's skills and the taught ones side by side.
    /// Rebuilt whenever a taught skill is added; falls back to the app's own folder.
    static func directoryForHarness() -> String? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("skills")
        guard let bundled, FileManager.default.fileExists(atPath: bundled.path) else {
            return FileManager.default.fileExists(atPath: userDirectory.path) ? userDirectory.path : nil
        }
        guard FileManager.default.fileExists(atPath: userDirectory.path) else { return bundled.path }
        return (try? merge(bundled: bundled)) ?? bundled.path
    }

    private static func merge(bundled: URL) throws -> String {
        let fm = FileManager.default
        try? fm.removeItem(at: mergedDirectory)
        try fm.createDirectory(at: mergedDirectory, withIntermediateDirectories: true)
        for folder in [bundled, userDirectory] {
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where !name.hasPrefix(".") {
                let source = folder.appendingPathComponent(name)
                guard fm.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else { continue }
                try? fm.removeItem(at: mergedDirectory.appendingPathComponent(name))
                try fm.copyItem(at: source, to: mergedDirectory.appendingPathComponent(name))
            }
        }
        return mergedDirectory.path
    }

    /// Writes a taught skill; returns where it went.
    @discardableResult
    static func save(name: String, steps: [CookieTeachStep]) throws -> URL {
        let folder = userDirectory.appendingPathComponent(CookieSkillWriter.slug(name), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("SKILL.md")
        try CookieSkillWriter.markdown(name: name, steps: steps).write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

/// Records what the person does: clicks (as the control under the pointer), typing, shortcuts.
@MainActor
final class CookieTeach: ObservableObject {
    static let shared = CookieTeach()

    @Published private(set) var isTeaching = false
    @Published private(set) var steps: [CookieTeachStep] = []
    @Published private(set) var problem: String?
    private var tap: CFMachPort?
    private var typing: (app: String, field: String, text: String)?

    func toggle() {
        if isTeaching { stop() } else { start() }
    }

    func start() {
        guard !isTeaching else { return }
        guard AXIsProcessTrusted() else {
            problem = "Cookie needs Accessibility access to watch what you do (System Settings → Privacy & Security → Accessibility)."
            return
        }
        let types: [CGEventType] = [.leftMouseUp, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let teach = Unmanaged<CookieTeach>.fromOpaque(userInfo).takeUnretainedValue()
            let copy = event.copy()
            Task { @MainActor in teach.handle(type: type, event: copy ?? event) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            problem = "Cookie couldn't watch the keyboard and mouse. Check Input Monitoring in System Settings."
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        steps = []
        typing = nil
        problem = nil
        isTeaching = true
        CookieNotifications.shared.post(.reply, threadID: nil, title: "Teaching Cookie", body: "Do the task once. Open Cookie's menu again to stop and name it.", panelOpen: false)
    }

    func stop() {
        guard isTeaching else { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
        flushTyping()
        isTeaching = false
        guard !steps.isEmpty else { problem = "Nothing was recorded."; return }
        askForNameAndSave()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        guard isTeaching else { return }
        let app = NSWorkspace.shared.frontmostApplication
        if app?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        let appName = app?.localizedName ?? "the app"
        if MacSafety.blocked(bundleID: app?.bundleIdentifier, category: app.flatMap(MacOperator.category)) { return }
        switch type {
        case .leftMouseUp:
            flushTyping()
            var element: AXUIElement?
            let point = event.location
            if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success, let element {
                let role = (MacOperator.string(element, kAXRoleAttribute) ?? "control").replacingOccurrences(of: "AX", with: "")
                steps.append(.press(app: appName, role: role, label: MacOperator.label(element)))
            } else {
                steps.append(.press(app: appName, role: "spot", label: "at \(Int(point.x)),\(Int(point.y)) on screen"))
            }
        case .keyDown:
            let flags = event.flags
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if flags.contains(.maskCommand) || flags.contains(.maskControl) || (flags.contains(.maskAlternate) && !flags.contains(.maskShift)) {
                flushTyping()
                var parts: [String] = []
                if flags.contains(.maskControl) { parts.append("ctrl") }
                if flags.contains(.maskAlternate) { parts.append("opt") }
                if flags.contains(.maskShift) { parts.append("shift") }
                if flags.contains(.maskCommand) { parts.append("cmd") }
                parts.append(MacKeys.name(for: CGKeyCode(code)) ?? "key\(code)")
                steps.append(.key(app: appName, combo: parts.joined(separator: "+")))
                return
            }
            if let name = MacKeys.name(for: CGKeyCode(code)), ["return", "tab", "delete", "left", "right", "up", "down"].contains(name) {
                flushTyping()
                steps.append(.key(app: appName, combo: name))
                return
            }
            let focused = MacOperator.focusedElement()
            if let focused, MacOperator.string(focused, kAXRoleAttribute) == "AXSecureTextField" {
                flushTyping()
                if steps.last != .typedSomethingPrivate(app: appName) { steps.append(.typedSomethingPrivate(app: appName)) }
                return
            }
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &buffer)
            let text = String(utf16CodeUnits: buffer, count: length)
            guard !text.isEmpty else { return }
            let field = focused.map(MacOperator.label) ?? ""
            if var current = typing, current.app == appName, current.field == field {
                current.text += text
                typing = current
            } else {
                flushTyping()
                typing = (appName, field, text)
            }
        default:
            break
        }
    }

    private func flushTyping() {
        guard let typing else { return }
        let text = typing.text.trimmingCharacters(in: .controlCharacters)
        if !text.isEmpty { steps.append(.type(app: typing.app, field: typing.field, text: String(text.prefix(300)))) }
        self.typing = nil
    }

    private func askForNameAndSave() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Name what Cookie just learned"
        alert.informativeText = "\(steps.count) step\(steps.count == 1 ? "" : "s") recorded. Cookie replays it when you ask for it by this name."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Send the weekly report"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { steps = []; return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let file = try CookieSkills.save(name: name.isEmpty ? "Taught task" : name, steps: steps)
            problem = nil
            CookieNotifications.shared.post(.reply, threadID: nil, title: "Cookie learned it", body: "“\(name.isEmpty ? "Taught task" : name)” is saved (\(file.deletingLastPathComponent().lastPathComponent)). Ask for it by name.", panelOpen: false)
        } catch {
            problem = "Couldn't save the skill: \(error.localizedDescription)"
        }
        steps = []
    }
}
