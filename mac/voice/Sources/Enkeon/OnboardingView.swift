import EnkeonVoiceKit
import SwiftUI

/// First launch, one step at a time: access, the 🌐 key (only if macOS has it doing something else),
/// the speech model, then one real dictation. The header is Enkeon's atmosphere with the fluid orb,
/// which listens along when you try it.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var index = 0
    @State private var forward = true
    @FocusState private var practiceFocused: Bool

    enum Step: Hashable { case access, key, model, tryIt }

    private var steps: [Step] { model.fnKeyIsFree ? [.access, .model, .tryIt] : [.access, .key, .model, .tryIt] }
    private var step: Step { steps[min(index, steps.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                content
                    .id(step)
                    .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 30)
            .padding(.top, 22)
            .clipped()
            footer
        }
        .frame(width: 640, height: 580)
        .background(Theme.background)
        .animation(Theme.settle, value: index)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(steps.indices, id: \.self) { i in
                        Capsule().fill(.white.opacity(i <= index ? 0.9 : 0.25)).frame(width: i == index ? 22 : 8, height: 4)
                    }
                }
                .animation(Theme.settle, value: index)
                headline
                    .font(.system(size: 28, weight: .regular, design: .serif))
                    .tracking(-0.5)
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)
                Text(message).font(.system(size: 13)).foregroundStyle(.white.opacity(0.82)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            FluidOrb(energy: listening ? model.dictation.level : 0, palette: listening ? .listening : .brand)
                .frame(width: 84, height: 84)
                .scaleEffect(listening ? 1 + min(0.1, model.dictation.level * 0.14) : 1)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                .animation(.easeOut(duration: 0.12), value: model.dictation.level)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { Atmosphere() }
    }

    private var listening: Bool { if case .listening = model.dictation.phase { return true }; return false }

    private var headline: Text {
        switch step {
        case .access: return Text("Let Enkeon ") + Text("hear").italic() + Text(" you.")
        case .key: return Text("One key, ") + Text("your").italic() + Text(" voice.")
        case .model: return Text("Speech, ") + Text("on this Mac").italic() + Text(".")
        case .tryIt: return Text("Now say ") + Text("anything").italic() + Text(".")
        }
    }

    private var message: String {
        switch step {
        case .access: return "Four permissions, asked once. Your voice is turned into text on this Mac and never leaves it."
        case .key: return "macOS also uses the 🌐 key. Free it, and holding fn anywhere starts dictation."
        case .model: return "Apple's speech model, for your language, runs on this Mac."
        case .tryIt: return "Click the box, hold the keys and talk. Let go, and your words appear."
        }
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .access: access
        case .key: key
        case .model: speechModel
        case .tryIt: tryIt
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 2) {
                ForEach(model.permissions.applicablePermissions) { permission in
                    PermissionRow(permission: permission)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(permission == nextPermission ? Theme.accent.opacity(0.1) : .clear))
                }
            }
            .padding(6)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .animation(Theme.settle, value: nextPermission)
            Text("If the keys don't respond after allowing Input Monitoring, quit and reopen Enkeon.")
                .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
        }
    }

    private var nextPermission: DictationPermission? { model.permissions.applicablePermissions.first { !model.permissions.isAllowed($0) } }

    private var key: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                (Text("System Settings → Keyboard → ") + Text("Press 🌐 key to").fontWeight(.semibold) + Text(" → ") + Text("Do Nothing").fontWeight(.semibold))
                    .font(.system(size: 14)).foregroundStyle(Theme.text)
                Text("Until then, ⌃⌘ works on any keyboard.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Button("Open Keyboard Settings") { model.openKeyboardSettings() }.buttonStyle(PrimaryButton()).padding(.top, 4)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var speechModel: some View {
        HStack(spacing: 14) {
            Group {
                switch model.speechModelReady {
                case .some(false): ProgressView().controlSize(.small)
                default: PhosphorIcon(name: "CheckCircle", weight: .fill, size: 22).foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(modelTitle).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                Text(modelDetail).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(Theme.settle, value: model.speechModelReady)
    }

    private var modelTitle: String {
        switch model.speechModelReady {
        case .some(true): return "Speech model ready"
        case .some(false): return "Preparing speech…"
        case .none: return "Checking speech…"
        }
    }

    private var modelDetail: String {
        switch model.speechModelReady {
        case .some(false): return model.speechModelNote + " Dictation becomes available when it is ready."
        default: return "Nothing you say is sent anywhere to be transcribed."
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Hold").foregroundStyle(Theme.secondary)
                DictationKeys()
                Text("and speak, then let go.").foregroundStyle(Theme.secondary)
            }
            .font(.system(size: 13))
            TextEditor(text: $model.practiceText)
                .focused($practiceFocused)
                .font(.system(size: 16))
                .scrollContentBackground(.hidden)
                .padding(14)
                .frame(maxHeight: .infinity)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(practiceFocused ? Theme.accent : .clear, lineWidth: 2))
                .overlay(alignment: .topLeading) {
                    if model.practiceText.isEmpty {
                        Text(listening ? (model.dictation.isMicrophoneReady ? (model.dictation.liveText.isEmpty ? "Listening…" : model.dictation.liveText) : "Starting microphone…") : "Your words land here…")
                            .font(.system(size: 16)).foregroundStyle(Theme.tertiary)
                            .padding(.horizontal, 19).padding(.vertical, 14).allowsHitTesting(false)
                    }
                }
                .disabled(!model.isSetUp)
                .animation(.easeOut(duration: 0.15), value: practiceFocused)
            if !model.isSetUp {
                Text("Allow access first; the keys can't reach Enkeon yet.").font(.system(size: 12)).foregroundStyle(Theme.warning)
            }
        }
        .padding(.bottom, 4)
        .onAppear { practiceFocused = model.isSetUp }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Later") { model.showOnboarding = false }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            Spacer()
            if index > 0 {
                Button("Back") { go(-1) }.buttonStyle(SecondaryButton())
            }
            if step == .tryIt {
                Button("Done") { model.finishOnboarding() }.buttonStyle(PrimaryButton()).disabled(!model.isSetUp)
            } else {
                Button("Continue") { go(1) }.buttonStyle(PrimaryButton()).disabled(!canContinue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
    }

    /// Access must be done to go on; the key is optional (⌃⌘ works), and the model can finish in the background.
    private var canContinue: Bool { step != .access || model.permissions.allAllowed }

    private func go(_ delta: Int) {
        forward = delta > 0
        withAnimation(Theme.settle) { index = max(0, min(steps.count - 1, index + delta)) }
    }
}
