import AppKit
import SwiftUI

struct CookieComposer: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var draft: CookieChatDraft
    let availableWidth: CGFloat

    var body: some View {
        CookieComposerControl(
            draft: draft, availableWidth: availableWidth,
            voiceState: companionManager.voiceState,
            isWorking: companionManager.isWorking,
            audioLevel: companionManager.currentAudioPowerLevel,
            startTalking: companionManager.startTalkingFromButton,
            finishTalking: companionManager.stopTalkingFromButton,
            stopResponse: companionManager.stopResponse,
            sendMessage: { companionManager.sendTypedMessage($0, attachments: $1, withScreen: $2) },
            recordMeeting: { CookieRecorder.shared.start() },
            dictating: companionManager.isDictating
        )
    }
}

enum CookieComposerPhase {
    case ready, listening, thinking, speaking

    init(voiceState: CompanionVoiceState, isWorking: Bool, holding: Bool) {
        if holding || voiceState == .listening { self = .listening }
        else if voiceState == .responding { self = .speaking }
        else if isWorking || voiceState == .processing { self = .thinking }
        else { self = .ready }
    }

    var canSubmit: Bool { self == .ready }
    var canStop: Bool { self == .thinking || self == .speaking }
    var title: String {
        switch self {
        case .ready: return "Hold to talk"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        }
    }
    var subtitle: String {
        switch self {
        case .ready: return "Ask, learn, or get something done"
        case .listening: return "Release to send"
        case .thinking: return "Making sense of it"
        case .speaking: return "Stop whenever you like"
        }
    }
}

/// One continuous surface: voice leads at rest, then makes room for the draft.
/// Callbacks keep this control renderable without starting audio or loading chats.
struct CookieComposerControl: View {
    @ObservedObject var draft: CookieChatDraft
    let availableWidth: CGFloat
    let voiceState: CompanionVoiceState
    let isWorking: Bool
    let audioLevel: CGFloat
    let startTalking: () -> Void
    let finishTalking: () -> Void
    let stopResponse: () -> Void
    let sendMessage: (String, [CookieAttachment], Bool) -> Void
    /// Start recording a meeting (nil hides the button).
    var recordMeeting: (() -> Void)? = nil
    var dictating = false

    @FocusState private var focused: Bool
    @State private var holding = false

