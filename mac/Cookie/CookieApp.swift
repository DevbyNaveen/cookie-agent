//
//  CookieApp.swift
//  Cookie
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens the notch. First launch opens a dedicated setup window.
//

import ServiceManagement
import SwiftUI

@main
struct CookieApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The AppDelegate owns the notch, status menu and first-run setup.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private var notchPanelManager: NotchPanelManager?
    private var setupController: CookieSetupController?
    private let companionManager = CompanionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Cookie: Starting...")
        print("🎯 Cookie: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        // Vision's accurate text model takes seconds to load; it loads now, not on the first question.
        CookieVisionText.warmUp()
        CookieAnalytics.configure()
        CookieAnalytics.trackAppOpened()

        companionManager.start()
        notchPanelManager = NotchPanelManager(companionManager: companionManager)
        CookieCaptureShield.start()
        CookieNotifications.shared.start { [weak self] thread in self?.notchPanelManager?.openFromNotification(thread) }
        setupController = CookieSetupController(companionManager: companionManager) { [weak self] configureModel in
            self?.notchPanelManager?.showHome(settingsPage: configureModel ? .voice : nil)
        }
        menuBarPanelManager = MenuBarPanelManager(openCookie: { [weak self] in self?.openCookie() },
            openSettings: { [weak self] in self?.openCookie(settingsPage: .general) },
            openShortcuts: { [weak self] in self?.openCookie(settingsPage: .shortcuts) },
            openSetup: { [weak self] in self?.setupController?.show() })
        if !companionManager.hasCompletedOnboarding { setupController?.show() }
        // ponytail: no auto login item — the user opts in later from settings
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    private func openCookie(settingsPage: CookieNavigation.SettingsPage? = nil) {
        if !companionManager.hasCompletedOnboarding || companionManager.isSetupPresented {
            setupController?.show()
        } else {
            notchPanelManager?.showHome(settingsPage: settingsPage)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openCookie()
        return true
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Cookie: Registered as login item")
            } catch {
                print("⚠️ Cookie: Failed to register as login item: \(error)")
            }
        }
    }
}
