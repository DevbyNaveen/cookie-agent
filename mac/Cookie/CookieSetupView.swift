import SwiftUI

struct CookieSetupView: View {
    @ObservedObject var progress: CookieSetupProgress
    @ObservedObject var permissions: CookiePermissionCenter
    let needsModel: Bool
    let finish: (Bool) -> Void
    let dismiss: () -> Void

    var body: some View {
        CookieSetupContent(step: progress.step, permissions: permissions, needsModel: needsModel,
                           back: progress.back, next: {
            if progress.step == .ready { finish(needsModel) } else { progress.advance() }
        }, dismiss: dismiss)
    }
}

/// Shares the actual setup layout with native previews without requesting access.
struct CookieSetupContent: View {
    let step: CookieSetupStep
    @ObservedObject var permissions: CookiePermissionCenter
    var needsModel = false
    let back: () -> Void
    let next: () -> Void
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if step == .welcome { welcome } else {
                        introduction
                        stepContent
                    }
                }
                .frame(maxWidth: 540, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.vertical, 26)
                .id(step)
                .transition(.opacity)
            }
            .scrollIndicators(.automatic)
            footer
        }
        .background(CK.island)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(CK.hairline, lineWidth: 0.5))
        .foregroundStyle(CK.text)
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : CK.quick, value: step)
        .cookieMotionPreferences()
    }

    private var header: some View {
        VStack(spacing: 22) {
            HStack(spacing: 9) {
                CookieAvatar(size: 25)
                Text("Cookie").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("MAKE YOURSELF AT HOME").font(.system(size: 9, weight: .semibold)).tracking(1.7)
                    .foregroundStyle(CK.tertiary)
                IslandButton(symbol: "xmark", help: "Close setup. Your progress is saved.", action: dismiss)
                    .accessibilityLabel("Close setup")
                    .padding(.leading, 12)
            }
            HStack(spacing: 7) {
                ForEach(CookieSetupStep.allCases) { item in
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().fill(item.rawValue <= step.rawValue ? CK.accent : CK.fillHover).frame(height: 3)
                        Text(item.label).font(.system(size: 10, weight: item == step ? .semibold : .regular))
                            .foregroundStyle(item == step ? CK.text : CK.tertiary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.label), step \(item.rawValue + 1) of 5\(item == step ? ", current step" : "")")
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 6)
    }

    private var welcome: some View {
        VStack(spacing: 23) {
            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(LinearGradient(colors: [CK.fillHover, CK.fill.opacity(0.2)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 210, height: 124)
                VStack(spacing: 10) {
                    Capsule().fill(.black).frame(width: 78, height: 8)
                    CookieAvatar(size: 70)
                }
            }
            .accessibilityHidden(true)
            VStack(spacing: 12) {
                Text("A little help.\nRight where you work.")
                    .font(.system(size: 32, weight: .semibold)).tracking(-1)
                    .multilineTextAlignment(.center)
                Text("Talk, ask about your screen, or type a thought.\nCookie lives at the top of your Mac.")
                    .font(.system(size: 13)).foregroundStyle(CK.secondary)
                    .multilineTextAlignment(.center).lineSpacing(4)
            }
            HStack(spacing: 0) {
                welcomeFeature("mic", title: "Speak naturally")
                welcomeFeature("rectangle.inset.filled", title: "Bring context")
                welcomeFeature("hand.raised", title: "Choose access")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    private func welcomeFeature(_ symbol: String, title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(CK.secondary)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(CK.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        switch step {
        case .welcome: return "Welcome to Cookie"
        case .voice: return "Your voice, when you choose."
        case .screen: return "Less explaining. More context."
        case .shortcuts: return "One small shortcut."
        case .ready: return "Make room for your next idea."
        }
    }

    private var subtitle: String {
        switch step {
        case .welcome: return ""
        case .voice: return "Hold to talk. Release to send. You can always type instead."
        case .screen: return "Let Cookie see what you’re asking about. Screen access is optional."
        case .shortcuts: return "Reach Cookie from any app, without breaking your flow."
        case .ready: return "Your choices are saved. You can change them anytime in Settings."
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: step == .voice ? "waveform" : step == .screen ? "rectangle.inset.filled" : step == .shortcuts ? "command" : "checkmark")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(CK.accent)
                .frame(width: 54, height: 54)
                .background(RoundedRectangle(cornerRadius: 17).fill(CK.accent.opacity(0.12)))
                .padding(.bottom, 3)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 27, weight: .semibold)).tracking(-0.8)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(CK.secondary)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .welcome: EmptyView()
        case .voice:
            permissionGroup(permissions.voicePermissions)
            note("mic.slash", "The microphone is used while you talk. Granting access doesn’t start a recording.")
        case .screen:
            permissionGroup([.screen])
            if permissions.isAllowed(.screen) {
                HStack(spacing: 12) {
                    Image(systemName: permissions.screenVerified ? "checkmark.circle.fill" : "viewfinder")
                        .foregroundStyle(permissions.screenVerified ? .green : CK.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(permissions.screenVerified ? "Screen access checked" : "Try a local screen check")
                            .font(.system(size: 12, weight: .semibold))
                        Text("One small capture, discarded on this Mac. Never sent.")
                            .font(.system(size: 11)).foregroundStyle(CK.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    if permissions.isCheckingScreen { ProgressView().controlSize(.small) }
                    else if !permissions.screenVerified {
                        PillButton(title: "Check access") { Task { await permissions.checkScreenAccess() } }
                            .disabled(permissions.isBusy)
                    }
                }
                .padding(16).cookieCard()
            }
            if let message = permissions.screenCheckMessage {
                note("info.circle", message)
                PillButton(title: "Screen settings", symbol: "arrow.up.forward") { permissions.openSettings(for: .screen) }
            }
            note("lock", "When you ask about your screen, its context is shared with your chosen AI model. Screenshots aren’t saved to your chats.")
            if permissions.wasRequested(.screen) && !permissions.isAllowed(.screen) {
                note("arrow.clockwise", "Turn Cookie on in System Settings. If macOS asks you to quit and reopen, setup will pick up here.")
            }
        case .shortcuts:
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    shortcutKey("⌃", name: "Control")
                    shortcutKey("⌥", name: "Option")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Hold both to talk").font(.system(size: 13, weight: .semibold))
                    Text("Drag while holding to circle something.").font(.system(size: 11)).foregroundStyle(CK.secondary)
                }
                Spacer(minLength: 0)
            }
            permissionGroup(permissions.shortcutPermissions)
            note("cursorarrow", "Prefer clicking? The talk button and typing work without a global shortcut.")
        case .ready:
            VStack(spacing: 0) {
                readinessRow("mic", title: "Talk to Cookie", ready: permissions.voiceReady)
                Divider().overlay(CK.hairline).padding(.leading, 45)
                readinessRow("rectangle.inset.filled", title: "Screen context", ready: permissions.isAllowed(.screen))
                Divider().overlay(CK.hairline).padding(.leading, 45)
                readinessRow("keyboard", title: "Talk from any app", ready: permissions.shortcutsReady && permissions.voiceReady)
            }
            .padding(.horizontal, 16).cookieCard()
            note("arrow.up", "Click Cookie in the menu bar to open the notch. Right-click for Settings and Help.")
            if needsModel {
                note("sparkles", "One more thing before your first answer: connect an AI model. We’ll open that setting next.")
            }
        }
    }

    private func permissionGroup(_ items: [CookiePermission]) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { permission in
                CookiePermissionRow(permission: permission, permissions: permissions)
                if permission != items.last { Rectangle().fill(CK.hairline).frame(height: 0.5).padding(.leading, 53) }
            }
        }
        .cookieCard()
    }

    private func shortcutKey(_ symbol: String, name: String) -> some View {
        VStack(spacing: 4) {
            Text(symbol).font(.system(size: 24, weight: .medium))
            Text(name).font(.system(size: 9)).foregroundStyle(CK.secondary)
        }
        .frame(width: 62, height: 62).cookieCard()
        .accessibilityLabel(name)
    }

    private func readinessRow(_ symbol: String, title: String, ready: Bool) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).foregroundStyle(CK.secondary).frame(width: 20)
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
            Label(ready ? "Enabled" : "Set up later", systemImage: ready ? "checkmark.circle.fill" : "minus.circle")
                .font(.system(size: 11)).foregroundStyle(ready ? Color.green : CK.secondary)
        }
        .padding(.vertical, 15)
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).frame(width: 15).padding(.top, 1)
            Text(text).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
        }
        .font(.system(size: 11)).foregroundStyle(CK.secondary)
    }

    private var stepIsReady: Bool {
        switch step {
        case .voice: return permissions.voiceReady
        case .screen: return permissions.isAllowed(.screen)
        case .shortcuts: return permissions.shortcutsReady
        default: return true
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(CK.hairline).frame(height: 0.5)
            HStack(spacing: 16) {
                if step != .welcome {
                    Button(action: back) { Label("Back", systemImage: "chevron.left").font(.system(size: 12, weight: .medium)) }
                        .buttonStyle(.plain).foregroundStyle(CK.secondary).cookiePointingCursor()
                        .disabled(permissions.isBusy)
                } else {
                    Text("A few choices. Always yours.").font(.system(size: 11)).foregroundStyle(CK.tertiary)
                }
                Spacer()
                Button(action: next) {
                    HStack(spacing: 9) {
                        Text(step == .welcome ? "Get started" : step == .ready ? (needsModel ? "Choose AI model" : "Open Cookie") : stepIsReady ? "Continue" : "Set up later")
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 19).frame(height: 38)
                    .contentShape(Capsule())
                }
                .buttonStyle(CookieSetupButtonStyle(primary: stepIsReady))
                .keyboardShortcut(.defaultAction)
                .cookiePointingCursor()
                .disabled(permissions.isBusy)
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
        }
    }
}

