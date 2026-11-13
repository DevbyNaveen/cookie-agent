//
//  TextFieldAccess.swift
//  EnkeonVoiceKit
//
//  The few Accessibility reads dictation needs to find the focused field and
//  refuse the ones it must never type into. Taken from Cookie's MacOperator,
//  MacSafety and CaptureGuard (cookie-harness 8ffefde); Cookie's computer use
//  keeps the rest.
//

import AppKit
import ApplicationServices

enum TextFieldAccess {
    /// Require direct selected-text replacement, not whole-value writes. Some
    /// editors expose a writable selection but a read-only whole-field value.
    /// Terminal screen/scrollback does not gain edit permission from its role.
    static func isVerifiedEditable(_ element: AXUIElement) -> Bool {
        guard [kAXTextFieldRole, kAXTextAreaRole].contains(string(element, kAXRoleAttribute) ?? "") else { return false }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success
            && settable.boolValue
    }
    /// Apps dictation never types into. Users can add their own under `userBlockedKey`.
    static let defaultBlockedApps: [String: String] = [
        "com.1password.1password": "1Password",
        "com.agilebits.onepassword7": "1Password 7",
        "com.bitwarden.desktop": "Bitwarden",
        "org.keepassxc.keepassxc": "KeePassXC",
        "com.lastpass.LastPass": "LastPass",
        "com.apple.Passwords": "Passwords",
        "com.apple.keychainaccess": "Keychain Access",
    ]

    static let userBlockedKey = "enkeon.blockedApps"

    static var blockedBundleIDs: Set<String> {
        Set(defaultBlockedApps.keys).union(UserDefaults.standard.stringArray(forKey: userBlockedKey) ?? [])
    }

    /// Bundle ids and App Store categories dictation never types into.
    static func blocked(bundleID: String?, category: String?) -> Bool {
        if let bundleID, blockedBundleIDs.contains(bundleID) { return true }
        return ["public.app-category.finance", "public.app-category.medical"].contains(category ?? "")
    }

    static func category(_ app: NSRunningApplication) -> String? {
        guard let url = app.bundleURL, let bundle = Bundle(url: url) else { return nil }
        return bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
    }

    /// Chromium browsers and Electron apps (Chrome, X and LinkedIn in a browser, Claude, Slack) build
    /// their accessibility tree only when an assistive app asks, so until then there is no focused
    /// field to type into. Electron answers AXManualAccessibility; Chrome only AXEnhancedUserInterface,
    /// which is set only when the first is refused because it can slow window animations.
    static func exposeFields(_ app: NSRunningApplication) {
        guard AXIsProcessTrusted(), app.processIdentifier != getpid() else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        if AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue) != .success {
            AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    static func focusedElement() -> AXUIElement? {
        guard let value = attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// AXSecureTextField is the subrole every native password field reports.
    static func focusedElementIsSecure() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
        AXUIElementSetMessagingTimeout(element as! AXUIElement, 0.2)
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSubroleAttribute as CFString, &subrole) == .success else {
            return false
        }
        return (subrole as? String) == (kAXSecureTextFieldSubrole as String)
    }

    /// Where the text cursor is, in screen coordinates (AppKit's: origin bottom-left), or nil when the
    /// focused app doesn't say (terminals, many Electron apps).
    @MainActor public static func caretRect() -> CGRect? {
        guard AXIsProcessTrusted(), let element = focusedElement(), let range = TextDestination.selectionRange(element) else { return nil }
        let end = range.location + range.length
        // An empty range has no bounds in many apps; the character before the cursor always does.
        let probes = [CFRange(location: end, length: 0), CFRange(location: max(0, end - 1), length: end > 0 ? 1 : 0)]
        for var probe in probes {
            guard let value = AXValueCreate(.cfRange, &probe) else { continue }
            var out: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, value, &out) == .success,
                  let out, CFGetTypeID(out) == AXValueGetTypeID() else { continue }
            var rect = CGRect.zero
            guard AXValueGetValue(out as! AXValue, .cgRect, &rect), rect.height > 2 else { continue }
            let caretX = probe.length == 0 ? rect.minX : rect.maxX
            // Accessibility measures from the top of the primary screen; AppKit from its bottom.
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            return CGRect(x: caretX, y: top - rect.maxY, width: 1, height: rect.height)
        }
        return nil
    }

    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "org.alacritty", "com.mitchellh.ghostty", "co.zeit.hyper", "com.github.wez.wezterm", "dev.commandline.waveterm",
        "com.cmuxterm.app",
    ]

    /// A terminal app, or a terminal inside another app (an editor's panel names itself "Terminal").
    /// A line break typed into one is Return, so dictation never sends one there.
    static func isTerminal(pid: pid_t, element: AXUIElement) -> Bool {
        if let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           terminalBundleIDs.contains(bundleID) { return true }
        return [label(element), string(element, kAXRoleDescriptionAttribute) ?? ""]
            .contains { $0.range(of: "terminal", options: .caseInsensitive) != nil }
    }

    static func label(_ element: AXUIElement) -> String {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute, "AXIdentifier"] {
            if let text = string(element, key), !text.isEmpty { return String(text.prefix(80)) }
        }
        if let value = string(element, kAXValueAttribute), !value.isEmpty, value.count <= 80 { return value }
        return ""
    }

    // Pure reads of another app's tree, safe off the main thread.

    /// The title of the front app's focused window ("Re: renewal — Mail"), when it has one.
    static func focusedWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let window = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return string(window as! AXUIElement, kAXTitleAttribute)
    }

    nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    nonisolated static func string(_ element: AXUIElement, _ name: String) -> String? {
        let value = attribute(element, name)
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
