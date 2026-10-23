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

    var body: some View {
        GeometryReader { geometry in
            let layout = CookieHomeLayout(width: geometry.size.width)
            HStack(spacing: 0) {
                if layout.showsSidebar {
                    sidebar(width: layout.sidebarWidth)
                }
                VStack(spacing: 0) {
                    header(showsSidebarToggle: !layout.showsSidebar)
                    conversation(layout: layout)
                }
            }
            .overlay(alignment: .leading) {
                if !layout.showsSidebar && navigation.showsSidebarDrawer {
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

    private func previewPane(_ attachment: CookieAttachment) -> some View {
        FilePreviewPane(attachment: attachment) {
            withAnimation(CK.spring) { navigation.preview = nil }
        }
        .padding([.trailing, .bottom], 12)
        .transition(.opacity)
    }

    /// In the notch the top strip belongs to the camera: only the window
    /// buttons sit there (right of the notch). The chat's name gets its own
    /// row underneath. In the window there is no notch, so one row holds both.
    private func header(showsSidebarToggle: Bool) -> some View {
        VStack(spacing: 0) {
            if mode == .notch {
                HStack(spacing: 8) {
                    if showsSidebarToggle { sidebarToggle }
                    Spacer()
                    IslandButton(symbol: "macwindow.on.rectangle", help: "Open in a window", action: popOut)
                    IslandButton(symbol: "xmark", help: "Close  (esc)", action: close)
                }
                .padding(.horizontal, 14)
                .frame(height: max(topInset, 30) + 6)
                if navigation.settingsPage == nil && navigation.section == .chats && !navigation.showsWorkComposer && navigation.agentPage == nil {
                    titleRow.frame(height: 30)
                }
            } else {
                HStack(spacing: 0) {
                    if showsSidebarToggle { sidebarToggle.padding(.leading, 78) }
                    titleRow
                }
                .frame(height: 52)
            }
        }
    }

    private var sidebarToggle: some View {
        IslandButton(symbol: "sidebar.left", help: "Chats and settings", active: navigation.showsSidebarDrawer) {
            withAnimation(CK.spring) { navigation.showsSidebarDrawer.toggle() }
        }
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
                    Text(thread?.title ?? "New chat")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(thread == nil ? CK.secondary : CK.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .buttonStyle(.plain).cookiePointingCursor()
            .help(agent.map { "\($0.name) · \($0.role)" } ?? "This chat")
            .padding(.horizontal, 48)
            .frame(maxWidth: .infinity)
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
            topPadding: mode == .window ? 30 : 0, headerHeight: max(topInset, 36),
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
