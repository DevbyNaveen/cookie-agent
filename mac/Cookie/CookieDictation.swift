//
//  CookieDictation.swift
//  Cookie
//
//  Enkeon dictation inside Cookie: one DictationController (EnkeonVoiceKit) owns the keyboard tap
//  and types your words. Cookie listens on the same tap (`controller.shortcuts`) for Talk, hover
//  and conversation, and steps aside for every dictation chord.
//
//  Fn+⇧ keeps what you say in Enkeon through Cookie's sign-in; Fn+⌃ edits with Cookie's Anthropic
//  key (or on this Mac). Neither ever runs while a password field has focus.
//

import AppKit
import EnkeonVoiceKit
import Foundation

@MainActor
final class CookieDictation {
    static let shared = CookieDictation()
    let controller = DictationController()

    static let secureRefusal = "Cookie doesn't listen into password fields. Choose another field."
    /// `kAXSecureTextFieldSubrole`: every native password field reports it.
    nonisolated static func refusesSecure(subrole: String?) -> Bool { subrole == "AXSecureTextField" }

    // Seams for the checks; the defaults are the real thing.
    var focusedIsSecure: () -> Bool = { CaptureGuard.focusedElementIsSecure() }
    var remember: (_ text: String, _ app: String) async -> (message: String, success: Bool) = CookieDictation.rememberInEnkeon
    var edit: (_ selected: String, _ instruction: String) async throws -> String? = CookieDictation.editWithCookiesEditor

    private var termsRefresh: Task<Void, Never>?

    private init() {
        EnkeonClient.shared.tokenSource = { await CookieAccount.shared.accessToken() }
        controller.saveToMemory = { [weak self] text, app in
            guard let self else { return ("", false) }
            if self.focusedIsSecure() { return (Self.secureRefusal, false) }
            return await self.remember(text, app)
        }
        controller.editSelection = { [weak self] selected, instruction, _ in
            guard let self else { return nil }
            if self.focusedIsSecure() { throw CloudVoiceEditor.Failure(Self.secureRefusal) }
            return try await self.edit(selected, instruction)
        }
    }

    /// Needs Accessibility and Input Monitoring; called again by the permission poller once granted.
    func start() {
        controller.start()
        guard termsRefresh == nil else { return }
        // Enkeon's project names, so dictation spells them right; every half hour, as Voice did.
        termsRefresh = Task { [weak self] in
            while !Task.isCancelled {
                if CookieAccount.shared.isSignedIn, let names = try? await EnkeonClient.shared.branchNames() {
                    self?.controller.enkeonTerms = names.map { $0.replacingOccurrences(of: "[-_.]+", with: " ", options: .regularExpression) }
                }
                try? await Task.sleep(for: .seconds(1800))
            }
        }
    }

    func stop() {
        controller.stop()
        termsRefresh?.cancel()
        termsRefresh = nil
    }

    private static func rememberInEnkeon(_ text: String, _ app: String) async -> (message: String, success: Bool) {
        guard CookieAccount.shared.isSignedIn else {
            return ("Sign in to Enkeon in Settings → Account to keep this in memory. Your words are kept here.", false)
        }
        do {
            let reply = try await EnkeonClient.shared.rememberNote(text, app: app)
            return (EnkeonClient.memoryID(fromReply: reply).map { "Kept in Enkeon (\($0))." } ?? "Kept in Enkeon.", true)
        } catch {
            return ("Couldn't keep this in Enkeon: \(error.localizedDescription) Your words are kept here.", false)
        }
    }

    /// Settings → Voice picks the editor: "apple" edits on this Mac, anything else uses Anthropic.
    static let editorProviderKey = "enkeon.editor.provider"
    private static func editWithCookiesEditor(_ selected: String, _ instruction: String) async throws -> String? {
        if UserDefaults.standard.string(forKey: editorProviderKey) == "apple" {
            return await SpeechHelper.shared.rewrite(selected, mode: "edit", instruction: instruction, deadline: 8)
        }
        guard let key = CookieModelSettings.value(CookieModelSettings.Field(variable: "ANTHROPIC_API_KEY", label: "API key")) else {
            throw CloudVoiceEditor.Failure("Add an Anthropic key in Settings → Account to edit by voice, or choose on-device editing in Settings → Voice.")
        }
        return try await CloudVoiceEditor().edit(selected, instruction: instruction, apiKey: key)
    }
}
