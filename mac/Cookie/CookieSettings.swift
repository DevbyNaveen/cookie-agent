//
//  CookieSettings.swift
//  Cookie
//
//  Settings pages, laid out like System Settings: a title, a line saying
//  what the page is for, then inset-grouped cards. Every switch here does
//  what it says today; nothing is a placeholder that pretends to work.
//

import AVFoundation
import ServiceManagement
import SwiftUI

struct CookieSettingsPage: View {
    let page: CookieNavigation.SettingsPage
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        CookieSettingsScaffold(page: page, subtitle: subtitle) { content }
    }

    private var subtitle: String {
        switch page {
        case .account: return "A companion of your own."
        case .general: return "Make Cookie feel at home on your Mac."
        case .privacy: return "Your screen, your conversations, your boundaries."
        case .permissions: return "Choose what Cookie can see and hear."
        case .voice: return "A voice to talk with. A model to think with."
        case .shortcuts: return "A few small shortcuts. Always within reach."
        case .cursor: return "A little pointer when you need a hand."
        case .connectors: return "Bring your apps into the conversation."
        case .about: return "A little companion for your Mac."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .account: AccountPage()
        case .general: GeneralPage()
        case .privacy: PrivacyPage(companionManager: companionManager)
        case .permissions: PermissionsPage(permissions: companionManager.permissionCenter)
        case .voice: VoicePage(companionManager: companionManager)
        case .shortcuts: ShortcutsPage()
        case .cursor: CursorPage(companionManager: companionManager)
        case .connectors: ConnectorsPage()
        case .about: AboutPage()
        }
    }
}

struct CookieSettingsScaffold<Content: View>: View {
    let page: CookieNavigation.SettingsPage
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: page.symbol)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(CK.accent)
                        .frame(width: 48, height: 48)
                        .background(RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(LinearGradient(colors: [CK.accent.opacity(0.15), CK.accent.opacity(0.045)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(CK.accent.opacity(0.13), lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(page.title).font(.system(size: 23, weight: .semibold)).tracking(-0.5)
                            .foregroundStyle(CK.text)
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(CK.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 4)
                content
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 32)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .id(page)
        .transition(.opacity)
        .cookieMotionPreferences()
    }
}

// MARK: - Building blocks

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(CK.secondary)
            .padding(.leading, 4)
    }
}

struct SettingsGroup<Content: View>: View {
    var label: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let label { SectionLabel(text: label) }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.055), Color.white.opacity(0.025)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(CK.hairline, lineWidth: 0.75))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    var caption: String?
    var symbol: String?
    /// With a tint the symbol sits on a coloured tile, like app icons in System Settings.
    var tint: Color?
    var divider = true
    var stacked = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tint ?? CK.secondary)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill((tint ?? .white).opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder((tint ?? .white).opacity(0.09), lineWidth: 0.5))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(CK.text)
                    if let caption {
                        Text(caption)
                            .font(.system(size: 11.5))
                            .foregroundStyle(CK.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if stacked { trailing.padding(.top, 6) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !stacked { trailing.fixedSize(horizontal: true, vertical: false) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            if divider {
                Rectangle().fill(Color.white.opacity(0.055)).frame(height: 0.5).padding(.leading, symbol == nil ? 14 : 54)
            }
        }
    }
}

private struct SettingsSwitch: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch).tint(CK.accent).labelsHidden()
            .controlSize(.small).cookiePointingCursor()
            .accessibilityLabel(title)
    }
}

private struct StatusDot: View {
    let granted: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(granted ? Color.green : Color.orange).frame(width: 6, height: 6)
            Text(granted ? "Allowed" : "Not allowed")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(granted ? Color.green.opacity(0.9) : Color.orange.opacity(0.9))
        }
    }
}

// MARK: - Pages

private struct AccountPage: View {
    @ObservedObject private var account = CookieAccount.shared

