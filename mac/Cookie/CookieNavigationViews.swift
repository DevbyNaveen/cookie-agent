import SwiftUI

struct CookieSidebarContent: View {
    @Binding var search: String
    @Binding var settingsPage: CookieNavigation.SettingsPage?
    @Binding var section: CookieNavigation.Section
    @ObservedObject private var work = WorkStore.shared
    let threads: [CookieThread]
    let selectedThreadID: UUID?
    /// The Cookie of the open chat, or the one chosen for the chat about to start.
    var selectedAgentID: UUID? = nil
    let isWorking: Bool
    let isLocked: Bool
    var topPadding: CGFloat = 0
    var headerHeight: CGFloat = 36
    var displayName = NSFullUserName()
    @ObservedObject private var account = CookieAccount.shared
    /// Make a new Cookie: the "+" beside search.
    var newAgent: () -> Void = {}
    /// A Cookie's row: its latest chat, or a new one.
    var selectAgent: (UUID) -> Void = { _ in }
    /// Open a Cookie's profile.
    var openAgent: (UUID) -> Void = { _ in }
    @ObservedObject private var agents = CookieAgentStore.shared
    let newChat: () -> Void
    let selectThread: (UUID) -> Void
    let deleteThread: (UUID) -> Void
    @FocusState private var searchFocused: Bool

