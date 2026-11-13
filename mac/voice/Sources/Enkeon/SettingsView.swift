import EnkeonVoiceKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(HistoryStore.enabledKey) private var historyEnabled = true
    @AppStorage(AppModel.completeKey) private var finishSentences = true
    @AppStorage(AppModel.completeMemoryKey) private var completeWithMemory = true
    @AppStorage(AppModel.phrasesKey) private var learnPhrases = true
    @AppStorage(AppModel.proofreadKey) private var proofread = true
    @State private var confirmForget = false
    @AppStorage(AppModel.barWhenIdleKey) private var barWhenIdle = true
    @State private var confirmClear = false
    @State private var tab: Tab?
    @AppStorage(AppModel.editorProviderKey) private var editorProvider = "anthropic"
    @State private var editorKey = ""
    @State private var editorNote = ""

    enum Tab: Hashable { case shortcuts, permissions, speech, privacy }

    var body: some View {
        PageColumn {
            PageTitle(title: "Settings") {
                HStack(spacing: 6) {
                    Circle().fill(model.shortcutIsLive ? Theme.live : Theme.warning).frame(width: 7, height: 7)
                    Text(model.shortcutIsLive ? "Listening for the shortcut" : "Not listening yet")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                }
            }
            TabStrip(tabs: [(.shortcuts, "Shortcuts"), (.permissions, "Permissions"), (.speech, "Speech"), (.privacy, "Privacy")],
                     selection: Binding(get: { current }, set: { tab = $0 })) { EmptyView() }
            if allowed < total || !model.fnKeyIsFree { attention }
            ScrollView {
                VStack(spacing: 18) {
                    switch current {
                    case .shortcuts: shortcuts
                    case .permissions: permissions
                    case .speech: speech
                    case .privacy: privacy
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
        }
        .confirmationDialog("Clear every kept dictation?", isPresented: $confirmClear) {
            Button("Clear history", role: .destructive) { model.history.clear() }
        }
    }

    /// Opens on Permissions until they're all allowed, then on Shortcuts.
    private var current: Tab { tab ?? (allowed < total ? .permissions : .shortcuts) }
    private var allowed: Int { model.permissions.applicablePermissions.filter(model.permissions.isAllowed).count }
    private var total: Int { model.permissions.applicablePermissions.count }

    // MARK: What still needs doing

    private var attention: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 4)
                Circle().trim(from: 0, to: total == 0 ? 1 : CGFloat(allowed) / CGFloat(total))
                    .stroke(Theme.live, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Theme.settle, value: allowed)
                Text("\(allowed)/\(total)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 4) {
                (allowed < total ? Text("Almost ") + Text("there").italic() + Text(".") : Text("One ") + Text("key").italic() + Text(" to free up."))
                    .font(.system(size: 22, weight: .regular, design: .serif)).foregroundStyle(.white)
                Text(allowed < total
                     ? "\(total - allowed) permission\(total - allowed == 1 ? "" : "s") left before Enkeon can hear the shortcut and type for you."
                     : "macOS also uses the 🌐 key; set “Press 🌐 key to” to Do Nothing so Fn only dictates.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.82))
            }
            Spacer(minLength: 0)
            if allowed < total {
                if current != .permissions {
                    Button("Show permissions") { withAnimation(Theme.settle) { tab = .permissions } }.buttonStyle(HeroButton())
                }
            } else {
                Button("Open Keyboard Settings") { model.openKeyboardSettings() }.buttonStyle(HeroButton())
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { Atmosphere() }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.opacity)
    }

    // MARK: Tabs

    private var shortcuts: some View {
        VStack(spacing: 18) {
            RowsBox(title: "While you work") {
                SettingRow(icon: "Microphone", title: "Dictate", detail: "Hold, speak, let go. Fn on Apple keyboards; ⌃⌘ on any keyboard.") { DictationKeys() }
                SettingRow(icon: "MemoryCards", title: "Ask Enkeon", detail: "Hold Option + Fn, ask, then release. An answer appears in a card; your question is never typed. No wake word needed.") { KeyCap(label: "⌥ Fn") }
                SettingRow(icon: "Waveform", title: "Hands-free", detail: "Keeps listening after you let go. Press Fn again to finish.") {
                    HStack(spacing: 4) { KeyCap(label: "fn"); KeyCap(label: "space") }
                }
                SettingRow(icon: "Brain", title: "Save to memory", detail: "Hold ⇧ too: it goes to your Enkeon memory, not into the field.") { KeyCap(label: "⇧") }
                SettingRow(icon: "Sparkle", title: "Edit by voice",
                           detail: "Hold Control, then Fn, and say the change. Edits your selection, or the whole message when nothing is selected. Without an Apple Fn key, use ⌥⌃⌘. \(rewriteStatus)") { KeyCap(label: "⌃ Fn") }
                SettingRow(icon: "Copy", title: "Copy last / Paste last",
                           detail: "⌃⌘C copies the last result. Focus the destination, then ⌃⌘V pastes it. Results stay available for this session even with history off.") { EmptyView() }
                SettingRow(icon: "X", title: "Cancel", detail: "Drops what was heard; nothing is typed.") { KeyCap(label: "esc") }
            }
            RowsBox(title: "While you type") {
                SettingRow(icon: "Sparkle", title: "Finish my sentences",
                           detail: "The rest of your sentence appears faded as you type, in your words; Tab takes it. Runs on this Mac. Not in passwords, terminals or code editors. \(completionStatus)") {
                    Toggle("", isOn: $finishSentences).toggleStyle(.switch).tint(Theme.accent).labelsHidden()
                }
                SettingRow(icon: "Brain", title: "Use my Enkeon memory",
                           detail: "Looks up relevant memories as your sentence develops. Matching sentences can appear as suggestions; Tab accepts, Esc dismisses. Remembered facts can still be outdated.") {
                    Toggle("", isOn: $completeWithMemory).toggleStyle(.switch).tint(Theme.accent).labelsHidden()
                        .disabled(!finishSentences || !model.account.isSignedIn)
                }
                SettingRow(icon: "NotePencil", title: "Learn my phrases",
                           detail: "Sentences you finish are kept on this Mac only. Start one you've written before and the rest comes back in your words. \(phraseStatus)") {
                    HStack(spacing: 10) {
                        if model.phrases.count > 0 {
                            Button("Forget") { confirmForget = true }.buttonStyle(SecondaryButton())
                        }
                        Toggle("", isOn: $learnPhrases).toggleStyle(.switch).tint(Theme.accent).labelsHidden()
                    }
                }
                SettingRow(icon: "TextAa", title: "Catch typos",
                           detail: "A misspelled word, or a slip in a sentence you just finished, shows corrected below the line; Tab fixes it. Names and words you use often are left alone.") {
                    Toggle("", isOn: $proofread).toggleStyle(.switch).tint(Theme.accent).labelsHidden()
                }

            }
            .confirmationDialog("Forget every phrase Enkeon learned from your typing?", isPresented: $confirmForget) {
                Button("Forget \(model.phrases.count) sentences", role: .destructive) { model.phrases.forgetAll(); model.objectWillChange.send() }
            }
            RowsBox(title: "Say it while dictating") {
                SettingRow(icon: "ArrowUUpLeft", title: "“scratch that”", detail: "Undoes the last dictation.") { EmptyView() }
                SettingRow(icon: "TextAa", title: "“new line”, “new paragraph”", detail: "Break the text where you say it.") { EmptyView() }
                SettingRow(icon: "ChatCircleText", title: "“literal …”", detail: "Types the words after it exactly as said.") { EmptyView() }
            }
        }
    }

    private var permissions: some View {
        RowsBox(title: "\(allowed) of \(total) allowed") {
            ForEach(model.permissions.applicablePermissions) { permission in
                PermissionRow(permission: permission)
                    .padding(.horizontal, 18).padding(.vertical, 12)
            }
        }
    }

    private var speech: some View {
        VStack(spacing: 18) {
            RowsBox(title: "Recognition") {
                SettingRow(icon: "Microphone", title: "Recognizer", detail: "On this Mac; your voice never leaves it.") {
                    Text(model.dictation.engineName).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                SettingRow(icon: "Waveform", title: "Speech model", detail: model.speechModelNote) {
                    if model.speechModelReady == false {
                        Button("Retry") { Task { await model.checkSpeechModel() } }.buttonStyle(SecondaryButton())
                    } else { status(model.speechModelReady == true) }
                }
                SettingRow(icon: "Sparkle", title: "Clean-up", detail: "Tidies punctuation and fillers; set per app in Styles.") {
                    Button("Styles") { model.page = .styles }.buttonStyle(SecondaryButton())
                }
            }
            RowsBox(title: "Voice editor") {
                SettingRow(icon: "Sparkle", title: "Editing model", detail: "Cloud edits send only the selected text or message and your instruction. Dictation and typing suggestions stay on this Mac. Automatic fallback is off.") {
                    Picker("Editor", selection: $editorProvider) {
                        Text("Claude Haiku 4.5 · cloud").tag("anthropic")
                        Text("Apple · on device").tag("apple")
                    }.labelsHidden().frame(width: 210)
                }
                if editorProvider == "anthropic" {
                    SettingRow(icon: "Key", title: model.editorConnected ? "API key saved" : "Connect Anthropic",
                               detail: editorNote.isEmpty ? "Saved in your Mac’s Keychain. API billing is separate; no shared key is bundled with Enkeon." : editorNote) {
                        VStack(alignment: .trailing, spacing: 8) {
                            SecureField("Anthropic API key", text: $editorKey).textFieldStyle(.roundedBorder).frame(width: 210)
                            HStack {
                                if model.editorConnected {
                                    Button("Remove") { model.removeEditorKey(); editorNote = "API key removed." }
                                }
                                Button("Save") {
                                    do { try model.saveEditorKey(editorKey); editorKey = ""; editorNote = "Saved. Cloud edits are ready to request; model access has not been tested." }
                                    catch { editorNote = "Could not save the key. Check Keychain access and try again." }
                                }.disabled(editorKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }
            }
            RowsBox(title: "Floating bar") {
                SettingRow(icon: "SidebarSimple", title: "Always show the bar", detail: "Click the bar to open Speak, Meeting and Memory. Turn off to use keyboard shortcuts without an idle bar.") {
                    Toggle("", isOn: $barWhenIdle).toggleStyle(.switch).tint(Theme.accent).labelsHidden()
                }
            }
        }
    }

    private var privacy: some View {
        RowsBox(title: "History") {
            SettingRow(icon: "Clock", title: "Keep a history", detail: "On this Mac only, never uploaded.") {
                Toggle("", isOn: $historyEnabled).toggleStyle(.switch).tint(Theme.accent).labelsHidden()
                    .onChange(of: historyEnabled) { _, on in if !on { model.history.clear() } }
            }
            SettingRow(icon: "Trash", title: "Clear history", detail: "\(model.history.records.count) dictations kept.") {
                Button("Clear…") { confirmClear = true }.buttonStyle(SecondaryButton()).disabled(model.history.records.isEmpty)
            }
        }
    }

    private var completionStatus: String {
        switch model.completer.status {
        case .off: return ""
        case .noModel: return "The writing model isn't installed yet."
        case .starting: return "Starting…"
        case .ready: return model.completer.shown == 0 ? "Ready." : "Ready · \(model.completer.accepted) of \(model.completer.shown) suggestions taken."
        case .failed(let why): return "Not running: \(why)"
        }
    }

    private var phraseStatus: String {
        model.phrases.count == 0 ? "" : "\(model.phrases.count) sentences so far."
    }

    private var rewriteStatus: String {
        if editorProvider == "anthropic" {
            return model.editorConnected ? "Uses Claude Haiku 4.5 in the cloud; no automatic fallback." : "Connect the cloud editor in Speech, or choose Apple there."
        }
        switch model.cleanupModel {
        case .some(let m) where m.available: return "Runs on Apple's on-device model; nothing leaves this Mac."
        case .some(let m): return "Needs Apple Intelligence (\(m.note))."
        case .none: return model.cleanupChecked ? "Needs the speech helper, which this build doesn't have." : ""
        }
    }

    private var speechModelDetail: String {
        switch model.speechModelReady {
        case .some(true): return "Installed for your language."
        case .some(false): return "macOS is installing it. Dictation uses the older recognizer until then."
        case .none: return "This build has no speech helper; the older on-device recognizer is used."
        }
    }

    private func status(_ ok: Bool) -> some View {
        PhosphorIcon(name: ok ? "CheckCircle" : "Clock", weight: ok ? .fill : .regular, size: 16)
            .foregroundStyle(ok ? Theme.accent : Theme.warning)
    }
}

/// A System Settings–style row: icon tile, title and explanation, the control on the right.
private struct SettingRow<Trailing: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            PhosphorIcon(name: icon, size: 15)
                .foregroundStyle(Theme.text)
                .frame(width: 28, height: 28)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(minHeight: 56)
    }
}

struct PermissionRow: View {
    @EnvironmentObject private var model: AppModel
    let permission: DictationPermission

    static func icon(_ permission: DictationPermission) -> String {
        switch permission {
        case .microphone: return "Microphone"
        case .speech: return "Waveform"
        case .accessibility: return "CursorClick"
        case .inputMonitoring: return "Keyboard"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            PhosphorIcon(name: Self.icon(permission), size: 16)
                .frame(width: 28, height: 28)
                .foregroundStyle(Theme.text)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Text(permission.explanation).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if model.permissions.isAllowed(permission) {
                HStack(spacing: 5) {
                    PhosphorIcon(name: "CheckCircle", weight: .fill, size: 14)
                    Text("Allowed").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.accent)
            } else if model.permissions.statuses[permission] == .restricted {
                Text("Blocked by this Mac's settings").font(.system(size: 12)).foregroundStyle(Theme.warning)
            } else {
                Button(model.permissions.wasRequested(permission) ? "Open Settings" : "Allow") {
                    Task { await model.permissions.request(permission) }
                }
                .buttonStyle(PrimaryButton())
                .disabled(model.permissions.isBusy)
            }
        }
    }
}