struct CookiePermissionRow: View {
    let permission: CookiePermission
    @ObservedObject var permissions: CookiePermissionCenter

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: permission.symbol).font(.system(size: 16)).foregroundStyle(CK.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(permission.title).font(.system(size: 12, weight: .semibold))
                Text(permissions.statuses[permission] == .restricted ? "Managed by your Mac. Contact your administrator." : permission.explanation)
                    .font(.system(size: 11)).foregroundStyle(CK.secondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
            }
            Spacer(minLength: 8)
            if permissions.isAllowed(permission) {
                Label("Allowed", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
            } else if permissions.requesting == permission {
                ProgressView().controlSize(.small).accessibilityLabel("Requesting \(permission.title) access")
            } else if permissions.statuses[permission] != .restricted {
                PillButton(title: permissions.statuses[permission] == .denied || permissions.wasRequested(permission) ? "Open Settings" : "Allow", primary: true) {
                    Task { await permissions.request(permission) }
                }
                .accessibilityLabel("\(permissions.wasRequested(permission) ? "Open Settings for" : "Allow") \(permission.title)")
                .disabled(permissions.isBusy)
            }
        }
        .padding(16)
    }
}

private struct CookieSetupButtonStyle: ButtonStyle {
    var primary: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(primary ? Color.white : CK.text)
            .background(Capsule().fill(primary ? CK.accent.opacity(hovering ? 1 : 0.9) : (hovering ? CK.selected : CK.fillHover)))
            .overlay(Capsule().strokeBorder(CK.hairline))
            .opacity(!enabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
            .onHover { hovering = $0 }
    }
}
