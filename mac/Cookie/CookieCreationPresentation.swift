import SwiftUI

/// Pure presentation: previews never open a microphone, speak, or create a saved Cookie.
struct CookieCreationSurface<Details: View, Actions: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let identity: UUID
    let agent: CookieAgent?
    let isProfile: Bool
    let phase: CookieComposerPhase
    let preparingSpeech: Bool
    let audioLevel: CGFloat
    let line: String
    let speechProgress: Double
    let lastAnswer: String
    let problem: String?
    @Binding var typed: String
    let back: () -> Void
    let submit: () -> Void
    let beginHolding: () -> Void
    let endHolding: () -> Void
    let stop: () -> Void
    let replay: () -> Void
    @ViewBuilder let details: () -> Details
    @ViewBuilder let actions: () -> Actions
    @FocusState private var typing: Bool
    @State private var hoveringCharacter = false
    @State private var holding = false

    private var busy: Bool { phase != .ready || preparingSpeech }
    private var mood: ClayCookie.Mood {
        switch phase {
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .ready: return .idle
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 480
            let inset: CGFloat = compact ? 20 : 32
            VStack(spacing: 0) {
                header(compact: compact)
                    .padding(.horizontal, inset).padding(.top, 8).padding(.bottom, 8)
                ScrollView {
                    VStack(spacing: 20) {
                        character(size: geometry.size.height < 500 || agent != nil ? 92 : 124)
                            .padding(.top, geometry.size.height < 500 ? 0 : 12)
                        VStack(spacing: 12) {
                            Text(isProfile ? "YOUR COOKIE" : agent == nil ? "A COOKIE OF YOUR OWN" : "A LITTLE HELP, MADE YOURS")
                                .font(.system(size: 9, weight: .semibold)).tracking(2)
                                .foregroundStyle(CK.secondary)
                            if let agent {
                                Text(isProfile ? agent.name : "Meet \(agent.name).")
                                    .font(.system(size: compact ? 27 : 30, weight: .semibold)).tracking(-0.8)
                                    .foregroundStyle(CK.text)
                            }
                            if !isProfile {
                                spokenLine(size: agent == nil ? (compact ? 23 : 27) : 15)
                                    .frame(maxWidth: agent == nil ? 440 : 460)
                            }
                        }
                        .multilineTextAlignment(.center)
                        if agent != nil {
                            details()
                        } else if lastAnswer.isEmpty {
                            Text("Give it a purpose. We’ll find its personality.")
                                .font(.system(size: 12)).foregroundStyle(CK.secondary)
                                .multilineTextAlignment(.center)
                            suggestions
                        } else {
                            VStack(spacing: 6) {
                                Text("YOUR IDEA").font(.system(size: 9, weight: .semibold)).tracking(1.4)
                                    .foregroundStyle(CK.tertiary)
                                Text(lastAnswer).font(.system(size: 13)).foregroundStyle(CK.secondary)
                                    .lineLimit(3).multilineTextAlignment(.center).textSelection(.enabled)
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .frame(maxWidth: 520).frame(maxWidth: .infinity)
                    .padding(.horizontal, inset).padding(.bottom, 24)
                    .frame(minHeight: max(0, geometry.size.height - (agent == nil ? 178 : 98)), alignment: .center)
                }
                .scrollIndicators(.hidden)
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(Color.orange.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12).frame(maxWidth: 520, alignment: .leading)
                        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, inset).padding(.bottom, 10)
                }
                if agent == nil { composer.padding(.horizontal, inset).padding(.bottom, 18) }
                else {
                    VStack(spacing: 10) {
                        actions().frame(maxWidth: 520, alignment: .leading)
                        if !isProfile { voiceStatus }
                    }
                    .padding(.horizontal, inset).padding(.top, 8).padding(.bottom, 18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(CK.text)
        .onChange(of: phase) { _, next in
            if next == .listening { typing = false }
            if next == .ready { holding = false }
        }
        .cookieMotionPreferences()
    }

    private func header(compact: Bool) -> some View {
        HStack {
            Button(action: back) { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(WorkButtonStyle(quiet: true))
            Spacer()
            if isProfile {
                Text("Cookie profile").font(.system(size: 11)).foregroundStyle(CK.secondary)
            } else {
                HStack(spacing: compact ? 8 : 12) {
                    step("1", title: "Imagine", selected: agent == nil)
                    Rectangle().fill(CK.hairline).frame(width: compact ? 16 : 26, height: 1)
                    step("2", title: "Meet", selected: agent != nil)
                }
            }
        }
        .frame(height: 32)
    }

    private func step(_ number: String, title: String, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(number).font(.system(size: 9, weight: .semibold, design: .rounded))
                .frame(width: 18, height: 18)
                .background(selected ? CK.accent.opacity(0.16) : CK.fill, in: Circle())
            Text(title).font(.system(size: 11, weight: selected ? .medium : .regular))
        }
        .foregroundStyle(selected ? CK.text : CK.tertiary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func character(size: CGFloat) -> some View {
        ZStack {
            Ellipse()
                .fill(RadialGradient(colors: [CK.accent.opacity(phase == .listening ? 0.16 : 0.04), .clear],
                                     center: .center, startRadius: 0, endRadius: size))
                .frame(width: size * 2, height: size * 1.3)
                .offset(y: size * 0.25)
            Ellipse().fill(.black.opacity(0.18)).frame(width: size * 0.65, height: 8)
                .blur(radius: 6).offset(y: size * 0.52)
            CookieAvatar(size: size, agent: agent ?? CookieAgent(id: identity, name: "", role: "", detail: "", kind: .general),
                         mood: mood, animatesIdle: true, isEngaged: hoveringCharacter || phase == .listening)
                .onHover { hoveringCharacter = $0 }
        }
        .frame(height: size + 8)
        .animation(reduceMotion ? nil : CK.quick, value: phase)
        .animation(reduceMotion ? nil : CK.spring, value: agent?.id)
        .accessibilityHidden(true)
    }

    private func spokenLine(size: CGFloat) -> some View {
        let parts = CookieSpokenText.parts(line, progress: reduceMotion ? 1 : speechProgress)
        // Both segments occupy their final space. Words brighten without moving the sentence.
        return (Text(parts.spoken).foregroundColor(CK.text) + Text(parts.upcoming).foregroundColor(.white.opacity(0.23)))
            .font(.system(size: size, weight: agent == nil ? .medium : .regular))
            .tracking(agent == nil ? -0.5 : 0)
            .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Cookie says: \(line)")
            .textSelection(.enabled)
    }

    private var suggestions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { suggestionButtons }
            VStack(spacing: 8) { suggestionButtons }
        }
        .padding(.top, 2)
    }

    @ViewBuilder private var suggestionButtons: some View {
        suggestion("Research", symbol: "sparkle.magnifyingglass", text: "Help me research competitors and spot what matters.")
        suggestion("Follow-ups", symbol: "paperplane", text: "Help me keep track of people I need to follow up with.")
        suggestion("Writing", symbol: "pencil.line", text: "Help me turn rough ideas into clear, thoughtful writing.")
    }

    private func suggestion(_ title: String, symbol: String, text: String) -> some View {
        Button {
            typed = text
            typing = true
        } label: {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .buttonStyle(CookieCreationButtonStyle())
        .disabled(phase == .thinking || phase == .listening)
        .help("Use this idea, then make it yours")
    }

    private var composer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Tell Cookie what you have in mind…", text: $typed)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .focused($typing).onSubmit(submit)
                    .disabled(phase == .thinking || phase == .listening)
                    .accessibilityLabel("Your idea for this Cookie")
                Button(action: submit) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(canSend ? CK.accent : CK.fill, in: Circle())
                }
                .buttonStyle(CookieCreationButtonStyle(round: true))
                .disabled(!canSend).help("Send your idea").accessibilityLabel("Send your idea")
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
            Rectangle().fill(CK.hairline).frame(height: 0.5).padding(.horizontal, 16)
            voiceStatus.padding(.horizontal, 12).padding(.vertical, 9)
        }
        .frame(maxWidth: 520)
        .background(LinearGradient(colors: [.white.opacity(0.06), .white.opacity(0.035)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(typing ? CK.accent.opacity(0.4) : CK.hairline, lineWidth: 0.75))
        .frame(maxWidth: .infinity)
    }

    private var canSend: Bool {
        !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phase != .thinking && phase != .listening
    }

    private var voiceStatus: some View {
        HStack(spacing: 10) {
            // This hit target stays mounted through listening, so mouse-up is never lost
            // when the visual state changes during a press-and-hold.
            HStack(spacing: 9) {
                CookieVoiceMedallion(phase: preparingSpeech ? .thinking : phase, audioLevel: audioLevel, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preparingSpeech ? "Getting ready to speak" : phase == .thinking ? "Finding the right fit" : phase.title)
                        .font(.system(size: 11, weight: .medium))
                    if busy {
                        Text(phase == .listening ? "Release to send" : phase == .speaking ? "Follow along above" : "Just a moment…")
                            .font(.system(size: 10)).foregroundStyle(CK.secondary)
                    }
                }
            }
            .padding(.vertical, 3).padding(.trailing, 8)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !holding, phase != .thinking else { return }
                    holding = true
                    typing = false
                    beginHolding()
                }
                .onEnded { _ in holding = false; endHolding() })
            .cookiePointingCursor()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(busy ? phase.title : "Hold to talk")
            .accessibilityHint("Hold Control and Option, or activate to start and stop recording.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if phase == .listening { holding = false; endHolding() }
                else if phase != .thinking { holding = true; beginHolding() }
            }
            Spacer(minLength: 4)
            if busy {
                Button(action: stop) { Label("Stop", systemImage: "stop.fill").font(.system(size: 11, weight: .medium)).padding(8) }
                    .buttonStyle(CookieCreationButtonStyle()).help("Stop · Escape")
            } else if agent == nil {
                TalkKeys().help("Hold Control + Option anywhere to talk")
            } else {
                Button(action: replay) { Label("Hear again", systemImage: "speaker.wave.2").font(.system(size: 11)).padding(8) }
                    .buttonStyle(CookieCreationButtonStyle())
            }
        }
        .frame(maxWidth: 520, minHeight: 34)
        .frame(maxWidth: .infinity)
    }

}

struct CookieCreationButtonStyle: ButtonStyle {
    var round = false
    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, round: round)
    }

    private struct Content: View {
        let configuration: Configuration
        let round: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(CK.text)
                .background(Color.white.opacity(hovering ? 0.09 : round ? 0 : 0.035), in: Capsule())
                .opacity(!isEnabled ? 0.35 : configuration.isPressed ? 0.65 : 1)
                .onHover { hovering = $0 }.cookiePointingCursor()
        }
    }
}
