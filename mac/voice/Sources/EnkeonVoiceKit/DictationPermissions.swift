//
//  DictationPermissions.swift
//  EnkeonVoiceKit
//
//  The permissions dictation needs and nothing more: no Screen Recording.
//  Taken from Cookie's CookiePermissions (cookie-harness 8ffefde) without the
//  screen check; Cookie's agent asks for that itself.
//

import Combine
import AppKit
import AVFoundation
import Speech

public enum DictationPermission: String, CaseIterable, Identifiable {
    case microphone, speech, accessibility, inputMonitoring
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .speech: return "Speech recognition"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }

    public var symbol: String {
        switch self {
        case .microphone: return "mic"
        case .speech: return "waveform"
        case .accessibility: return "cursorarrow.rays"
        case .inputMonitoring: return "keyboard"
        }
    }

    public var explanation: String {
        switch self {
        case .microphone: return "Hear you while you hold the dictation shortcut."
        case .speech: return "Use Apple Speech to turn your voice into words, on this Mac."
        case .accessibility: return "Put your words into the field you are typing in."
        case .inputMonitoring: return "Recognize the dictation keys while you work in another app."
        }
    }

    var settingsPane: String {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .speech: return "Privacy_SpeechRecognition"
        case .accessibility: return "Privacy_Accessibility"
        case .inputMonitoring: return "Privacy_ListenEvent"
        }
    }
}

public enum DictationPermissionStatus: Equatable {
    case notDetermined, denied, restricted, allowed
}

@MainActor
public protocol DictationPermissionProviding {
    func status(for permission: DictationPermission) -> DictationPermissionStatus
    func request(_ permission: DictationPermission) async
    func openSettings(for permission: DictationPermission)
}

@MainActor
public struct SystemDictationPermissions: DictationPermissionProviding {
    public init() {}

    public func status(for permission: DictationPermission) -> DictationPermissionStatus {
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
        case .accessibility: return AXIsProcessTrusted() ? .allowed : .notDetermined
        case .inputMonitoring: return CGPreflightListenEventAccess() ? .allowed : .notDetermined
        }
    }

    public func request(_ permission: DictationPermission) async {
        switch permission {
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speech:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring: _ = CGRequestListenEventAccess()
        }
    }

    public func openSettings(for permission: DictationPermission) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsPane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
public final class DictationPermissionCenter: ObservableObject {
    @Published public private(set) var statuses: [DictationPermission: DictationPermissionStatus] = [:]
    @Published public private(set) var requesting: DictationPermission?
    public let requiresSpeechRecognition: Bool
    private let provider: any DictationPermissionProviding
    private let defaults: UserDefaults

    public init(requiresSpeechRecognition: Bool, provider: (any DictationPermissionProviding)? = nil,
                defaults: UserDefaults = .standard) {
        self.requiresSpeechRecognition = requiresSpeechRecognition
        self.provider = provider ?? SystemDictationPermissions()
        self.defaults = defaults
        refresh()
    }

    public var voicePermissions: [DictationPermission] { requiresSpeechRecognition ? [.microphone, .speech] : [.microphone] }
    public var shortcutPermissions: [DictationPermission] { [.accessibility, .inputMonitoring] }
    public var applicablePermissions: [DictationPermission] { voicePermissions + shortcutPermissions }
    public var voiceReady: Bool { voicePermissions.allSatisfy(isAllowed) }
    public var shortcutsReady: Bool { shortcutPermissions.allSatisfy(isAllowed) }
    public var allAllowed: Bool { applicablePermissions.allSatisfy(isAllowed) }
    public var isBusy: Bool { requesting != nil }
    public func isAllowed(_ permission: DictationPermission) -> Bool { statuses[permission] == .allowed }
    public func wasRequested(_ permission: DictationPermission) -> Bool { defaults.bool(forKey: Self.requestedKey(permission)) }

    public func refresh() {
        let currentStatuses = Dictionary(uniqueKeysWithValues: applicablePermissions.map { ($0, provider.status(for: $0)) })
        if statuses != currentStatuses { statuses = currentStatuses }
    }

    /// The first ask shows the system prompt; after a denial or an earlier ask macOS won't prompt
    /// again, so the matching System Settings pane opens instead.
    public func request(_ permission: DictationPermission) async {
        guard !isBusy, !isAllowed(permission), statuses[permission] != .restricted else { return }
        requesting = permission
        defer { requesting = nil; refresh() }
        if statuses[permission] == .denied || wasRequested(permission) {
            // Accessibility and Input Monitoring list an app only once it has asked; asking again is
            // silent and puts Enkeon back in the list (after a reset, or a new build), then the pane opens.
            if permission == .accessibility || permission == .inputMonitoring { await provider.request(permission) }
            provider.openSettings(for: permission)
        } else {
            defaults.set(true, forKey: Self.requestedKey(permission))
            await provider.request(permission)
        }
    }

    public func openSettings(for permission: DictationPermission) { provider.openSettings(for: permission) }

    private static func requestedKey(_ permission: DictationPermission) -> String {
        "enkeon.permission.requested.\(permission.rawValue)"
    }
}
