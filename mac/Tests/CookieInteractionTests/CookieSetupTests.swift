import AppKit
import SwiftUI

@MainActor
final class CookieFakePermissions: CookiePermissionProviding {
    var statuses: [CookiePermission: CookiePermissionStatus] = [:]
    var requests: [CookiePermission] = []
    var settingsOpened: [CookiePermission] = []
    var captureChecks = 0
    var captureSucceeds = true
    var holdRequest = false
    var requestContinuation: CheckedContinuation<Void, Never>?

    func status(for permission: CookiePermission) -> CookiePermissionStatus { statuses[permission] ?? .notDetermined }
    func request(_ permission: CookiePermission) async {
        requests.append(permission)
        if holdRequest { await withCheckedContinuation { requestContinuation = $0 } }
    }
    func openSettings(for permission: CookiePermission) { settingsOpened.append(permission) }
    func verifyScreenAccess() async throws -> Bool {
        captureChecks += 1
        if !captureSucceeds { throw NSError(domain: "CookieSetupCheck", code: 1) }
        return true
    }
}

@MainActor
enum CookieSetupTests {
    static func run() async {
        let suiteName = "cookie.tests.setup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let progress = CookieSetupProgress(defaults: defaults)
        progress.complete()
        precondition(!defaults.bool(forKey: CookieSetupProgress.completedKey), "Only the final step completes setup")
        progress.advance()
        progress.advance()
        let resumed = CookieSetupProgress(defaults: defaults)
        precondition(resumed.step == .screen, "A restart must return to the permission step")
        resumed.back()
        precondition(CookieSetupProgress(defaults: defaults).step == .voice)
        resumed.advance(); resumed.advance(); resumed.advance()
        precondition(!defaults.bool(forKey: CookieSetupProgress.completedKey), "Merely viewing Ready isn't completion")
        resumed.complete()
        precondition(defaults.bool(forKey: CookieSetupProgress.completedKey))
        let replay = CookieSetupProgress(defaults: defaults, replay: true)
        replay.advance()
        precondition(defaults.bool(forKey: CookieSetupProgress.completedKey), "Replay must not unset existing completion")
        precondition(defaults.object(forKey: CookieSetupProgress.stepKey) == nil, "Replay must not change first-run progress")
        print("PASS setup resumes, completes explicitly and replays without resetting the user")

        let provider = CookieFakePermissions()
        let permissions = CookiePermissionCenter(requiresSpeechRecognition: true, provider: provider, defaults: defaults)
        permissions.refresh()
        precondition(provider.requests.isEmpty && provider.captureChecks == 0, "Reading permissions must not prompt or capture")
        provider.statuses[.microphone] = .allowed
        permissions.refresh()
        precondition(!permissions.voiceReady, "Apple Speech also requires speech authorization")
        provider.statuses[.speech] = .allowed
        permissions.refresh()
        precondition(permissions.voiceReady)
        let remoteVoice = CookiePermissionCenter(requiresSpeechRecognition: false, provider: provider, defaults: defaults)
        precondition(!remoteVoice.applicablePermissions.contains(.speech) && remoteVoice.voiceReady)
        print("PASS permission reads are silent and speech access is provider-aware")

        provider.statuses[.microphone] = .denied
        permissions.refresh()
        await permissions.request(.microphone)
        precondition(provider.requests.isEmpty && provider.settingsOpened == [.microphone])
        provider.statuses[.microphone] = .restricted
        permissions.refresh()
        await permissions.request(.microphone)
        precondition(provider.settingsOpened.count == 1, "Restricted permissions must not send users into a request loop")
        print("PASS denied access opens Settings and restricted access does not re-prompt")

        provider.holdRequest = true
        let request = Task { await permissions.request(.screen) }
        while provider.requestContinuation == nil { await Task.yield() }
        await permissions.request(.screen)
        await permissions.request(.accessibility)
        precondition(provider.requests == [.screen], "Only one system permission request may be in flight")
        provider.requestContinuation?.resume()
        await request.value
        await permissions.request(.screen)
        precondition(provider.settingsOpened.last == .screen, "Retries should open Settings")
        print("PASS repeated clicks cannot stack permission prompts")

        await permissions.checkScreenAccess()
        precondition(provider.captureChecks == 0, "A screen check needs a real current grant")
        provider.statuses[.screen] = .allowed
        permissions.refresh()
        precondition(provider.captureChecks == 0, "Granting permission alone must not capture")
        await permissions.checkScreenAccess()
        precondition(permissions.screenVerified && provider.captureChecks == 1)
        provider.statuses[.screen] = .denied
        permissions.refresh()
        precondition(!permissions.screenVerified && !defaults.bool(forKey: "hasScreenContentPermission"), "Revocation invalidates old success")
        provider.statuses[.screen] = .allowed
        provider.captureSucceeds = false
        permissions.refresh()
        await permissions.checkScreenAccess()
        precondition(!permissions.screenVerified && permissions.screenCheckMessage != nil && !permissions.isBusy)
        print("PASS screen checks are explicit, recover from failure and respect revocation")

        provider.statuses[.accessibility] = .allowed
        permissions.refresh()
        precondition(!permissions.shortcutsReady, "The event tap also needs listen access")
        provider.statuses[.inputMonitoring] = .allowed
        permissions.refresh()
        precondition(permissions.shortcutsReady)
        provider.statuses[.inputMonitoring] = .denied
        permissions.refresh()
        precondition(!permissions.shortcutsReady)
        print("PASS shortcut readiness follows actual Accessibility and Input Monitoring grants")

        _ = NSApplication.shared
        var actions: [String] = []
        let existingPanelCount = NSApp.windows.filter { $0 is NSPanel }.count
        let menuManager = MenuBarPanelManager(openCookie: { actions.append("open") }, openSettings: { actions.append("settings") },
                                              openShortcuts: { actions.append("shortcuts") }, openSetup: { actions.append("setup") })
        let menu = menuManager.makeMenu()
        precondition(menu.items.map(\.title) == ["Open Cookie", "Settings…", "Teach Cookie a task", "Your taught tasks…", "Help", "", "Quit Cookie"])
        for item in [menu.items[0], menu.items[1], menu.items[4].submenu!.items[0], menu.items[4].submenu!.items[1]] {
            _ = NSApp.sendAction(item.action!, to: item.target, from: item)
        }
        precondition(actions == ["open", "settings", "shortcuts", "setup"])
        precondition(NSApp.windows.filter { $0 is NSPanel }.count == existingPanelCount, "The status menu must not construct the old floating popup")
        print("PASS native menu routes every action without constructing a duplicate panel")
        print("7 setup checks passed.")
    }