    private var initials: String {
        NSFullUserName().split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    var body: some View {
        SettingsGroup {
            HStack(spacing: 14) {
                Circle()
                    .fill(LinearGradient(colors: [CK.accent.opacity(0.7), CK.accent.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 46, height: 46)
                    .overlay(Text(initials).font(.system(size: 16, weight: .semibold)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(NSFullUserName()).font(.system(size: 14, weight: .semibold))
                    Text(status).font(.system(size: 12)).foregroundStyle(CK.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                switch account.phase {
                case .signedIn:
                    PillButton(title: "Sign out") { account.signOut() }
                case .waitingForBrowser:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        PillButton(title: "Cancel") { account.cancelSignIn() }
                    }
                case .signedOut, .failed:
                    PillButton(title: "Sign in", symbol: "arrow.up.forward.app", primary: true) { account.signIn() }
                }
            }
            .padding(14)
        }
        Text("Signing in opens enkeon.com in your browser, where you choose a project. Cookie gets a key for that project only, kept in your Keychain; your password never passes through Cookie. Your chats stay on this Mac.")
            .font(.system(size: 11))
            .foregroundStyle(CK.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
        EnkeonSettings()
    }

    private var status: String {
        switch account.phase {
        case .signedIn: return "Signed in to Enkeon"
        case .waitingForBrowser: return "Finish signing in in your browser…"
        case .signedOut: return "Not signed in to Enkeon"
        case .failed(let why): return why
        }
    }
}

private struct GeneralPage: View {
    @AppStorage(CK.Key.showInDock) private var showInDock = false
    @AppStorage(CK.Key.showInRecordings) private var showInRecordings = true
    @AppStorage(CK.Key.peekOnHover) private var peekOnHover = true
    @AppStorage(CK.Key.sounds) private var sounds = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        CookieGeneralSettingsContent(showInDock: $showInDock, showInRecordings: $showInRecordings,
                                     peekOnHover: $peekOnHover, sounds: $sounds,
                                     openAtLogin: Binding(get: { openAtLogin }, set: setOpenAtLogin),
                                     loginError: loginError)
        NotificationSettings()
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "macOS said no: \(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct CookieGeneralSettingsContent: View {
    @Binding var showInDock: Bool
    @Binding var showInRecordings: Bool
    @Binding var peekOnHover: Bool
    @Binding var sounds: Bool
    @Binding var openAtLogin: Bool
    var loginError: String?

    var body: some View {
        SettingsGroup(label: "On your Mac") {
            SettingsRow(title: "Show in Dock", caption: "Keep Cookie in the Dock as well as the notch.", symbol: "macwindow", tint: CK.accent) {
                SettingsSwitch(title: "Show in Dock", isOn: $showInDock)
            }
            SettingsRow(title: "Show in screen recordings", caption: "Include Cookie when you share or record your screen.", symbol: "rectangle.on.rectangle", tint: CK.accent) {
                SettingsSwitch(title: "Show in screen recordings", isOn: $showInRecordings)
            }
            SettingsRow(title: "Peek on hover", caption: "Pause over the notch to see your recent chats.", symbol: "cursorarrow", tint: CK.accent) {
                SettingsSwitch(title: "Peek on hover", isOn: $peekOnHover)
            }
            SettingsRow(title: "Sounds", caption: "Little tunes when Cookie opens, listens, sends and finishes.", symbol: "speaker.wave.2", tint: CK.accent, divider: false) {
                SettingsSwitch(title: "Sounds", isOn: $sounds)
            }
        }
        SettingsGroup(label: "Ready when you are") {
            SettingsRow(title: "Open at login", caption: loginError ?? "Have Cookie waiting when you start your Mac.", symbol: "power", tint: CK.accent, divider: false) {
                SettingsSwitch(title: "Open at login", isOn: $openAtLogin)
            }
        }
    }
}

private struct PermissionsPage: View {
    @ObservedObject var permissions: CookiePermissionCenter

    var body: some View {
        VStack(spacing: 0) {
            ForEach(permissions.applicablePermissions) { permission in
                CookiePermissionRow(permission: permission, permissions: permissions)
                if permission != permissions.applicablePermissions.last {
                    Rectangle().fill(CK.hairline).frame(height: 0.5).padding(.leading, 53)
                }
            }
        }
        .cookieCard()
        if permissions.isAllowed(.screen) {
            HStack {
                Text(permissions.screenVerified ? "Screen access checked" : "Verify screen access with a local capture.")
                    .font(.system(size: 11)).foregroundStyle(CK.secondary)
                Spacer()
                if permissions.isCheckingScreen { ProgressView().controlSize(.small) }
                else {
                    PillButton(title: "Check access") { Task { await permissions.checkScreenAccess() } }
                        .disabled(permissions.isBusy)
                }
            }
        }
        if let message = permissions.screenCheckMessage {
            Text(message).font(.system(size: 11)).foregroundStyle(CK.secondary)
        }
        Text("Access is optional. Your screen is shared with your chosen model only when you talk to Cookie, circle something, or press the screen button. The local screen check is discarded and never sent.")
            .font(.system(size: 11)).foregroundStyle(CK.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct VoicePage: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        ModelSettings()
        SettingsGroup(label: "Listening") {
            SettingsRow(title: "Speech recognition", caption: "Turns your voice into text before Cookie reads it.", divider: false) {
                Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                    .font(.system(size: 12))
                    .foregroundStyle(CK.secondary)
            }
        }
        SettingsGroup(label: "Speaking") {
            CredentialRow(field: CookieModelSettings.elevenLabsField, title: "ElevenLabs key",
                          caption: "Optional. With a key, Cookie's spoken replies use ElevenLabs, and the reply's text is sent to ElevenLabs to be spoken. Without one, the best voice installed on this Mac speaks, on this Mac.",
                          divider: false)
        }
    }
}

/// provider:model and its credentials. No default: the harness has none,
/// and Cookie never answers with a model nobody chose.
private struct ModelSettings: View {
    @AppStorage(CookieModelSettings.modelKey) private var model = ""
    /// Bumped when a credential is saved, so the status line reads the Keychain again.
    @State private var saved = 0

    private var trimmed: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var provider: CookieModelSettings.Provider? { CookieModelSettings.provider(of: trimmed) }
    private var missing: String? { _ = saved; return CookieModelSettings.missing(model: trimmed) }

    var body: some View {
        if trimmed.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(CK.secondary)
                Text("Cookie needs a model before it can answer. Choose one below — for example anthropic:claude-sonnet-4-6, or ollama:qwen3 to think on this Mac with no key.")
                    .font(.system(size: 12))
                    .foregroundStyle(CK.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cookieCard()
        }

        SettingsGroup(label: "Model") {
            SettingsRow(title: "Model", caption: "provider:model — anthropic, openai, gemini, bedrock or ollama.") {
                TextField("anthropic:claude-sonnet-4-6", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 240)
                    .autocorrectionDisabled()
            }
            if let provider {
                if provider.fields.isEmpty {
                    SettingsRow(title: "API key", caption: provider.note, divider: false) { EmptyView() }
                }
                ForEach(Array(provider.fields.enumerated()), id: \.element) { index, field in
                    CredentialRow(field: field, title: "\(provider.title) \(field.label.lowercased())",
                                  caption: index == provider.fields.count - 1 && !provider.note.isEmpty ? provider.note : nil,
                                  divider: index < provider.fields.count - 1) { saved += 1 }
                }
            } else {
                SettingsRow(title: "API key", caption: "Choose the model first; the key depends on the provider.", divider: false) { EmptyView() }
            }
        }

        HStack(spacing: 6) {
            Circle().fill(missing == nil ? Color.green : Color.orange).frame(width: 6, height: 6)
            Text(missing ?? "Ready. Cookie thinks with \(trimmed).")
                .font(.system(size: 11))
                .foregroundStyle(CK.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }
}

/// One credential in the Keychain. Secrets are never shown back: only
/// whether one is there. Plain values (a region) are shown.
private struct CredentialRow: View {
    let field: CookieModelSettings.Field
    let title: String
    var caption: String?
    var divider = true
    var onSave: () -> Void = {}

    @State private var draft = ""
    @State private var stored: String?
    @State private var error: String?

    private var defaultCaption: String {
        field.secret ? "Kept in your Keychain and handed only to Cookie's helper. Never saved anywhere else."
                     : (field.required ? "Kept in your Keychain." : "Optional. Kept in your Keychain.")
    }

    var body: some View {
        SettingsRow(title: title, caption: error ?? caption ?? defaultCaption, divider: divider) {
            if let stored {
                HStack(spacing: 8) {
                    if field.secret {
                        Label("In Keychain", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green)
                    } else {
                        Text(stored).font(.system(size: 12, design: .monospaced)).foregroundStyle(CK.secondary)
                    }
                    PillButton(title: "Remove") { save("") }
                }
            } else {
                HStack(spacing: 6) {
                    Group {
                        if field.secret { SecureField("Paste", text: $draft) } else { TextField("eu-central-1", text: $draft) }
                    }
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .onSubmit { save(draft) }
                    PillButton(title: "Save", primary: true) { save(draft) }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: field) { _, _ in refresh() }
    }

    private func refresh() {
        draft = ""
        error = nil
        stored = CookieModelSettings.value(field)
    }

    private func save(_ value: String) {
        do {
            try CookieModelSettings.setValue(value, for: field)
            refresh()
            onSave()
        } catch {
            self.error = "Couldn't save to the Keychain: \(error.localizedDescription)"
        }
    }
}

/// Enkeon context: off unless switched on and a key is saved.
private struct EnkeonSettings: View {
    @AppStorage(CookieModelSettings.enkeonEnabledKey) private var enabled = true
    @ObservedObject private var account = CookieAccount.shared
    @State private var saved = 0

    private var hasKey: Bool { _ = saved; return account.isSignedIn || CookieModelSettings.value(CookieModelSettings.enkeonField) != nil }

    var body: some View {
        SettingsGroup(label: "Enkeon") {
            SettingsRow(title: "Use your Enkeon context",
                        caption: enabled && !hasKey ? "Sign in above, or add an Enkeon key below; until then Cookie answers without it."
                                                    : "Cookie can look things up in Enkeon. Saving anything there asks you first.") {
                Toggle("", isOn: $enabled).toggleStyle(.switch).tint(CK.accent).labelsHidden()
            }
            CredentialRow(field: CookieModelSettings.enkeonField, title: "Enkeon key",
                          caption: "Only if you'd rather not sign in: a project key (tr_sk_…). Signing in is used first.",
                          divider: false) { saved += 1 }
        }
    }
}

private struct ShortcutsPage: View {
    var body: some View {
        SettingsGroup {
            SettingsRow(title: "Talk", caption: "Hold, speak, let go. Cookie looks at your screen and answers.") {
                HStack(spacing: 6) { Text("Hold").font(.system(size: 11)).foregroundStyle(CK.tertiary); TalkKeys() }
            }
            SettingsRow(title: "Open Cookie", caption: "Click the notch.") {
                Image(systemName: "rectangle.topthird.inset.filled").foregroundStyle(CK.secondary)
            }
            SettingsRow(title: "Close", caption: "Folds Cookie back into the notch.", divider: false) {
                KeyCap(label: "esc")
            }
        }
    }
}

private struct CursorPage: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        SettingsGroup {
            SettingsRow(title: "Show Cookie by your pointer", caption: "Off hides the blue pointer until you talk to Cookie.", divider: false) {
                SettingsSwitch(title: "Show Cookie by your pointer", isOn: Binding(get: { companionManager.isCookieCursorEnabled }, set: companionManager.setCookieCursorEnabled))
            }
        }
    }
}

private struct ConnectorsPage: View {
    private let apps: [(name: String, detail: String, symbol: String, tint: Color)] = [
        ("Gmail", "Read threads, draft replies you approve.", "envelope.fill", .red),
        ("Google Calendar", "See what's next, find free time.", "calendar", .blue),
        ("Slack", "Read channels and threads you're in.", "number", .purple),
        ("LinkedIn", "Keep track of conversations.", "person.2.fill", .cyan),
        ("Google Drive", "Find and open your files.", "folder.fill", .green),
        ("Notion", "Read pages and databases.", "doc.text.fill", .gray),
        ("GitHub", "Issues, pull requests and repos.", "chevron.left.forwardslash.chevron.right", .indigo),
    ]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(CK.secondary)
            Text("Connecting apps needs your Enkeon sign-in. Every message Cookie sends asks you first.")
                .font(.system(size: 12))
                .foregroundStyle(CK.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cookieCard()

        SettingsGroup {
            ForEach(Array(apps.enumerated()), id: \.offset) { index, app in
                SettingsRow(title: app.name, caption: app.detail, symbol: app.symbol, tint: app.tint, divider: index < apps.count - 1) {
                    PillButton(title: "Connect") {}
                        .disabled(true)
                        .opacity(0.45)
                }
            }
        }
    }
}

private struct AboutPage: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "–") (\(info?["CFBundleVersion"] as? String ?? "–"))"
    }

    var body: some View {
        SettingsGroup {
            SettingsRow(title: "Cookie by Enkeon", caption: "Version \(version)", divider: false) { CookieAvatar(size: 30) }
        }
    }
}

private struct PrivacyPage: View {
    @ObservedObject var companionManager: CompanionManager
    @AppStorage(Redactor.hideSecretsKey) private var hideSecrets = true
    @AppStorage(Redactor.blurFacesKey) private var blurFaces = true
    @AppStorage(ChatLock.enabledKey) private var requireTouchID = false
    @AppStorage(CaptureGuard.userBlockedKey) private var userBlockedRaw = ""
    @AppStorage(CookieScreenMemory.enabledKey) private var screenMemory = true
    @State private var confirmDelete = false

    private var userBlocked: [String] { UserDefaults.standard.stringArray(forKey: CaptureGuard.userBlockedKey) ?? [] }

    var body: some View {
        SettingsGroup(label: "Never looks") {
            SettingsRow(title: "Password fields", caption: "While a password is being typed anywhere, or a password field is selected, Cookie doesn't take a picture.",
                        symbol: "key.fill", tint: .gray) {
                Text("Always").font(.system(size: 11, weight: .medium)).foregroundStyle(CK.secondary)
            }
            ForEach(CaptureGuard.defaultBlockedApps.sorted(by: { $0.value < $1.value }), id: \.key) { _, name in
                SettingsRow(title: name, caption: "Cut out of every picture.", symbol: "lock.fill", tint: .gray) {
                    Text("Built in").font(.system(size: 11, weight: .medium)).foregroundStyle(CK.tertiary)
                }
            }
            ForEach(userBlocked, id: \.self) { id in
                SettingsRow(title: appName(id), caption: "Cut out of every picture.", symbol: "lock.fill", tint: .orange) {
                    PillButton(title: "Remove") { setBlocked(userBlocked.filter { $0 != id }) }
                }
            }
            SettingsRow(title: "Block another app", caption: "Banking apps, health records, anything private.", divider: false) {
                CookieMenu("Block another app", items: runningApps.compactMap { app in
                    guard let id = app.bundleIdentifier else { return nil }
                    return CookieMenuItem(app.localizedName ?? id, id: id) { setBlocked(userBlocked + [id]) }
                }) {
                    CookieMenuLabel(title: "Add", symbol: "plus")
                }
            }
        }

        OpeningSettings()
        WritingSettings()

        SettingsGroup(label: "Hidden before anything leaves your Mac") {
            SettingsRow(title: "Card numbers, bank numbers and keys", caption: "Blacked out on this Mac before a picture is sent: card numbers, IBANs, API keys, tokens and private keys.") {
                SettingsSwitch(title: "Hide card numbers, bank numbers and keys", isOn: $hideSecrets)
            }
            SettingsRow(title: "Faces", caption: "Faces on screen are blurred. Cookie never tries to recognise who someone is.", divider: false) {
                SettingsSwitch(title: "Blur faces", isOn: $blurFaces)
            }
        }

        SettingsGroup(label: "What Cookie saw") {
            SettingsRow(title: "Remember the words on screen for a day", caption: "Text Cookie read when it looked, after the same hiding as the picture, sealed on this Mac. So you can ask about something you saw an hour ago.", symbol: "eye", tint: CK.accent) {
                SettingsSwitch(title: "Remember the words on screen", isOn: $screenMemory)
            }
            SettingsRow(title: "Forget it all", caption: "Clears everything Cookie read off your screen.", divider: false) {
                PillButton(title: "Forget") { CookieScreenMemory.shared.forgetAll() }
            }
        }

        SettingsGroup(label: "Your chats") {
            SettingsRow(title: "Encrypted on this Mac", caption: "AES-256, with the key in your Keychain. Pictures of your screen are never saved.") {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
            SettingsRow(title: "Require Touch ID", caption: "Ask before showing chats. Locks again when your screen locks or after 15 minutes.") {
                SettingsSwitch(title: "Require Touch ID", isOn: Binding(get: { requireTouchID }, set: { on in
                    requireTouchID = on
                    if on { ChatLock.shared.lock() }
                }))
            }
            SettingsRow(title: "Delete all chats", caption: "Removes every chat from this Mac. This can't be undone.", divider: false) {
                PillButton(title: "Delete…") { confirmDelete = true }
            }
        }
        .confirmationDialog("Delete all chats?", isPresented: $confirmDelete) {
            Button("Delete All Chats", role: .destructive) { companionManager.deleteAllThreads() }
        } message: {
            Text("Every chat on this Mac is removed. This can't be undone.")
        }

        Text("Cookie is an AI and can be wrong. It only looks when you talk to it, circle something or press the screen button, and only your own words count as instructions — text on screen is never obeyed.")
            .font(.system(size: 11))
            .foregroundStyle(CK.tertiary)
            .padding(.horizontal, 4)
    }

    private var runningApps: [NSRunningApplication] {
        let blocked = CaptureGuard.blockedBundleIDs
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !blocked.contains($0.bundleIdentifier!) && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func appName(_ id: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return id
    }

    private func setBlocked(_ ids: [String]) {
        UserDefaults.standard.set(Array(Set(ids)).sorted(), forKey: CaptureGuard.userBlockedKey)
        userBlockedRaw = ids.joined(separator: ",") // ponytail: nudges SwiftUI to redraw the list
    }
}

/// When Cookie may open apps, System Settings and links without the card,
/// and the apps you said "Always allow" to.
/// Where Cookie may type without a card each time.
private struct WritingSettings: View {
    @AppStorage(CookieWriteGrants.key) private var appsRaw = ""
    private var apps: [String] { CookieWriteGrants.apps }
    private var runningApps: [String] {
        Array(Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap(\.localizedName))).sorted()
    }

    var body: some View {
        SettingsGroup(label: "Writing where you are") {
            SettingsRow(title: "Typing without a card", caption: "In these apps, dictation and drafts land at your cursor without asking. Sending, paying and deleting still ask.",
                        symbol: "keyboard", tint: CK.accent) {
                Text(apps.isEmpty ? "No apps yet" : "\(apps.count) app\(apps.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(CK.secondary)
            }
            ForEach(apps, id: \.self) { app in
                SettingsRow(title: app, caption: "Cookie may type here.", symbol: "app", tint: CK.accent) {
                    PillButton(title: "Remove") { CookieWriteGrants.forget(app); appsRaw = UUID().uuidString }
                }
            }
            SettingsRow(title: "Allow another app", caption: "Mail, Notes, Slack, Pages, a spreadsheet.", divider: false) {
                CookieMenu("Allow another app", items: runningApps.map { name in
                    CookieMenuItem(name, checked: apps.contains(name)) { CookieWriteGrants.allow(name); appsRaw = UUID().uuidString }
                }) {
                    CookieMenuLabel(title: "Add", symbol: "plus")
                }
            }
        }
    }
}

private struct OpeningSettings: View {
    @AppStorage(CookieOpen.modeKey) private var mode = CookieOpen.Mode.ask.rawValue
    @State private var always = CookieOpen.always

    private var caption: String {
        switch CookieOpen.Mode(rawValue: mode) ?? .ask {
        case .ask: return "Cookie shows a card and waits for your yes, except for the apps below."
        case .apps: return "Apps and System Settings open straight away. Web links still ask."
        case .all: return "Everything opens straight away, web links too. A link's address can carry what Cookie read, so only choose this if you trust every page you show it. Only your own words can name what opens."
        }
    }

    var body: some View {
        SettingsGroup(label: "Opening apps and links") {
            SettingsRow(title: "Open without asking", caption: caption, symbol: "arrow.up.forward.app", tint: CK.accent,
                        divider: !always.isEmpty) {
                CookieChoice("Open without asking", selection: $mode, options: [
                    (CookieOpen.Mode.ask.rawValue, "Never"),
                    (CookieOpen.Mode.apps.rawValue, "Apps and settings"),
                    (CookieOpen.Mode.all.rawValue, "Everything"),
                ])
            }
            ForEach(Array(always.enumerated()), id: \.element) { index, key in
                SettingsRow(title: CookieOpen.name(ofAlwaysKey: key), caption: "You chose Always allow.",
                            divider: index < always.count - 1) {
                    PillButton(title: "Remove") { CookieOpen.forget(key) }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            always = CookieOpen.always
        }
    }
}

/// When Cookie may use macOS notifications (only while you're away from the Mac).
private struct NotificationSettings: View {
    @AppStorage(CookieNotifications.levelKey) private var level = CookieNotifications.Level.all.rawValue

    var body: some View {
        SettingsGroup(label: "When you're away") {
            SettingsRow(title: "Notifications",
                        caption: "If Cookie finishes or needs your OK while you're away from the Mac (idle a minute, or locked), it leaves a notification. Clicking it opens the chat; approvals are always answered on Cookie's card.",
                        symbol: "bell.badge", tint: CK.accent, divider: false) {
                CookieChoice("Notifications", selection: $level, options: [
                    (CookieNotifications.Level.all.rawValue, "Replies and approvals"),
                    (CookieNotifications.Level.important.rawValue, "Approvals and failures"),
                    (CookieNotifications.Level.off.rawValue, "Off"),
                ])
            }
        }
    }
}
