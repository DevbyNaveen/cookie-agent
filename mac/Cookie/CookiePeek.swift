//
//  CookiePeek.swift
//  Cookie
//
//  The notch peek: three rows and a chat field.
//    Latest  - the newest thing that happened (a reply, a moved card, meeting notes)
//    Now     - what Cookie is doing, else what waits for you on the Board
//              (Cookie's drafts, approvals and questions first), else where your work stands
//    Up next - your next meeting with one line of prep, else the most urgent work
//  The rows are built from plain values (testable); PeekView wires them up.
//

import SwiftUI

enum PeekAction: Equatable {
    case none, openThread(UUID), openWork(UUID), openWorkBoard, openMeeting, stop, review
    case connectCalendar, prepare(UpcomingMeeting)
}

struct PeekLine: Equatable, Identifiable {
    enum Kind: String { case latest, now, upNext }
    let kind: Kind
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var activityDate: Date?
    var button: String?
    var action: PeekAction = .none
    /// A live reply is in progress; tracked work alone does not set this.
    var busy = false
    var characterMood: CookieOrb.Mood = .idle
    var id: String { kind.rawValue }

    var label: String {
        switch kind {
        case .latest: return "Latest"
        case .now: return "Now"
        case .upNext: return "Up next"
        }
    }
}

enum PeekLines {
    struct MeetingNotes: Equatable { let minutes: Int; let promises: Int }

    static func latest(threads: [CookieThread], work: [WorkItem], meetingNotes: MeetingNotes?, chatsLocked: Bool,
                       now: Date = Date()) -> PeekLine {
        if let notes = meetingNotes {
            let promises = notes.promises == 1 ? "1 promise" : "\(notes.promises) promises"
            return PeekLine(kind: .latest, symbol: "waveform", tint: CK.accent, title: "Your meeting notes are ready",
                            detail: "\(notes.minutes) min · \(promises)", button: "Open", action: .openMeeting)
        }
        var best: (date: Date, line: PeekLine)?
        func consider(_ date: Date, _ line: PeekLine) {
            if best == nil || date > best!.date { best = (date, line) }
        }
        for item in work {
            guard let event = item.history.last(where: { $0.by != "you" }) else { continue }
            consider(event.date, PeekLine(kind: .latest, symbol: "bell", tint: WorkColumn.cookie.tint, title: event.text,
                                          detail: "\(item.title) · \(ago(event.date, now: now))", button: "Open",
                                          action: .openWork(item.id)))
        }
        if !chatsLocked {
            for thread in threads {
                guard let activity = thread.messages.last else { continue }
                let request = thread.messages.last(where: { $0.role == .user })
                let question = preview(request?.text ?? "")
                let title = question.isEmpty ? (request?.attachments.first?.name ?? "Conversation update") : question
                let detail: String
                switch activity.role {
                case .user: detail = "Your message · Open to continue"
                case .failure: detail = "Couldn't finish · " + preview(activity.text)
                case .note: detail = preview(activity.text)
                case .assistant: detail = preview(activity.text)
                }
                consider(activity.date, PeekLine(kind: .latest,
                    symbol: activity.role == .failure ? "exclamationmark.circle" : "bubble.left",
                    tint: activity.role == .failure ? .orange : CK.secondary,
                    title: title, detail: detail.isEmpty ? "Open conversation" : detail,
                    activityDate: activity.date, button: "Continue", action: .openThread(thread.id)))
            }
        }
        return best?.line ?? PeekLine(kind: .latest, symbol: "tray", tint: CK.tertiary, title: "Nothing new yet",
                                      detail: "What Cookie finishes shows up here.")
    }

