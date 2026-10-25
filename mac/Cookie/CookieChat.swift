//
//  CookieChat.swift
//  Cookie
//
//  The conversation: greeting when empty, messages with what Cookie did and
//  how long it took, files you attached, suggested next steps, and the
//  composer (dictate, attach, type, send or stop).
//

import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

struct CookieChatView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var dictation: BuddyDictationManager
    @ObservedObject var navigation: CookieNavigation
    @ObservedObject private var appApprovals = CookieAppApprovals.shared
    @ObservedObject private var recorder = CookieRecorder.shared
    var roomy = false

    @State private var dropTargeted = false
    @State private var conversationWidth: CGFloat = 640

    var body: some View {
        VStack(spacing: 0) {
            if companionManager.chatMessages.isEmpty && !companionManager.isWorking {
                GreetingView(mood: companionManager.voiceState.cookieMood, agent: companionManager.currentAgent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MessageList(companionManager: companionManager, navigation: navigation, roomy: roomy,
                            onShowScreen: { companionManager.showScreenForLastRequest() },
                            onScreenAccess: { companionManager.openScreenAccessSettings() }) { suggestion in
                    companionManager.sendTypedMessage(suggestion)
                }
                .id(companionManager.currentThreadID)
            }
            if recorder.phase != .idle {
                MeetingBar(recorder: recorder)
                    .padding(.horizontal, roomy ? 28 : 18)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .offset(y: 10)))
            }
            ForEach(appApprovals.pending) { item in
                AppApprovalCard(item: item)
                    .padding(.horizontal, roomy ? 28 : 18)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .offset(y: 10)))
            }
            if let approval = companionManager.pendingApproval {
                Group {
                    if approval.actions.count == 1 {
                        ApprovalCard(action: approval.actions[0]) { allow in companionManager.answerApproval(approval.id, answers: [allow]) }
                    } else {
                        BatchApprovalCard(approval: approval) { answers in companionManager.answerApproval(approval.id, answers: answers) }
                    }
                }
                    .padding(.horizontal, roomy ? 28 : 18)
                    .padding(.bottom, 10)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)).combined(with: .offset(y: 10)),
                                            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))))
            }
            CookieComposer(companionManager: companionManager,
                           draft: companionManager.drafts.draft(for: companionManager.currentThreadID),
                           availableWidth: max(0, conversationWidth - (roomy ? 56 : 36)))
                .id(companionManager.currentThreadID)
                .padding(.horizontal, roomy ? 28 : 18)
                .padding(.bottom, 14)
        }
        .background(GeometryReader { geometry in
            Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in
                conversationWidth = width
            }
        })
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(CK.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(CK.accent.opacity(0.06)))
                    .overlay(Label("Drop to attach", systemImage: "paperclip").font(.system(size: 13, weight: .semibold)))
                    .padding(10)
                    .transition(.opacity)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            let destinationDraft = companionManager.drafts.draft(for: companionManager.currentThreadID)
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        let attachment = CookieAttachment(path: url.path)
                        destinationDraft.attach(attachment)
                    }
                }
            }
            return true
        }
        .animation(CK.quick, value: dropTargeted)
        .animation(CK.spring, value: companionManager.pendingApproval)
        .cookieMotionPreferences()
    }
}

// MARK: - Empty state

private struct GreetingView: View {
    let mood: CookieOrb.Mood
    var agent: CookieAgent? = nil
    @State private var appeared = false

    /// A made Cookie introduces itself; Cookie herself says hello.
    private var made: CookieAgent? { agent.flatMap { $0.builtIn ? nil : $0 } }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.orange.opacity(0.14)).frame(width: 110, height: 110).blur(radius: 28)
                CookieAvatar(size: 76, agent: made, mood: mood, animatesIdle: true)
            }
            .scaleEffect(appeared ? 1 : 0.86)
            .opacity(appeared ? 1 : 0)

            VStack(spacing: 6) {
                Text(made.map { "Hi, I’m \($0.name)." } ?? CookieTime.greeting())
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(CK.text)
                Text(made.map { $0.detail.isEmpty ? $0.role : $0.detail } ?? "Ask about anything on your screen.")
                    .font(.system(size: 13))
                    .foregroundStyle(CK.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            HStack(spacing: 6) {
                Text("Hold").font(.system(size: 12)).foregroundStyle(CK.tertiary)
                TalkKeys()
                Text("and talk, or type below").font(.system(size: 12)).foregroundStyle(CK.tertiary)
            }
            .padding(.top, 2)
            Text("Cookie is an AI and can be wrong.")
                .font(.system(size: 10.5))
                .foregroundStyle(CK.tertiary)
                .padding(.top, 10)
        }
        .onAppear { withAnimation(CK.spring.delay(0.05)) { appeared = true } }
    }
}

