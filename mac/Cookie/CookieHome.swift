//
//  CookieHome.swift
//  Cookie
//
//  Cookie's home: chats on the left, the conversation (or settings) on the
//  right, a file preview beside it when one is open. The same view lives in
//  the notch and in the pop-out window.
//

import SwiftUI

struct CookieHomeView: View {
    @ObservedObject private var workspace = CookieWorkspaceStore.shared
    @ObservedObject private var agents = CookieAgentStore.shared
    enum Mode { case notch, window }
    @ObservedObject private var lock = ChatLock.shared

    let mode: Mode
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var navigation: CookieNavigation
    /// The strip the hardware notch covers; content keeps clear of it.
    var topInset: CGFloat = 0
    var popOut: () -> Void = {}
    var close: () -> Void = {}

    private var showsWorkspace: Bool {
        navigation.settingsPage == nil && !lock.isLocked && navigation.agentPage == nil &&
        !navigation.showsWorkComposer && navigation.section == .chats && navigation.preview == nil &&
        workspace.session(companionManager.currentThreadID).showing
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = CookieHomeLayout(width: geometry.size.width)
            HStack(spacing: 0) {
                if layout.showsSidebar && !showsWorkspace {
                    sidebar(width: layout.sidebarWidth)
                }
                VStack(spacing: 0) {
                    header(showsSidebarToggle: !layout.showsSidebar || showsWorkspace, width: layout.width)
                    conversation(layout: layout)
                }
            }
            .overlay(alignment: .leading) {
                if (!layout.showsSidebar || showsWorkspace) && navigation.showsSidebarDrawer {
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.25)
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(CK.spring) { navigation.showsSidebarDrawer = false } }
                        sidebar(width: layout.drawerWidth)
                            .background(CK.island)
                    }
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .onChange(of: layout.showsSidebar) { _, visible in
                if visible { navigation.showsSidebarDrawer = false }
            }
        }
        .foregroundStyle(CK.text)
        .animation(CK.spring, value: navigation.settingsPage)
        .animation(CK.spring, value: navigation.preview)
        .animation(CK.spring, value: navigation.section)
        .animation(CK.quick, value: navigation.showsWorkComposer)
        .onChange(of: navigation.settingsPage) { _, _ in navigation.showsSidebarDrawer = false }
        .clipped()
        .cookieMotionPreferences()
    }

    private func sidebar(width: CGFloat) -> some View {
        Sidebar(mode: mode, companionManager: companionManager, navigation: navigation, topInset: topInset) {
            withAnimation(CK.spring) { navigation.showsSidebarDrawer = false }
        }
        .frame(width: width)
        .background(LinearGradient(colors: [Color.white.opacity(0.04), Color.white.opacity(0.02)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(alignment: .trailing) { Rectangle().fill(CK.hairline).frame(width: 0.5) }
    }

    @ViewBuilder
    private func conversation(layout: CookieHomeLayout) -> some View {
        let preview = navigation.settingsPage == nil && navigation.section == .chats && !navigation.showsWorkComposer && navigation.agentPage == nil && !lock.isLocked ? navigation.preview : nil
        HStack(spacing: 0) {
            if let preview, !layout.showsInlinePreview {
                previewPane(preview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, 12)
            } else {
                Group {
                    if let page = navigation.settingsPage {
                        CookieSettingsPage(page: page, companionManager: companionManager)
                    } else if lock.isLocked {
                        LockedView()
                    } else if navigation.agentPage != nil {
                        CookieNewAgentView(store: CookieAgentStore.shared, companionManager: companionManager, navigation: navigation)
                    } else if navigation.showsWorkComposer {
                        CookieNewWorkView(store: WorkStore.shared, navigation: navigation, draft: navigation.workDraft)
                    } else if navigation.section == .board {
                        BoardView(store: WorkStore.shared, lists: ListStore.shared, companionManager: companionManager, navigation: navigation)
                    } else if showsWorkspace, let thread = companionManager.currentThreadID {
                        workspaceConversation(thread: thread, width: layout.width)
                    } else {
                        CookieChatView(companionManager: companionManager,
                                       dictation: companionManager.buddyDictationManager,
                                       navigation: navigation,
                                       roomy: mode == .window && preview == nil && layout.conversationWidth > 700)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let preview {
                    previewPane(preview).frame(width: layout.previewWidth)
                }
            }
        }
    }

    private func workspaceConversation(thread: UUID, width: CGFloat) -> some View {
        let chatWidth = min(370, max(300, width * 0.36))
        return Group {
            if width >= 720 {
                HStack(spacing: 0) {
                    workspaceChat.frame(width: chatWidth)
                    Rectangle().fill(CK.hairline).frame(width: 0.5)
                    CookieWorkspaceView(store: workspace, manager: companionManager, thread: thread, showsComposer: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VSplitView {
                    workspaceChat.frame(minHeight: 200)
                    CookieWorkspaceView(store: workspace, manager: companionManager, thread: thread, showsComposer: false)
                        .frame(minHeight: 200)
                }
            }
        }
    }

    private var workspaceChat: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conversation").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { withAnimation(CK.quick) { navigation.showsSidebarDrawer.toggle() } } label: {
                    Label("History", systemImage: "clock")
                }.buttonStyle(.plain).cookiePointingCursor().foregroundStyle(CK.secondary)
            }.font(.system(size: 11)).padding(.horizontal, 18).frame(height: 40)
            CookieChatView(companionManager: companionManager, dictation: companionManager.buddyDictationManager,
                           navigation: navigation)
        }.background(CK.sidebar.opacity(0.35))
    }

    private func previewPane(_ attachment: CookieAttachment) -> some View {
        FilePreviewPane(attachment: attachment) {
            withAnimation(CK.spring) { navigation.preview = nil }
        }
        .padding([.trailing, .bottom], 12)
        .transition(.opacity)
    }

    private func header(showsSidebarToggle: Bool, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            if showsWorkspace && width >= 720 {
                HStack(spacing: 0) {
                    HStack(spacing: 10) {
                        sidebarToggle
                        CookieAvatar(size: 22, agent: companionManager.currentAgent, mood: companionManager.characterMood, gaze: companionManager.gazeTowardPointer)
                        Text(companionManager.currentAgent?.name ?? "Cookie").font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 18).frame(width: min(370, max(300, width * 0.36)))
                    Rectangle().fill(CK.hairline).frame(width: 0.5)
                    Text(headerTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading)
                    if mode == .notch {
                        IslandButton(symbol: "macwindow.on.rectangle", help: "Open in a window", action: popOut)
                        IslandButton(symbol: "xmark", help: "Close  (esc)", action: close).padding(.trailing, 14)
                    }
                }.frame(height: 48)
            } else if mode == .notch {
                HStack(spacing: 8) {
                    if showsSidebarToggle { sidebarToggle }
                    titleRow
                    Button {
                        _ = companionManager.ensureWorkspaceThread()
                        workspace.setSession(companionManager.currentThreadID) { $0.showing.toggle() }
                    } label: { Image(systemName: "square.stack.3d.up") }
                    .buttonStyle(.plain).cookiePointingCursor().help("Workspace")
                    Spacer(minLength: 0)
                    IslandButton(symbol: "macwindow.on.rectangle", help: "Open in a window", action: popOut)
                    IslandButton(symbol: "xmark", help: "Close  (esc)", action: close)
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
            } else {
                HStack(spacing: 0) {
                    if showsSidebarToggle { sidebarToggle.padding(.leading, 78) }
                    titleRow
                    Button {
                        _ = companionManager.ensureWorkspaceThread()
                        workspace.setSession(companionManager.currentThreadID) { $0.showing.toggle() }
                    } label: { Image(systemName: "square.stack.3d.up") }
                    .buttonStyle(.plain).cookiePointingCursor().padding(.trailing, 16).help("Workspace")
                }
                .frame(height: 52)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(CK.hairline).frame(height: 0.5) }
    }

    private var sidebarToggle: some View {
        IslandButton(symbol: "sidebar.left", help: "Chats and settings", active: navigation.showsSidebarDrawer) {
            withAnimation(CK.spring) { navigation.showsSidebarDrawer.toggle() }
        }
    }

    private var headerTitle: String {
        if let output = workspace.selected(companionManager.currentThreadID) { return output.title }
        let title = companionManager.currentThread?.title ?? "New chat"
        let words = title.split(whereSeparator: { $0.isWhitespace })
        return words.count > 7 ? words.prefix(7).joined(separator: " ") + "…" : title
    }

    @ViewBuilder
    private var titleRow: some View {
        if navigation.settingsPage == nil, !lock.isLocked, navigation.section == .chats, navigation.agentPage == nil,
           companionManager.currentThread != nil || companionManager.currentAgent?.builtIn == false {
            let thread = companionManager.currentThread
            let agent = companionManager.currentAgent
            // The agent's face and name open its profile; the title is the chat.
            Button {
                navigation.agentPage = agent.map { .profile($0.id) } ?? .new
            } label: {
                HStack(spacing: 7) {
                    CookieAvatar(size: 22, agent: agent, mood: companionManager.characterMood, gaze: companionManager.gazeTowardPointer)
                    if let agent {
                        Text(agent.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(CK.secondary).lineLimit(1)
                        Text("·").foregroundStyle(CK.tertiary)
                    }
                    Text(headerTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(thread == nil ? CK.secondary : CK.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .buttonStyle(.plain).cookiePointingCursor()
            .help(agent.map { "\($0.name) · \($0.role)" } ?? "This chat")
            .padding(.horizontal, mode == .notch ? 4 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        } else {
            Color.clear
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    let mode: CookieHomeView.Mode
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var navigation: CookieNavigation
    @ObservedObject private var lock = ChatLock.shared
    let topInset: CGFloat
    var onNavigate: () -> Void = {}

    var body: some View {
        CookieSidebarContent(
            search: $navigation.search, settingsPage: $navigation.settingsPage,
            section: Binding(get: { navigation.section }, set: { section in
                navigation.showsWorkComposer = false
                navigation.agentPage = nil
                navigation.openWork = nil
                navigation.section = section
                onNavigate()
            }),
            threads: companionManager.threads, selectedThreadID: companionManager.currentThreadID,
            selectedAgentID: companionManager.currentAgent?.id,
            isWorking: companionManager.isWorking, isLocked: lock.isLocked,
            topPadding: 0, headerHeight: mode == .notch ? 48 : 52,
            newAgent: {
                navigation.settingsPage = nil
                navigation.showsWorkComposer = false
                navigation.agentPage = .new
                onNavigate()
            },
            selectAgent: { agentID in
                navigation.showsWorkComposer = false
                navigation.agentPage = nil
                navigation.preview = nil
                navigation.settingsPage = nil
                navigation.section = .chats
                companionManager.selectAgent(agentID)
                onNavigate()
            },
            openAgent: { agentID in
                navigation.settingsPage = nil
                navigation.showsWorkComposer = false
                navigation.agentPage = .profile(agentID)
                onNavigate()
            },
            newChat: {
                navigation.showsWorkComposer = false
                navigation.agentPage = nil
                navigation.preview = nil
                navigation.section = .chats
                companionManager.newThread()
                onNavigate()
            },
            selectThread: { threadID in
                navigation.showsWorkComposer = false
                navigation.agentPage = nil
                navigation.preview = nil
                navigation.section = .chats
                companionManager.selectThread(threadID)
                onNavigate()
            },
            deleteThread: companionManager.deleteThread
        )
    }
}

/// Chats behind Touch ID (Settings → Privacy & safety).
private struct LockedView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(CK.secondary)
                .frame(width: 64, height: 64)
                .background(Circle().fill(CK.fill))
            Text("Chats are locked").font(.system(size: 16, weight: .semibold))
            Text("Unlock with Touch ID or your Mac password.")
                .font(.system(size: 12))
                .foregroundStyle(CK.secondary)
            PillButton(title: "Unlock", symbol: "touchid", primary: true) { ChatLock.shared.unlock() }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
