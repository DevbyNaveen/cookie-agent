import AppKit
import SwiftUI

/// The status item opens Cookie's existing surface; secondary actions use a native menu.
@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private let openCookie: () -> Void
    private let openSettings: () -> Void
    private let openShortcuts: () -> Void
    private let openSetup: () -> Void

    init(openCookie: @escaping () -> Void, openSettings: @escaping () -> Void,
         openShortcuts: @escaping () -> Void, openSetup: @escaping () -> Void) {
        self.openCookie = openCookie
        self.openSettings = openSettings
        self.openShortcuts = openShortcuts
        self.openSetup = openSetup
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image = makeCookieMenuBarIcon()
        button.toolTip = "Open Cookie · Right-click for Settings and Help"
        button.setAccessibilityLabel("Cookie")
        button.action = #selector(statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            guard let button = statusItem?.button else { return }
            let menu = makeMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
        } else {
            openCookie()
        }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Cookie")
        menu.addItem(item("Open Cookie", action: #selector(openCookieAction)))
        menu.addItem(item("Settings…", action: #selector(openSettingsAction)))
        menu.addItem(item(CookieTeach.shared.isTeaching ? "Stop teaching and save…" : "Teach Cookie a task", action: #selector(toggleTeaching)))
        if CookieTeach.shared.isTeaching {
            menu.addItem(item(CookieTeach.shared.isPaused ? "Resume teaching" : "Pause teaching", action: #selector(pauseTeaching)))
            menu.addItem(item("Discard recording", action: #selector(discardTeaching)))
        }
        menu.addItem(item("Your taught tasks…", action: #selector(showTaughtTasks)))
        let help = NSMenu(title: "Help")
        help.addItem(item("Keyboard shortcuts", action: #selector(openShortcutsAction)))
        help.addItem(item("Set up Cookie…", action: #selector(openSetupAction)))
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpItem.submenu = help
        menu.addItem(helpItem)
        menu.addItem(.separator())
        menu.addItem(item("Quit Cookie", action: #selector(quitCookie)))
        return menu
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openCookieAction() { openCookie() }
    @objc private func openSettingsAction() { openSettings() }
    @objc private func openShortcutsAction() { openShortcuts() }
    @objc private func openSetupAction() { openSetup() }
    @objc private func quitCookie() { NSApp.terminate(nil) }
    @objc private func pauseTeaching() { CookieTeach.shared.togglePause() }
    @objc private func discardTeaching() { CookieTeach.shared.cancel() }
    @objc private func showTaughtTasks() {
        let records = CookieSkills.records()
        let alert = NSAlert()
        alert.messageText = "Your taught tasks"
        alert.informativeText = records.isEmpty ? "No tasks saved yet. Choose Teach Cookie a task, demonstrate it, then review and save." : records.prefix(20).map { "• \($0.record.name) — \($0.record.steps.count) steps" }.joined(separator: "\n") + "\n\nAsk Cookie to run a task by name. Open its folder to inspect or remove it."
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Open folder")
        if alert.runModal() == .alertSecondButtonReturn {
            try? FileManager.default.createDirectory(at: CookieSkills.userDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(CookieSkills.userDirectory)
        }
    }
    @objc private func toggleTeaching() { CookieTeach.shared.toggle() }

    /// Menu bar icon: the same Cookie creature the home and greeting show,
    /// rendered once at 2x so it stays crisp. Not a template: it keeps its colour.
    private func makeCookieMenuBarIcon() -> NSImage {
        let renderer = ImageRenderer(content: CookieAvatar(size: 18))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 18, height: 18))
        image.size = NSSize(width: 18, height: 18)
        return image
    }

}