    private var phase: CookieComposerPhase {
        CookieComposerPhase(voiceState: voiceState, isWorking: isWorking, holding: holding)
    }
    private var hasDraft: Bool {
        !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty
    }
    private var stacked: Bool { availableWidth < 460 }
    private var expanded: Bool { focused || hasDraft || availableWidth < 460 }
    private var voiceWidth: CGFloat { expanded ? 48 : max(48, (availableWidth - 28) * 0.6) }
    private var shell: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }

    var body: some View {
        VStack(spacing: 9) {
            VStack(spacing: 8) {
                if !draft.attachments.isEmpty { attachments }
                if stacked {
                    messageField.padding(.horizontal, 8).frame(minHeight: 46, alignment: .topLeading)
                    HStack(spacing: 4) {
                        CookieVoiceControl(phase: phase, compact: true, holding: holding, audioLevel: audioLevel,
                                           beginHolding: beginHolding, endHolding: endHolding, dictating: dictating)
                            .frame(width: 44, height: 44)
                        Spacer(minLength: 8)
                        composerActions
                    }
                } else {
                HStack(alignment: .bottom, spacing: 8) {
                    CookieVoiceControl(phase: phase, compact: expanded, holding: holding, audioLevel: audioLevel,
                                       beginHolding: beginHolding, endHolding: endHolding, dictating: dictating)
                        .frame(width: voiceWidth, height: 48)
                    typingField
                }
                }
            }
            .padding(8)
            .background(shell.fill(LinearGradient(
                colors: [Color.white.opacity(0.075), Color.white.opacity(0.035)],
                startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(shell.strokeBorder(
                focused || phase == .listening ? CK.accent.opacity(0.38) : Color.white.opacity(0.10),
                lineWidth: 0.75))
            .clipShape(shell)

            footer
                .padding(.horizontal, 5)
        }
        .animation(CK.spring, value: expanded)
        .animation(CK.quick, value: phase)
        .animation(CK.quick, value: focused)
        .animation(CK.spring, value: draft.attachments.count)
        .cookieMotionPreferences()
        .onDisappear(perform: endHolding)
    }

    private var typingField: some View {
        HStack(alignment: .bottom, spacing: 3) {
            messageField
            composerActions

        }
        .padding(7)
        .frame(minHeight: 48)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(Color.black.opacity(focused ? 0.19 : 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
            .strokeBorder(Color.white.opacity(focused ? 0.07 : 0.035), lineWidth: 0.5))
    }

    private var messageField: some View {
            TextField(expanded ? "Message Cookie…" : "Or type…", text: $draft.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(CK.text)
                .tint(CK.accent)
                .lineLimit(1...5)
                .focused($focused)
                .padding(.vertical, 8)
                .padding(.leading, 7)
                .accessibilityLabel("Message Cookie")
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                        // Insert at the caret through AppKit so selection and undo survive.
                        return NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                                                to: nil, from: nil) ? .handled : .ignored
                    }
                    send()
                    return .handled
                }
                .onKeyPress(.escape) {
                    focused = false
                    return .handled
                }

    }

    @ViewBuilder private var composerActions: some View {
            if let recordMeeting {
                ComposerIconButton(symbol: "record.circle", label: "Record a meeting (no bot joins the call)", action: recordMeeting)
            }
            ComposerIconButton(symbol: "display", label: draft.withScreen ? "Your screen goes with this message" : "Share your screen with this message",
                               selected: draft.withScreen) { draft.withScreen.toggle() }
            ComposerIconButton(symbol: "plus", label: "Attach files", action: chooseFiles)

            if phase.canStop {
                ComposerIconButton(symbol: "stop.fill", label: "Stop response", prominent: true, action: stopResponse)
                    .transition(.opacity)
            } else if expanded {
                ComposerIconButton(symbol: "arrow.up", label: "Send message", prominent: true,
                                   enabled: hasDraft && phase.canSubmit, action: send)
                    .transition(.opacity)
            }
    }

    private var attachments: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(draft.attachments) { attachment in
                    HStack(spacing: 6) {
                        FileThumbnail(attachment: attachment, size: 22)
                        Text(attachment.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CK.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 150)
                        ComposerIconButton(symbol: "xmark", label: "Remove \(attachment.name)", size: 24) {
                            draft.attachments.removeAll { $0 == attachment }
                        }
                    }
                    .padding(.leading, 5)
                    .padding(.trailing, 3)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(CK.fill))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CK.hairline, lineWidth: 0.5))
                }
            }
        }
        .scrollIndicators(.never)
        .padding(2)
        .transition(.opacity)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            if phase == .listening {
                Circle().fill(CK.accent).frame(width: 4, height: 4)
                Text(dictating ? "Release to insert" : "Release to send")
            } else if phase.canStop {
                Text("\(phase.title) · you can keep typing")
            } else if expanded {
                Image(systemName: "return").font(.system(size: 9, weight: .medium))
                Text("Send")
                Text("·").padding(.horizontal, 2)
                Text("⇧↵ New line")
            } else {
                Image(systemName: "cursorarrow.and.square.on.square.dashed")
                    .font(.system(size: 9, weight: .medium))
                Text("Hold keys + drag to circle")
            }
            Spacer(minLength: 8)
            if availableWidth >= 380 {
                Text("Talk anywhere")
            }
            Text("⌃ ⌥")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(CK.fill))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(CK.hairline, lineWidth: 0.5))
                .accessibilityLabel("Hold Control and Option to talk from anywhere")
        }
        .font(.system(size: 10))
        .foregroundStyle(CK.secondary)
        .lineLimit(1)
        .frame(height: 17)
        .contentTransition(.opacity)
    }

    private func beginHolding() {
        guard phase == .ready, !holding else { return }
        holding = true
        focused = false
        startTalking()
    }

    private func endHolding() {
        guard holding else { return }
        holding = false
        finishTalking()
    }

    private func send() {
        guard hasDraft, phase.canSubmit else { return }
        sendMessage(draft.text, draft.attachments, draft.withScreen)
        draft.clear()
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        // Above the island (mainMenu + 3), or the picker opens underneath it.
        panel.level = CookieWindowLevel.notchPanel
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            for url in panel.urls { draft.attach(CookieAttachment(path: url.path)) }
            focused = true
        }
    }
}

private struct CookieVoiceControl: View {
    let phase: CookieComposerPhase
    let compact: Bool
    let holding: Bool
    let audioLevel: CGFloat
    let beginHolding: () -> Void
    let endHolding: () -> Void
    var dictating = false
    @State private var hovering = false
    @FocusState private var keyboardFocused: Bool