// MARK: - Messages

private struct MessageList: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var navigation: CookieNavigation
    let roomy: Bool
    let onShowScreen: () -> Void
    let onScreenAccess: () -> Void
    let onSuggestion: (String) -> Void

    @State private var followsLatest = true
    @State private var userIsScrolling = false
    @State private var isNearBottom = true

    var body: some View {
        let messages = companionManager.chatMessages
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if index == 0 || message.date.timeIntervalSince(messages[index - 1].date) > 1800 {
                            Text(CookieTime.separator(message.date))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(CK.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, index == 0 ? 4 : 10)
                        }
                        MessageRow(message: message, isLast: index == messages.count - 1,
                                   navigation: navigation, onShowScreen: onShowScreen, onScreenAccess: onScreenAccess,
                                   onSuggestion: onSuggestion)
                            .id(message.id)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                    }
                    if let step = companionManager.workingStep, let started = companionManager.workingStartedAt {
                        WorkingRow(step: step, startedAt: started, text: companionManager.streamingText).id("working")
                    }
                }
                .padding(.horizontal, roomy ? 32 : 22)
                .padding(.top, 10)
                .padding(.bottom, 24)

            }
            .scrollIndicators(.automatic)
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 48
            } action: { _, nearBottom in
                isNearBottom = nearBottom
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .tracking {
                    userIsScrolling = true
                    followsLatest = false
                } else if phase == .idle {
                    userIsScrolling = false
                    followsLatest = isNearBottom
                }
            }
            .onChange(of: messages.count) { _, _ in
                if messages.last?.role == .user { followsLatest = true }
                scrollToEnd(proxy)
            }
            .onChange(of: companionManager.workingStep) { _, _ in scrollToEnd(proxy) }
            .onChange(of: companionManager.streamingText) { _, _ in scrollToEnd(proxy) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard followsLatest, !userIsScrolling else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if companionManager.workingStep != nil {
                proxy.scrollTo("working", anchor: .bottom)
            } else {
                proxy.scrollTo(companionManager.chatMessages.last?.id, anchor: .bottom)
            }
        }
    }
}

struct MessageRow: View {
    let message: CompanionChatMessage
    let isLast: Bool
    @ObservedObject var navigation: CookieNavigation
    let onShowScreen: () -> Void
    let onScreenAccess: () -> Void
    let onSuggestion: (String) -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        switch message.role {
        case .user: userRow
        case .assistant: assistantRow
        case .failure: failureRow
        case .note: noteRow
        }
    }

    private var userRow: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(message.attachments) { attachment in
                FileCard(attachment: attachment) { navigation.preview = attachment }
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.white)
                    .lineSpacing(4)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 12)
                    .background(
                        UnevenRoundedRectangle(topLeadingRadius: 23, bottomLeadingRadius: 23, bottomTrailingRadius: 8, topTrailingRadius: 23)
                            .fill(LinearGradient(colors: [CK.accent.opacity(0.95), CK.accent.opacity(0.82)], startPoint: .top, endPoint: .bottom))
                    )
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 60)
    }

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.steps.isEmpty {
                StepsDisclosure(steps: message.steps)
            }
            CookieConversationReply(text: message.text)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Text([CookieTime.short(message.date), message.duration.map(CookieTime.duration)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(CK.tertiary)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(copied ? CK.accent : CK.tertiary)
                }
                .buttonStyle(.plain).cookiePointingCursor()
                .accessibilityLabel(copied ? "Copied" : "Copy reply")
                .help("Copy")
                .opacity(hovering || copied ? 1 : 0)
            }

            if isLast && message.screenAccessOff == true {
                PillButton(title: "Turn on screen access", symbol: "gearshape", primary: true, action: onScreenAccess)
                    .padding(.top, 2)
            }

            if isLast && message.wantsScreen == true {
                PillButton(title: "Show my screen", symbol: "rectangle.dashed", primary: true, action: onShowScreen)
                    .padding(.top, 2)
            }

            if isLast && !message.nextSteps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NEXT STEPS")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(CK.tertiary)
                    HStack(spacing: 6) {
                        ForEach(message.nextSteps, id: \.self) { suggestion in
                            PillButton(title: suggestion) { onSuggestion(suggestion) }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.trailing, 16)
        .onHover { hovering = $0 }
        .animation(CK.quick, value: hovering)
    }

    private var failureRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(message.text)
                .font(.system(size: 12))
                .foregroundStyle(CK.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.18)))
    }

    private var noteRow: some View {
        Text(message.text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(CK.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(CK.hairline))
    }
}