    static func render() {
        let suiteName = "cookie.tests.setup.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = CookieFakePermissions()
        let permissions = CookiePermissionCenter(requiresSpeechRecognition: true, provider: provider, defaults: defaults)
        for step in CookieSetupStep.allCases {
            snapshot("cookie-setup-\(step.label.lowercased())", step: step, permissions: permissions, width: 680, height: 620)
        }
        provider.statuses = [.microphone: .allowed, .speech: .denied, .screen: .allowed, .accessibility: .allowed, .inputMonitoring: .notDetermined]
        permissions.refresh()
        snapshot("cookie-setup-voice-denied", step: .voice, permissions: permissions, width: 500, height: 500)
        snapshot("cookie-setup-screen-compact", step: .screen, permissions: permissions, width: 500, height: 460)
        snapshot("cookie-setup-ready-partial", step: .ready, permissions: permissions, width: 680, height: 620)
    }

    private static func snapshot(_ name: String, step: CookieSetupStep, permissions: CookiePermissionCenter, width: CGFloat, height: CGFloat) {
        let view = CookieSetupContent(step: step, permissions: permissions, needsModel: true, back: {}, next: {}, dismiss: {})
            .frame(width: width, height: height).symbolEffectsRemoved()
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { preconditionFailure("Setup preview failed") }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/\(name).png")
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output)
        window.close()
        print("Rendered build/\(name).png")
    }
}