    /// `boardNeeds`: the titles of what waits for the person in Cookie's API (`CookieAPI.needs`).
    static func now(working: Bool, step: String?, threadTitle: String?, approval: String?, work: [WorkItem],
                    voiceState: CompanionVoiceState = .idle, dozing: Bool = false, boardNeeds: [String] = []) -> PeekLine {
        if let approval {
            return PeekLine(kind: .now, symbol: "hand.raised.fill", tint: .orange, title: "Cookie needs your OK",
                            detail: approval, button: "Review", action: .review)
        }
        if voiceState == .listening {
            return PeekLine(kind: .now, symbol: "waveform", tint: CK.accent, title: "I’m listening",
                            detail: "Release the keys when you’re ready.", characterMood: .listening)
        }
        if voiceState == .responding {
            return PeekLine(kind: .now, symbol: "waveform", tint: CK.accent, title: "Talking it through",
                            detail: threadTitle ?? "Your reply", button: "Stop", action: .stop, busy: true, characterMood: .speaking)
        }
        if working {
            return PeekLine(kind: .now, symbol: "sparkles", tint: WorkColumn.cookie.tint, title: step ?? "Thinking",
                            detail: threadTitle ?? "Working on it", button: "Stop", action: .stop, busy: true, characterMood: .thinking)
        }
        let open = work.filter { $0.column != .done }
        if let first = boardNeeds.first {
            let count = boardNeeds.count + open.filter { $0.column == .needsYou }.count
            return PeekLine(kind: .now, symbol: WorkColumn.needsYou.symbol, tint: WorkColumn.needsYou.tint,
                            title: "\(count) need\(count == 1 ? "s" : "") you", detail: first,
                            button: "Board", action: .openWorkBoard)
        }
        let needs = open.filter { $0.column == .needsYou }.count
        let waiting = open.filter { $0.column == .waiting }.count
        let doing = open.filter { $0.column == .cookie }.count
        var parts: [String] = []
        if needs > 0 { parts.append("\(needs) need\(needs == 1 ? "s" : "") you") }
        if doing > 0 { parts.append("\(doing) with Cookie") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return PeekLine(kind: .now, symbol: needs > 0 ? WorkColumn.needsYou.symbol : "checkmark.circle",
                        tint: needs > 0 ? WorkColumn.needsYou.tint : CK.secondary,
                        title: dozing ? "Resting" : "Ready when you are",
                        detail: parts.isEmpty ? (dozing ? "A word or the keys wakes me." : "A thought, a question, a little help.") : parts.joined(separator: " · "),
                        button: open.isEmpty ? nil : "Board",
                        action: open.isEmpty ? .none : .openWorkBoard, characterMood: dozing ? .sleeping : .idle)
    }

    static func upNext(access: CookieCalendar.Access, meeting: UpcomingMeeting?, recalled: String?, work: [WorkItem],
                       now: Date = Date()) -> PeekLine {
        switch access {
        case .notAsked:
            return PeekLine(kind: .upNext, symbol: "calendar", tint: CK.accent, title: "A little ahead of your day",
                            detail: "Connect Calendar for your next meeting.", button: "Connect",
                            action: .connectCalendar)
        case .denied:
            return PeekLine(kind: .upNext, symbol: "calendar.badge.exclamationmark", tint: CK.secondary,
                            title: "Calendar access is off", detail: "Turn it on in System Settings to see what's next.",
                            button: "Settings", action: .connectCalendar)
        case .allowed:
            break
        }
        if let meeting {
            let title = "\(meeting.title) · \(UpNextText.when(meeting.start, now: now))"
            if let item = UpNextText.work(for: meeting, in: work) {
                return PeekLine(kind: .upNext, symbol: "calendar", tint: CK.accent, title: title,
                                detail: item.nextStep.isEmpty ? item.title : "\(item.title): \(item.nextStep)",
                                button: "Open", action: .openWork(item.id))
            }
            let detail = recalled ?? (meeting.attendees.isEmpty ? "No notes on this yet."
                : "With " + meeting.attendees.prefix(3).joined(separator: ", "))
            return PeekLine(kind: .upNext, symbol: "calendar", tint: CK.accent, title: title, detail: detail,
                            button: "Prepare", action: .prepare(meeting))
        }
        let urgent = work.filter { $0.column != .done && $0.due != nil }.sorted(by: WorkStore.order).first
        if let item = urgent, let due = item.due, due < now.addingTimeInterval(2 * 86_400) {
            return PeekLine(kind: .upNext, symbol: item.isOverdue(now: now) ? "exclamationmark.circle" : "flag",
                            tint: item.isOverdue(now: now) ? WorkColumn.waiting.tint : CK.secondary,
                            title: "\(item.title) · \(WorkText.due(due, now: now))", detail: item.nextStep,
                            button: "Open", action: .openWork(item.id))
        }
        return PeekLine(kind: .upNext, symbol: "calendar", tint: CK.secondary, title: "Nothing scheduled",
                        detail: "No meetings in the next 12 hours.")
    }

    /// What Cookie is asked when you press Prepare on a meeting.
    static func prepareMessage(_ meeting: UpcomingMeeting) -> String {
        var text = "Get me ready for my meeting \u{201C}\(meeting.title)\u{201D} \(UpNextText.when(meeting.start))"
        if !meeting.attendees.isEmpty { text += " with " + meeting.attendees.joined(separator: ", ") }
        return text + ". Recall what we know about them and this topic, what I promised, and what's still open. Keep it to five short lines."
    }

    /// A compact readable excerpt, never a generated or invented summary.
    static func preview(_ text: String) -> String {
        let spoken = CookieReplyTags.split(text, streaming: true).spoken
        return spoken
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*(?:#{1,6}\s+|[-*•]\s+|[0-9]+[.)]\s+)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func ago(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? "just now" : RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
    }
}

// MARK: - The view

struct CookiePeekMetrics {
    static let statusHeight: CGFloat = 82
    static let updateHeight: CGFloat = 62
    static let latestHeight: CGFloat = 96
    static let rowSpacing: CGFloat = 4
    static let verticalPadding: CGFloat = 6
    static let composerHeight: CGFloat = 56

    static func height(header: CGFloat) -> CGFloat {
        header + statusHeight + latestHeight + updateHeight + rowSpacing * 2 + verticalPadding * 2 + composerHeight
    }
}

struct CookiePeekContent: View {
    let lines: [PeekLine]
    let isLocked: Bool
    let needsPermissions: Bool
    let headerHeight: CGFloat
    @Binding var showsShortcuts: Bool
    let perform: (PeekAction) -> Void
    let send: (String) -> Void
    let openChats: () -> Void
    let openSettings: () -> Void
    @Binding var draft: String
    var composerPhase: CookieComposerPhase = .ready
    var audioLevel: CGFloat = 0
    var dictating = false
    /// Where the character looks while Cookie points at something on screen.
    var gaze: CGFloat? = nil
    @FocusState private var typing: Bool

    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSend: Bool { composerPhase.canSubmit }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: CookiePeekMetrics.rowSpacing) {
                    if let status = lines.first(where: { $0.kind == .now }) {
                        PeekStatusRow(line: status, gaze: gaze, perform: perform)
                    }
                    ForEach(lines.filter { $0.kind != .now }) { line in
                        PeekUpdateRow(line: line) { perform(line.action) }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, CookiePeekMetrics.verticalPadding)
            }
            .scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize)
            chatField
                .padding(.horizontal, 16)
                .frame(height: CookiePeekMetrics.composerHeight)
        }
        .foregroundStyle(CK.text)
        .cookieMotionPreferences()
        .onChange(of: composerPhase) { _, phase in
            if phase != .ready { typing = false }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Cookie").font(.system(size: 13, weight: .semibold)).tracking(-0.15)
            if needsPermissions {
                Button(action: openSettings) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(WorkColumn.waiting.tint)
                        .frame(width: 22, height: 24)
                }
                .buttonStyle(.plain).cookiePointingCursor()
                .accessibilityLabel("Review Cookie permissions").help("Review permissions")
            }
            Spacer()
            PeekUtilityButton(symbol: "keyboard", title: "Shortcuts", selected: showsShortcuts) {
                withAnimation(CK.quick) { showsShortcuts.toggle() }
            }
            PeekUtilityButton(symbol: "gearshape", title: "Settings", action: openSettings)
        }
        .padding(.horizontal, 20).frame(height: headerHeight)
    }

    @ViewBuilder private var chatField: some View {
        if isLocked {
            Button(action: openChats) {
                HStack(spacing: 8) {
                    Image(systemName: "lock")
                    Text("Unlock to talk with Cookie")
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12)).foregroundStyle(CK.secondary)
                .padding(.horizontal, 13).frame(height: 38)
                .background(CK.fill, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain).cookiePointingCursor()
        } else {
            HStack(spacing: 8) {
                HStack(spacing: 9) {
                    if composerPhase != .ready {
                        activeVoiceContent
                            .transition(.opacity)
                    } else {
                        Image(systemName: "sparkle").font(.system(size: 13)).foregroundStyle(typing ? CK.accent : CK.secondary)
                            .accessibilityHidden(true)
                        TextField("Ask Cookie…", text: $draft)
                            .textFieldStyle(.plain).font(.system(size: 12.5))
                            .focused($typing).onSubmit(submit).accessibilityLabel("Ask Cookie")
                        if hasDraft {
                            Button(action: submit) {
                                Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 26, height: 26)
                                    .background(CK.accent, in: Circle())
                            }
                            .buttonStyle(.plain).cookiePointingCursor()
                            .accessibilityLabel("Send message").help("Send message")
                        } else if typing {
                            Text("↵").font(.system(size: 13)).foregroundStyle(CK.tertiary).accessibilityHidden(true)
                        }
                    }
                }
                .padding(.leading, 12).padding(.trailing, 6).frame(height: 38)
                .background(Color.white.opacity(typing || composerPhase == .listening ? 0.075 : 0.04), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(typing || composerPhase == .listening ? CK.accent.opacity(0.4) : .clear, lineWidth: 0.75)
                }
                PeekUtilityButton(symbol: "arrow.up.left.and.arrow.down.right", title: "Open Cookie", size: 32, action: openChats)
            }
            .animation(CK.quick, value: typing)
            .animation(CK.quick, value: composerPhase)
        }
    }

    private var activeVoiceContent: some View {
        HStack(spacing: 9) {
            CookieVoiceMedallion(phase: composerPhase, audioLevel: audioLevel, size: 28)
            Text(dictating && composerPhase == .listening ? "Dictating" : composerPhase.title)
                .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            Spacer(minLength: 4)
            if composerPhase == .listening {
                Text(dictating ? "Release to insert" : "Release to send")
                    .font(.system(size: 10.5)).foregroundStyle(CK.secondary).lineLimit(1)
            } else if composerPhase.canStop {
                PeekUtilityButton(symbol: "stop.fill", title: "Stop response", size: 26) { perform(.stop) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(composerPhase.title). \(composerPhase.subtitle)")
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !isLocked, !text.isEmpty else { return }
        draft = ""
        send(text)
    }
}

private struct PeekStatusRow: View {
    let line: PeekLine
    var gaze: CGFloat? = nil
    let perform: (PeekAction) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 13) {
            CookieAvatar(size: 52, mood: line.characterMood, animatesIdle: true, isEngaged: hovering, gaze: gaze)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(line.action == .review ? "NEEDS YOU" : line.busy ? "WITH COOKIE" : "NOW")
                        .font(.system(size: 8.5, weight: .semibold)).tracking(1)
                        .foregroundStyle(line.action == .review ? WorkColumn.waiting.tint : CK.tertiary)
                    Spacer(minLength: 4)
                    if let title = line.button {
                        Button { perform(line.action) } label: {
                            HStack(spacing: 4) {
                                Text(title)
                                Image(systemName: line.action == .stop ? "stop.fill" : "chevron.right")
                                    .font(.system(size: 7.5, weight: .semibold))
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(line.action == .review ? WorkColumn.waiting.tint : CK.secondary)
                            .padding(.horizontal, 7).frame(height: 22)
                            .background(Color.white.opacity(hovering ? 0.08 : 0.035), in: Capsule())
                        }
                        .buttonStyle(.plain).cookiePointingCursor()
                        .accessibilityLabel(line.action == .stop ? "Stop Cookie’s current reply" : title)
                    }
                }
                .frame(height: 14)
                Text(line.title).font(.system(size: 15, weight: .semibold)).tracking(-0.25).lineLimit(1)
                Text(line.detail).font(.system(size: 11)).foregroundStyle(CK.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: CookiePeekMetrics.statusHeight)
        .background {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.055), Color.white.opacity(0.02)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        // The whole card opens the Board; the small button keeps its own action (Stop, review, open work).
        .onTapGesture { perform(.openWorkBoard) }
        .cookiePointingCursor()
        .onHover { hovering = $0 }
        .animation(CK.quick, value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cookie’s status")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the Board")
        .accessibilityAction { perform(.openWorkBoard) }
    }
}

private struct PeekUpdateRow: View {
    let line: PeekLine
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Group {
            if line.action == .none {
                content
            } else {
                Button(action: action) { content }
                    .buttonStyle(.plain).cookiePointingCursor()
                    .accessibilityLabel("\(line.label): \(line.title). \(line.detail)")
                    .accessibilityHint(line.button ?? "Open")
                    .help("\(line.title)\n\(line.detail)")
            }
        }
        .onHover { hovering = $0 }
        .animation(CK.quick, value: hovering)
    }

    private var content: some View {
        HStack(spacing: 11) {
            Image(systemName: line.symbol)
                .font(.system(size: 15, weight: .regular)).foregroundStyle(line.tint.opacity(0.85))
                .frame(width: 30, height: 34).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text((line.kind == .latest && line.activityDate != nil ? "Recent conversation" : line.label).uppercased()).font(.system(size: 8, weight: .semibold)).tracking(0.8).foregroundStyle(CK.tertiary)
                    if let date = line.activityDate {
                        Text(date, style: .relative).font(.system(size: 9)).foregroundStyle(CK.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let title = line.button {
                        HStack(spacing: 4) {
                            Text(title).font(.system(size: 10, weight: .medium))
                            Image(systemName: "chevron.right").font(.system(size: 7.5, weight: .semibold))
                        }
                        .foregroundStyle(line.action == .connectCalendar ? CK.accent : CK.secondary)
                    }
                }
                Text(line.title).font(.system(size: 12, weight: .medium)).foregroundStyle(CK.text).lineLimit(line.kind == .latest ? 2 : 1)
                Text(line.detail).font(.system(size: 10.5)).foregroundStyle(CK.secondary).lineLimit(line.kind == .latest ? 2 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .multilineTextAlignment(.leading).padding(.horizontal, 13)
        .frame(height: line.kind == .latest ? CookiePeekMetrics.latestHeight : CookiePeekMetrics.updateHeight)
        .background(hovering && line.action != .none ? Color.white.opacity(0.035) : .clear,
                    in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct PeekUtilityButton: View {
    let symbol: String
    let title: String
    var size: CGFloat = 24
    var selected = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected || hovering ? CK.text : CK.secondary)
                .frame(width: size, height: size)
                .background(selected || hovering ? CK.fillHover : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).cookiePointingCursor().onHover { hovering = $0 }
        .help(title).accessibilityLabel(title)
        .animation(CK.quick, value: hovering)
    }
}