/// Shared by streaming and finished replies so their typography and wrapping stay consistent.
struct CookieConversationReply: View {
    let text: String

    var body: some View {
        Text(CompanionManager.visibleReply(text))
            .font(.system(size: 15, design: .rounded))
            .foregroundStyle(CK.text)
            .lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)

    }
}

/// "› 2 steps · 3.4s" — opens to show what Cookie did.
private struct StepsDisclosure: View {
    let steps: [CookieStep]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(CK.spring) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text("\(steps.count) \(steps.count == 1 ? "step" : "steps")")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(CK.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(CK.accent.opacity(0.9))
                            Text(step.title).font(.system(size: 12)).foregroundStyle(CK.secondary)
                            if step.seconds > 0.05 {
                                Text(CookieTime.duration(step.seconds)).font(.system(size: 11)).foregroundStyle(CK.tertiary)
                            }
                        }
                    }
                }
                .padding(.leading, 2)
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
    }
}

private struct WorkingRow: View {
    let step: String
    let startedAt: Date
    /// The reply so far, while it streams in.
    var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Above the text, where the finished reply shows its steps, so the
            // text doesn't move when the reply lands.
            if !text.isEmpty { stepLine }
            if text.isEmpty {
                ThinkingDots()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(CK.fill))
            } else {
                CookieConversationReply(text: text)
                    .padding(.trailing, 16)
            }
            if text.isEmpty { stepLine }
        }
        .transition(.opacity)
    }

    private var stepLine: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Text("\(step) · \(Int(context.date.timeIntervalSince(startedAt)))s")
                .font(.system(size: 11))
                .foregroundStyle(CK.tertiary)
                .contentTransition(.numericText())
        }
    }
}

// MARK: - Approval cards

/// How one action reads on a card: the question, what it does, its icon.
@MainActor
extension HarnessAction {
    var openTarget: CookieOpen.Target? {
        tool == CookieOpen.tool.name ? CookieOpen.target(preview: preview, apps: CookieOpen.installedApps()) : nil
    }

    var question: String {
        if let mac = MacOperator.shared.question(for: self) { return mac }
        if let handoff = CookieHandoff.question(for: self) { return handoff }
        if let routine = CookieRoutineWords.question(for: self) { return routine }
        switch openTarget {
        case .settings?: return "Open System Settings?"
        case .app(let url)?: return "Open \(url.deletingPathExtension().lastPathComponent)?"
        case .web(let url)?: return "Open \(url.host ?? url.absoluteString)?"
        case nil: return tool == "workspace" ? "Update this workspace?" : "Let Cookie use \(tool)?"
        }
    }

    var consequence: String {
        if tool == "workspace" { return "Saves a local draft in this conversation. Nothing is published or sent." }
        if tool == "start_task" { return "One yes covers this task in these apps. Sending, paying or deleting still asks. Esc stops it." }
        if tool == CookieRoutineWords.tool.name {
            if let agent = CookieRoutineWords.namedCookie { return "\(agent.name) does this job at those times on this Mac; it shows on your Board, where you can remove it." }
            return "Cookie gives itself this job at those times; it shows on your Board, where you can pause it."
        }
        switch openTarget {
        case .web?: return "In your browser. Nothing opens unless you allow it."
        case .some: return "On this Mac. Nothing opens unless you allow it."
        case nil:
            switch effect {
            case "outbound": return "This sends something to someone else."
            case "destroy": return "This deletes, pays or buys something."
            case "write": return "This changes something of yours."
            default: return reason
            }
        }
    }
}