    private var visibleThreads: [CookieThread] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return threads }
        return threads.filter { thread in
            thread.title.localizedCaseInsensitiveContains(query)
                || thread.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topPadding)
            header
            if settingsPage != nil {
                ScrollView {
                    CookieSettingsNavigation(selectedPage: settingsPage) { settingsPage = $0 }
                        .padding(.vertical, 14)
                }
                .scrollIndicators(.never)
            } else {
                HStack(spacing: 8) {
                    searchField
                    IslandButton(symbol: "plus", help: "New Cookie", size: 32) { newAgent() }
                        .accessibilityLabel("New Cookie")
                }
                .padding(.horizontal, 12).padding(.top, 12)
                if isLocked {
                    Spacer()
                    Label("Chats are locked", systemImage: "lock")
                        .font(.system(size: 11)).foregroundStyle(CK.secondary)
                    Spacer()
                } else {
                    VStack(spacing: 2) {
                        SectionRow(title: "Board", symbol: "rectangle.grid.1x2", count: work.items(in: .needsYou).count,
                                   selected: section == .board) { section = .board }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                    chatList
                }
            }
            profile
        }
        .foregroundStyle(CK.text)
        .cookieMotionPreferences()
    }

    private var header: some View {
        HStack(spacing: 8) {
            if settingsPage != nil {
                IslandButton(symbol: "chevron.left", help: "Back to chats", size: 25) { settingsPage = nil }
                Text("Settings").font(.system(size: 14, weight: .semibold))
            } else {
                CookieAvatar(size: 24)
                Text("Cookie").font(.system(size: 14, weight: .semibold))
            }
            Spacer(minLength: 0)
            if settingsPage == nil {
                IslandButton(symbol: "square.and.pencil", help: "New chat", size: 26, action: newChat)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: headerHeight)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                .foregroundStyle(searchFocused ? CK.secondary : CK.tertiary)
            TextField("Search chats", text: $search)
                .textFieldStyle(.plain).font(.system(size: 11.5))
                .focused($searchFocused)
                .accessibilityLabel("Search chats")
                .onKeyPress(.escape) {
                    if !search.isEmpty { search = "" } else { searchFocused = false }
                    return .handled
                }
            if !search.isEmpty {
                IslandButton(symbol: "xmark", help: "Clear search", size: 17) {
                    search = ""
                    searchFocused = true
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(searchFocused ? CK.accent.opacity(0.4) : CK.hairline, lineWidth: 0.75))
        .animation(CK.quick, value: searchFocused)
    }

    private var madeCookies: [CookieAgent] { agents.agents.filter { !$0.builtIn } }

    private var chatList: some View {
        VStack(alignment: .leading, spacing: 7) {
            if search.isEmpty, !madeCookies.isEmpty {
                Text("Your Cookies")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(CK.tertiary)
                    .padding(.horizontal, 18).padding(.top, 18)
                VStack(spacing: 2) {
                    ForEach(madeCookies) { agent in
                        AgentRow(agent: agent, selected: section == .chats && selectedAgentID == agent.id) { selectAgent(agent.id) }
                            .contextMenu {
                                Button("Profile…") { openAgent(agent.id) }
                            }
                    }
                }
                .padding(.horizontal, 8)
            }
            HStack {
                Text(search.isEmpty ? "Recent chats" : "Search results")
                Spacer()
                Text("\(visibleThreads.count)").monospacedDigit()
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(CK.tertiary)
            .padding(.horizontal, 18)
            .padding(.top, 18)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(visibleThreads) { thread in
                        ThreadRow(thread: thread, selected: section == .chats && thread.id == selectedThreadID,
                                  working: thread.id == selectedThreadID && isWorking) {
                            selectThread(thread.id)
                        }
                        .contextMenu {
                            Button("Delete Chat", role: .destructive) { deleteThread(thread.id) }
                        }
                    }
                    if visibleThreads.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: search.isEmpty ? "bubble.left" : "magnifyingglass")
                                .font(.system(size: 19, weight: .light))
                            Text(search.isEmpty ? "A little space to think." : "No matching chats")
                                .font(.system(size: 12, weight: .medium))
                            Text(search.isEmpty ? "Start a conversation with Cookie." : "Try another word or phrase.")
                                .font(.system(size: 10.5))
                        }
                        .foregroundStyle(CK.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
    }

    private var profile: some View {
        HStack(spacing: 8) {
            Button { settingsPage = .account } label: {
                HStack(spacing: 9) {
                    Circle().fill(LinearGradient(colors: [CK.accent.opacity(0.5), CK.accent.opacity(0.2)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                        .overlay(Text(initials).font(.system(size: 11, weight: .semibold)))
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName).font(.system(size: 12, weight: .medium)).foregroundStyle(CK.text)
                        Text(account.isSignedIn ? "Signed in to Enkeon" : "Not signed in").font(.system(size: 10)).foregroundStyle(CK.tertiary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).cookiePointingCursor().help("Account")
            IslandButton(symbol: "gearshape", help: "Settings", size: 28, active: settingsPage != nil) {
                settingsPage = settingsPage == nil ? .general : nil
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(CK.hairline).frame(height: 0.5).padding(.horizontal, 14) }
    }

    private var initials: String {
        displayName.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}

struct CookieSettingsNavigation: View {
    let selectedPage: CookieNavigation.SettingsPage?
    let selectPage: (CookieNavigation.SettingsPage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Personal", pages: [.account, .general])
            section("Your companion", pages: [.voice, .shortcuts, .cursor])
            section("Trust & access", pages: [.privacy, .permissions, .connectors])
            navigationItem(.about)
        }
        .padding(.horizontal, 8)
    }

    private func section(_ title: String, pages: [CookieNavigation.SettingsPage]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(CK.tertiary)
                .padding(.horizontal, 11).padding(.bottom, 3)
            ForEach(pages) { page in navigationItem(page) }
        }
    }

    private func navigationItem(_ page: CookieNavigation.SettingsPage) -> some View {
        CookieSettingsNavItem(page: page, selected: selectedPage == page) { selectPage(page) }
    }
}

private struct CookieSettingsNavItem: View {
    let page: CookieNavigation.SettingsPage
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? CK.accent : CK.secondary)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7).fill(selected ? CK.accent.opacity(0.12) : CK.fill))
                Text(page.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? CK.text : CK.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 36)
            .background(CookieSelectionSurface(selected: selected, hovering: hovering))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain).cookiePointingCursor()
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(CK.quick, value: hovering)
        .animation(CK.quick, value: selected)
    }
}

private struct CookieSelectionSurface: View {
    let selected: Bool
    let hovering: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(LinearGradient(colors: selected
                ? [Color.white.opacity(0.10), Color.white.opacity(0.045)]
                : [Color.white.opacity(hovering ? 0.05 : 0), Color.white.opacity(hovering ? 0.035 : 0)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(selected ? 0.075 : 0), lineWidth: 0.5))
    }
}

/// Today and Work, above the chats.
/// One of the person's Cookies in the sidebar: face, name, role.
private struct AgentRow: View {
    let agent: CookieAgent
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                CookieAvatar(size: 26, agent: agent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(CK.text).lineLimit(1)
                    Text(agent.role).font(.system(size: 10.5)).foregroundStyle(CK.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 40)
            .background(CookieSelectionSurface(selected: selected, hovering: hovering))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain).cookiePointingCursor()
        .onHover { hovering = $0 }
        .help("\(agent.name) · \(agent.role)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(CK.quick, value: hovering)
    }
}

private struct SectionRow: View {
    let title: String
    let symbol: String
    let count: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 18)
                    .foregroundStyle(selected ? CK.accent : CK.secondary)
                Text(title).font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 0)
                if count > 0 { Text("\(count)").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(CK.tertiary) }
            }
            .foregroundStyle(CK.text)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? CK.fillHover : (hovering ? CK.fill : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ThreadRow: View {
    let thread: CookieThread
    var selected = false
    var working = false
    var compact = false
    let action: () -> Void
    @ObservedObject private var agents = CookieAgentStore.shared
    @State private var hovering = false

    var body: some View {
        let agent = agents.agent(thread.agentID)
        Button(action: action) {
            HStack(spacing: 10) {
                CookieAvatar(size: 32, agent: agent, mood: working ? .thinking : .idle)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(thread.title).font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(CK.text).lineLimit(1)
                        Spacer(minLength: 0)
                        if compact {
                            Text(working ? "Now" : CookieTime.short(thread.updatedAt))
                                .font(.system(size: 10)).foregroundStyle(working ? CK.accent : CK.tertiary)
                                .fixedSize()
                        }
                    }
                    HStack(spacing: 4) {
                        if working {
                            Circle().fill(CK.accent).frame(width: 4, height: 4)
                        }
                        if let agent {
                            Text(agent.name).font(.system(size: 11, weight: .medium)).foregroundStyle(CK.secondary).lineLimit(1).fixedSize()
                            Text("·").font(.system(size: 11)).foregroundStyle(CK.tertiary)
                        }
                        Text(working ? "Working…" : thread.preview)
                            .font(.system(size: 11)).foregroundStyle(CK.secondary).lineLimit(1)
                    }
                }
                if compact, let attachment = thread.latestAttachment {
                    FileThumbnail(attachment: attachment, size: 28)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: compact ? 52 : 58)
            .background(CookieSelectionSurface(selected: selected, hovering: hovering))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain).cookiePointingCursor()
        .onHover { hovering = $0 }
        .help("\(thread.title) · \(CookieTime.separator(thread.updatedAt))")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(CK.quick, value: hovering)
        .animation(CK.quick, value: selected)
    }
}