    private var interactive: Bool { phase == .ready || holding }

    var body: some View {
        HStack(spacing: 10) {
            CookieVoiceMedallion(phase: phase, audioLevel: audioLevel)
                .scaleEffect(holding ? 0.94 : 1)
                .animation(CK.quick, value: holding)
            if !compact {
                VStack(alignment: .leading, spacing: 3) {
                    Text(dictating && phase == .listening ? "Dictating" : phase.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CK.text)
                    Text(dictating && phase == .listening ? "Release to insert" : phase.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(CK.secondary)
                }
                .lineLimit(1)
                .transition(.opacity)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .center : .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(hovering && interactive ? 0.035 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in beginHolding() }
            .onEnded { _ in endHolding() })
        .onHover { hovering = $0 }
        .onContinuousHover { event in
            switch event {
            case .active: (interactive ? NSCursor.pointingHand : NSCursor.arrow).set()
            case .ended: NSCursor.arrow.set()
            }
        }
        .focusable(interactive)
        .focused($keyboardFocused)
        .onChange(of: keyboardFocused) { _, focused in
            if !focused { endHolding() }
        }
        .onKeyPress(.space, phases: [.down, .up]) { press in
            if press.phase == .down { beginHolding() } else { endHolding() }
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase.title)
        .accessibilityValue(phase.subtitle)
        .accessibilityHint(interactive
            ? (holding ? "Activate again to finish and send." : "Press and hold, or activate to start listening.")
            : "Use Stop response to end the reply.")
        .accessibilityAddTraits(interactive ? .isButton : [])
        .accessibilityAction {
            if holding { endHolding() } else { beginHolding() }
        }
        .help(phase == .ready ? "Hold to talk · Control Option from anywhere" : phase.subtitle)
        .animation(CK.quick, value: hovering)
    }
}

/// The same voice indicator in the compact notch and the expanded composer.
struct CookieVoiceMedallion: View {
    let phase: CookieComposerPhase
    let audioLevel: CGFloat
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(
                colors: phase == .thinking
                    ? [Color.white.opacity(0.12), Color.white.opacity(0.055)]
                    : [CK.accent, CK.accent.opacity(0.68)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().strokeBorder(LinearGradient(
                colors: [Color.white.opacity(0.32), Color.white.opacity(0.02)],
                startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            Group {
                switch phase {
                case .ready:
                    Image(systemName: "mic.fill").font(.system(size: 17, weight: .medium))
                case .listening:
                    ComposerVoiceBars(level: audioLevel)
                case .thinking:
                    ThinkingDots().scaleEffect(0.60)
                case .speaking:
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 14, weight: .medium))
                        .symbolEffect(.variableColor.iterative)
                }
            }
            .foregroundStyle(phase == .thinking ? CK.secondary : .white)
        }
        .frame(width: 40, height: 40)
        .scaleEffect(size / 40)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .cookieMotionPreferences()
    }
}

private struct ComposerVoiceBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let level: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<5) { index in
                    let wave = (sin(time * 8 + Double(index) * 0.9) + 1) / 2
                    Capsule().fill(.white.opacity(0.95))
                        .frame(width: 2.5, height: 4 + 15 * max(0.2, min(1, level)) * CGFloat(wave))
                }
            }
            .frame(height: 22)
        }
    }
}

private struct ComposerIconButton: View {
    let symbol: String
    let label: String
    var prominent = false
    var enabled = true
    var selected = false
    var size: CGFloat = 32
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "stop.fill" ? 10 : 12, weight: .semibold))
                .foregroundStyle(prominent && enabled ? .white : selected ? CK.accent : (enabled ? CK.secondary : CK.tertiary))
                .frame(width: size, height: size)
                .background(Circle().fill(prominent && enabled ? CK.accent
                                          : selected ? CK.accent.opacity(0.16) : Color.white.opacity(hovering ? 0.08 : 0)))
                .overlay(Circle().strokeBorder(Color.white.opacity(prominent && enabled ? 0.16 : 0), lineWidth: 0.5))
                .brightness(hovering && enabled && prominent ? 0.06 : 0)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
        .cookiePointingCursor()
        .animation(CK.quick, value: hovering)
        .animation(CK.quick, value: enabled)
    }
}