/// The action's own icon: the app's icon for open, a globe for a link, else its effect.
struct ActionIcon: View {
    let action: HarnessAction
    var size: CGFloat = 38

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        switch action.openTarget {
        case .settings?, .app?:
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.35), radius: size * 0.1, y: size * 0.05)
        default:
            Image(systemName: action.openTarget == nil ? effectSymbol : "globe")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(CK.accent)
                .frame(width: size, height: size)
                .background(tile.fill(CK.accent.opacity(0.14)))
                .overlay(tile.strokeBorder(CK.accent.opacity(0.25), lineWidth: 0.5))
        }
    }

    private var appIcon: NSImage {
        switch action.openTarget {
        case .app(let url)?: return NSWorkspace.shared.icon(forFile: url.path)
        default:
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences")
            return url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
        }
    }

    private var effectSymbol: String {
        switch action.effect {
        case "outbound": return "paperplane.fill"
        case "destroy": return "trash.fill"
        case "write": return "square.and.pencil"
        default: return "hand.raised.fill"
        }
    }
}

/// A value Cookie found rather than one you said: the thing to check.
struct FromDataNote: View {
    let values: [String]
    var compact = false

    var body: some View {
        let box = RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous)
        HStack(alignment: .top, spacing: compact ? 7 : 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: compact ? 10 : 12))
                .foregroundStyle(Color.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                Text("Not typed by you")
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(CK.text)
                ForEach(values, id: \.self) { value in
                    Text(value.replacingOccurrences(of: " = ", with: ": "))
                        .font(.system(size: compact ? 11 : 11.5, design: .monospaced))
                        .foregroundStyle(CK.text.opacity(0.85))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                if !compact {
                    Text("Cookie found this on your screen, in a file or a page. Check it's right before you say yes.")
                        .font(.system(size: 11))
                        .foregroundStyle(CK.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 8 : 11)
        .background(box.fill(Color.orange.opacity(0.08)))
        .overlay(box.strokeBorder(Color.orange.opacity(0.24), lineWidth: 0.75))
    }
}

/// A quiet surface shared by approvals and the recording controls.
private struct ApprovalSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shell = RoundedRectangle(cornerRadius: 18, style: .continuous)
        content
            .padding(16)
            .background(shell.fill(LinearGradient(colors: [Color(white: 0.19), Color(white: 0.15)],
                                                 startPoint: .top, endPoint: .bottom)))
            .overlay(shell.strokeBorder(Color.white.opacity(0.065), lineWidth: 0.5))
            .clipShape(shell)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

/// Cookie wants to do one thing that needs your yes. One question in plain
/// words, what it acts on, and the verb on the button. Allow is a deliberate
/// click: no default key, so a stray Return can't say yes. Folding the panel
/// away is not an answer; Not now, Stop, a new message or another chat say no.
struct ApprovalCard: View {
    let action: HarnessAction
    let answer: (Bool) -> Void
    @State private var showsDetails = false

    private var target: CookieOpen.Target? { action.openTarget }
    private var workspaceSummary: String? {
        guard action.tool == "workspace" else { return nil }
        let arguments = MacOperator.args(of: action)
        guard let payload = arguments["payload"] as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
        let title = object["title"] as? String ?? object["id"] as? String ?? "Workspace output"
        let summary = object["summary"] as? String ?? "Save an updated draft"
        var lines = [title, summary]
        if let content = object["content"] as? [String: Any], let grid = content["grid"] as? [[String]] {
            lines.append("\(grid.count) rows · \(grid.map(\.count).max() ?? 0) columns")
        }
        return lines.joined(separator: "\n")
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ActionIcon(action: action)
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.question)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(CK.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(action.consequence)
                        .font(.system(size: 11.5))
                        .foregroundStyle(CK.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if target != nil || workspaceSummary != nil {
                        Button { withAnimation(CK.quick) { showsDetails.toggle() } } label: {
                            HStack(spacing: 4) {
                                Text(showsDetails ? "Hide details" : "Details")
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .rotationEffect(.degrees(showsDetails ? 180 : 0))
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CK.tertiary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .cookiePointingCursor()
                        .padding(.top, 2)
                    }
                }

            }

            if !action.fromData.isEmpty { FromDataNote(values: action.fromData) }

            // Anything but open shows exactly what would happen: the recipient, the amount.
            if let workspaceSummary {
                Text(workspaceSummary).font(.system(size: 12)).foregroundStyle(CK.secondary).fixedSize(horizontal: false, vertical: true)
                if showsDetails { PreviewText(text: action.preview) }
            } else if action.tool == "start_task" {
                let args = MacOperator.args(of: action)
                PreviewText(text: "\(args["plan"] as? String ?? "")\n\nApps: \(args["apps"] as? String ?? "")")
            } else if target == nil || showsDetails, !action.preview.isEmpty {
                PreviewText(text: action.preview)
            }
            Divider().overlay(CK.hairline)
                HStack(spacing: 8) {
                    PillButton(title: "Not now") { answer(false) }
                    if let target, CookieOpen.alwaysKey(target) != nil, action.fromData.isEmpty {
                        Menu { Button("Always allow this destination") { CookieOpen.allowAlways(target); answer(true) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().cookiePointingCursor()
                            .help("Open \(action.question.dropFirst(5).dropLast()) without asking from now on. Undo in Settings → Privacy & safety.")
                    }
                    PillButton(title: action.tool == "start_task" ? "Start" : target == nil ? "Allow" : "Open",
                               symbol: target == nil ? "checkmark" : "arrow.up.forward.app", primary: true) { answer(true) }
                }

                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .modifier(ApprovalSurface())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(action.question) \(action.consequence)")
    }
}

/// Every action of one turn on one card: tick what Cookie may do. What you
/// named starts ticked; what Cookie found and you didn't write starts unticked.
struct BatchApprovalCard: View {
    let approval: HarnessApproval
    let answer: ([Bool]) -> Void
    @State private var ticked: [Bool]

    init(approval: HarnessApproval, answer: @escaping ([Bool]) -> Void) {
        self.approval = approval
        self.answer = answer
        _ticked = State(initialValue: approval.startingAnswers)
    }

    private var count: Int { ticked.filter { $0 }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review \(approval.actions.count) actions")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(CK.text)
                    Text("Untick anything you don't want. Nothing happens until you choose.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(CK.secondary)
                }

            }
            ScrollView {
            VStack(spacing: 6) {
                ForEach(Array(approval.actions.enumerated()), id: \.offset) { index, action in
                    row(action, index: index)
                }
            }
            }.frame(maxHeight: 180)
            Divider().overlay(CK.hairline)
                HStack(spacing: 8) {
                    PillButton(title: "Not now") { answer(Array(repeating: false, count: approval.actions.count)) }
                    PillButton(title: "Allow \(count)", symbol: "checkmark", primary: true) { answer(ticked) }
                        .disabled(count == 0)
                        .opacity(count == 0 ? 0.45 : 1)
                }

                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .modifier(ApprovalSurface())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cookie wants to do \(approval.actions.count) things")
    }

    private func row(_ action: HarnessAction, index: Int) -> some View {
        let box = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button { withAnimation(CK.quick) { ticked[index].toggle() } } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: ticked[index] ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(ticked[index] ? CK.accent : CK.tertiary)
                    ActionIcon(action: action, size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.question.hasSuffix("?") ? String(action.question.dropLast()) : action.question)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(CK.text)
                            .lineLimit(1)
                        Text(action.preview)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(CK.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                if !action.fromData.isEmpty { FromDataNote(values: action.fromData, compact: true) }
            }
            .padding(9)
            .background(box.fill(ticked[index] ? CK.accent.opacity(0.07) : Color.white.opacity(0.025)))
            .overlay(box.strokeBorder(ticked[index] ? CK.accent.opacity(0.25) : Color.white.opacity(0.05), lineWidth: 0.75))
            .contentShape(box)
        }
        .buttonStyle(.plain)
        .cookiePointingCursor()
        .accessibilityLabel(action.question)
        .accessibilityAddTraits(ticked[index] ? .isSelected : [])
    }
}

/// An action in a connected app, parked on Enkeon until the person says yes.
/// The text is the person's own request, exactly as it would be sent.
struct AppApprovalCard: View {
    let item: GatewayApproval
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: item.class == "destroy" ? "trash.fill" : "paperplane.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CK.accent)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(CK.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.question)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(CK.text)
                    Text("\(item.actionName) · nothing happens unless you say yes.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(CK.secondary)
                }

            }
            if let detail = item.detail, !detail.isEmpty {
                PreviewText(text: detail)
            } else {
                Text("Enkeon didn't send the details of this action. Check it in the Enkeon console before saying yes.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.orange)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Color.orange)
            }
            Divider().overlay(CK.hairline)
                HStack(spacing: 8) {
                    PillButton(title: "Not now") { answer(false) }
                    PillButton(title: item.verb, symbol: "checkmark", primary: true) { answer(true) }
                }
                .disabled(busy)

                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .modifier(ApprovalSurface())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.question)
    }

    private func answer(_ approve: Bool) {
        busy = true
        Task {
            error = await CookieAppApprovals.shared.decide(item, approve: approve)
            busy = false
        }
    }
}

