import Combine
import AppKit
import AVFoundation
import ScreenCaptureKit
import Speech

enum CookiePermission: String, CaseIterable, Identifiable {
    case microphone, speech, screen, accessibility, inputMonitoring
    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .speech: return "Speech recognition"
        case .screen: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }

    var symbol: String {
        switch self {
        case .microphone: return "mic"
        case .speech: return "waveform"
        case .screen: return "rectangle.inset.filled"
        case .accessibility: return "cursorarrow.rays"
        case .inputMonitoring: return "keyboard"
        }
    }

    var explanation: String {
        switch self {
        case .microphone: return "Hear you while you hold the talk button or shortcut."
        case .speech: return "Use Apple Speech to turn your voice into words."
        case .screen: return "Include screen context when you ask Cookie a question."
        case .accessibility: return "Support the talk shortcut and circling things on screen."
        case .inputMonitoring: return "Recognize the talk keys while you work in another app."
        }
    }

    var settingsPane: String {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .speech: return "Privacy_SpeechRecognition"
        case .screen: return "Privacy_ScreenCapture"
        case .accessibility: return "Privacy_Accessibility"
        case .inputMonitoring: return "Privacy_ListenEvent"
        }
    }
}

enum CookiePermissionStatus: Equatable {
    case notDetermined, denied, restricted, allowed
}

@MainActor
protocol CookiePermissionProviding {
    func status(for permission: CookiePermission) -> CookiePermissionStatus
    func request(_ permission: CookiePermission) async
    func openSettings(for permission: CookiePermission)
    func verifyScreenAccess() async throws -> Bool
}

@MainActor
struct CookieSystemPermissions: CookiePermissionProviding {
    func status(for permission: CookiePermission) -> CookiePermissionStatus {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .allowed
            case .denied: return .denied
            case .restricted: return .restricted
            default: return .notDetermined
            }
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .allowed
            case .denied: return .denied
            case .restricted: return .restricted
            default: return .notDetermined
            }
        case .screen: return CGPreflightScreenCaptureAccess() ? .allowed : .notDetermined
        case .accessibility: return AXIsProcessTrusted() ? .allowed : .notDetermined
        case .inputMonitoring: return CGPreflightListenEventAccess() ? .allowed : .notDetermined
        }
    }

    func request(_ permission: CookiePermission) async {
        switch permission {
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speech:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        case .screen: _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring: _ = CGRequestListenEventAccess()
        }
    }

    func openSettings(for permission: CookiePermission) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsPane)") else { return }
        NSWorkspace.shared.open(url)
    }

    func verifyScreenAccess() async throws -> Bool {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { return false }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 32
        configuration.height = 32
        configuration.showsCursor = false
        // An explicit local check only: pixels never leave this function or reach a model.
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return image.width > 0 && image.height > 0
    }
}

@MainActor
final class CookiePermissionCenter: ObservableObject {
    @Published private(set) var statuses: [CookiePermission: CookiePermissionStatus] = [:]
    @Published private(set) var requesting: CookiePermission?
    @Published private(set) var isCheckingScreen = false
    @Published private(set) var screenVerified = false
    @Published private(set) var screenCheckMessage: String?
    let requiresSpeechRecognition: Bool
    private let provider: any CookiePermissionProviding
    private let defaults: UserDefaults

    init(requiresSpeechRecognition: Bool, provider: (any CookiePermissionProviding)? = nil,
         defaults: UserDefaults = .standard) {
        self.requiresSpeechRecognition = requiresSpeechRecognition
        self.provider = provider ?? CookieSystemPermissions()
        self.defaults = defaults
        refresh()
    }

    var voicePermissions: [CookiePermission] { requiresSpeechRecognition ? [.microphone, .speech] : [.microphone] }
    var shortcutPermissions: [CookiePermission] { [.accessibility, .inputMonitoring] }
    var applicablePermissions: [CookiePermission] { voicePermissions + [.screen] + shortcutPermissions }
    var voiceReady: Bool { voicePermissions.allSatisfy(isAllowed) }
    var shortcutsReady: Bool { shortcutPermissions.allSatisfy(isAllowed) }
    var allAllowed: Bool { applicablePermissions.allSatisfy(isAllowed) }
    var isBusy: Bool { requesting != nil || isCheckingScreen }
    func isAllowed(_ permission: CookiePermission) -> Bool { statuses[permission] == .allowed }
    func wasRequested(_ permission: CookiePermission) -> Bool { defaults.bool(forKey: "cookie.permission.requested.\(permission.rawValue)") }

    func refresh() {
        let currentStatuses = Dictionary(uniqueKeysWithValues: applicablePermissions.map { ($0, provider.status(for: $0)) })
        if statuses != currentStatuses { statuses = currentStatuses }
        if !isAllowed(.screen) {
            if screenVerified { screenVerified = false }
            if defaults.bool(forKey: "hasScreenContentPermission") { defaults.set(false, forKey: "hasScreenContentPermission") }
        }
    }

    func request(_ permission: CookiePermission) async {
        guard !isBusy, !isAllowed(permission), statuses[permission] != .restricted else { return }
        requesting = permission
        defer { requesting = nil; refresh() }
        if statuses[permission] == .denied || wasRequested(permission) {
            provider.openSettings(for: permission)
        } else {
            defaults.set(true, forKey: "cookie.permission.requested.\(permission.rawValue)")
            await provider.request(permission)
        }
    }

    func openSettings(for permission: CookiePermission) { provider.openSettings(for: permission) }

    func checkScreenAccess() async {
        guard !isBusy, isAllowed(.screen) else { return }
        isCheckingScreen = true
        screenCheckMessage = nil
        defer { isCheckingScreen = false }
        do {
            screenVerified = try await provider.verifyScreenAccess()
            if !screenVerified { screenCheckMessage = "No screen is available. Check your display connection and try again." }
        } catch {
            screenVerified = false
            screenCheckMessage = "The check didn’t finish. Confirm Cookie is enabled in System Settings. If macOS asks you to quit and reopen, setup will resume here."
        }
        defaults.set(screenVerified, forKey: "hasScreenContentPermission")
    }
}
