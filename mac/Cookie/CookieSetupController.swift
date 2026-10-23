import AppKit
import SwiftUI

private final class CookieSetupWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class CookieSetupController: NSObject, NSWindowDelegate {
    private let companionManager: CompanionManager
    private let openCookie: (Bool) -> Void
    private var window: NSWindow?
    private var progress: CookieSetupProgress?
    private var activationObserver: NSObjectProtocol?

    init(companionManager: CompanionManager, openCookie: @escaping (Bool) -> Void) {
        self.companionManager = companionManager
        self.openCookie = openCookie
        super.init()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.companionManager.refreshAllPermissions() }
        }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    func show() {
        if let window { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return }
        let progress = CookieSetupProgress(replay: companionManager.hasCompletedOnboarding)
        self.progress = progress
        companionManager.isSetupPresented = true
        companionManager.refreshAllPermissions()
        let available = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame.insetBy(dx: 16, dy: 16)
        let window = CookieSetupWindow(contentRect: NSRect(x: 0, y: 0, width: min(680, available.width), height: min(620, available.height)),
                                       styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.title = "Set up Cookie"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: min(500, available.width), height: min(460, available.height))
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        let model = UserDefaults.standard.string(forKey: CookieModelSettings.modelKey) ?? ""
        let needsModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || CookieModelSettings.missing(model: model) != nil
        window.contentView = NSHostingView(rootView: CookieSetupView(progress: progress, permissions: companionManager.permissionCenter,
                                                                   needsModel: needsModel, finish: { [weak self] configureModel in
            self?.finish(configureModel: configureModel)
        }, dismiss: { [weak self] in self?.window?.close() }))
        self.window = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finish(configureModel: Bool) {
        progress?.complete()
        window?.close()
        companionManager.completeSetup()
        openCookie(configureModel)
    }

    func windowWillClose(_ notification: Notification) {
        companionManager.isSetupPresented = false
        companionManager.refreshAllPermissions()
        window = nil
        progress = nil
    }
}