/// A meeting being recorded, transcribed, or ready to keep.
struct MeetingBar: View {
    @ObservedObject var recorder: CookieRecorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            content
        }
        .modifier(ApprovalSurface())
    }

    @ViewBuilder private var content: some View {
        switch recorder.phase {
        case .recording(let secs, let level, let micOnly):
            Circle().fill(Color.red).frame(width: 10, height: 10)
                .opacity(pulse || reduceMotion ? 1 : 0.35)
                .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
            VStack(alignment: .leading, spacing: 4) {
                Text("Recording · \(String(format: "%d:%02d", secs / 60, secs % 60))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(CK.text)
                Capsule().fill(CK.fill).frame(width: 140, height: 4)
                    .overlay(alignment: .leading) { Capsule().fill(CK.accent).frame(width: 140 * min(1, max(0.04, level * 3)), height: 4) }
                Text(micOnly ? "Only your microphone: turn on Screen Recording for Cookie to hear the call." : "Your microphone and the call, kept apart. No bot joins.")
                    .font(.system(size: 11)).foregroundStyle(micOnly ? Color.orange : CK.secondary)
            }
            Spacer(minLength: 8)
            PillButton(title: "Stop", symbol: "stop.fill", primary: true) { recorder.stop() }
        case .stopping, .transcribing:
            ProgressView().controlSize(.small)
            Text("Transcribing on Enkeon… you can keep working.")
                .font(.system(size: 12.5)).foregroundStyle(CK.secondary)
            Spacer()
        case .ready(_, let summary, let promises, let minutes):
            Image(systemName: "waveform.badge.checkmark").font(.system(size: 18)).foregroundStyle(CK.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Meeting ready · \(minutes) min\(promises > 0 ? " · \(promises) promise\(promises == 1 ? "" : "s")" : "")")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(CK.text)
                if !summary.isEmpty {
                    Text(summary).font(.system(size: 11.5)).foregroundStyle(CK.secondary).lineLimit(3)
                }
                Text("Keep it to add it to your Enkeon context; nothing is kept until you do.")
                    .font(.system(size: 11)).foregroundStyle(CK.tertiary)
            }
            Spacer(minLength: 8)
            PillButton(title: "Discard") { recorder.decide(keep: false) }
            PillButton(title: "Keep", symbol: "checkmark", primary: true) { recorder.decide(keep: true) }
        case .failed(let why):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
            Text(why).font(.system(size: 12)).foregroundStyle(CK.text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            PillButton(title: "OK") { recorder.dismiss() }
        case .idle:
            EmptyView()
        }
    }
}

/// Exactly what would happen, as the harness rendered it.
private struct PreviewText: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(CK.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 100)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.15)))
        .transition(.opacity)
    }
}

/// A file in the conversation. Click to preview it beside the chat.
struct FileCard: View {
    let attachment: CookieAttachment
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                FileThumbnail(attachment: attachment, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CK.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(attachment.kind) · Open")
                        .font(.system(size: 11))
                        .foregroundStyle(CK.tertiary)
                }
            }
            .padding(8)
            .padding(.trailing, 6)
            .frame(maxWidth: 260, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? CK.fillHover : CK.fill))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(CK.hairline))
            .scaleEffect(hovering ? 1.01 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(CK.quick, value: hovering)
    }
}

// MARK: - File preview

/// Quick Look, beside the chat.
struct FilePreviewPane: View {
    let attachment: CookieAttachment
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(attachment.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("· \(attachment.kind)")
                    .font(.system(size: 12))
                    .foregroundStyle(CK.tertiary)
                Spacer(minLength: 8)
                IslandButton(symbol: "arrow.up.forward.app", help: "Open", size: 24) {
                    NSWorkspace.shared.open(attachment.url)
                }
                IslandButton(symbol: "folder", help: "Show in Finder", size: 24) {
                    NSWorkspace.shared.activateFileViewerSelecting([attachment.url])
                }
                IslandButton(symbol: "xmark", help: "Close", size: 24, action: close)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)

            QuickLookView(url: attachment.url)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding([.horizontal, .bottom], 8)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(CK.hairline))
    }
}

private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
}
