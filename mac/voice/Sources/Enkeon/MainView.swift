import Collaboration
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home, notes, meetings, dictionary, snippets, styles, context, connections, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .notes: return "Notes"
        case .meetings: return "Meetings"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .styles: return "Styles"
        case .context: return "Context"
        case .connections: return "Connections"
        case .settings: return "Settings"
        }
    }

    /// The Phosphor icon, as in the web Console.
    var icon: String {
        switch self {
        case .home: return "House"
        case .notes: return "Brain"
        case .meetings: return "ChatCircleText"
        case .dictionary: return "BookOpenText"
        case .snippets: return "Scissors"
        case .styles: return "TextAa"
        case .context: return "GitDiff"
        case .connections: return "Plugs"
        case .settings: return "GearSix"
        }
    }
}

/// The Console's split shell under a toolbar row: the traffic lights' row carries the sidebar
/// toggle and the app's state, the rail sits on the underlay, the workspace floats beside it.
struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var railOpen = true
    @State private var brandPulse = 0
    @State private var brandStarted: Date?

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(railOpen: $railOpen)
            HStack(alignment: .top, spacing: 8) {
                Rail(page: $model.page, compact: !railOpen, onBrandClick: playBrandMotion)
                workspace
            }
            .padding([.bottom, .trailing], 10)
        }
        .animation(Theme.settle, value: railOpen)
        .background(SidebarMaterial())
        .ignoresSafeArea()
        .frame(minWidth: 820, minHeight: 560)
        .environment(\.brandPulse, brandPulse)
        .overlayPreferenceValue(BrandOrigin.self) { anchor in
            if let anchor, let started = brandStarted {
                GeometryReader { geometry in
                    let rect = geometry[anchor]
                    BrandRipple(started: started, origin: CGPoint(x: rect.midX, y: rect.midY))
                }
                .clipped()
                .allowsHitTesting(false)
            }
        }
        .task(id: brandPulse) {
            guard brandPulse > 0 else { return }
            do { try await Task.sleep(for: .milliseconds(850)) } catch { return }
            brandStarted = nil
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView().environmentObject(model)
        }
        .sheet(isPresented: $model.meetings.showSetup) { MeetingSetupView().environmentObject(model) }
    }

    private func playBrandMotion() {
        guard brandStarted == nil else { return }
        brandStarted = Date()
        brandPulse += 1
    }

    private var workspace: some View {
        ZStack {
            switch model.page {
            case .home: HomeView(openDictionary: { model.page = .dictionary }).transition(.opacity)
            case .notes: NotesView().transition(.opacity)
            case .meetings: MeetingsView().transition(.opacity)
            case .dictionary: DictionaryView().transition(.opacity)
            case .snippets: SnippetsView().transition(.opacity)
            case .styles: StylesView().transition(.opacity)
            case .context: ContextView().transition(.opacity)
            case .connections: ConnectionsView().transition(.opacity)
            case .settings: SettingsView().transition(.opacity)
            }
        }
        .animation(Theme.settle, value: model.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        // Borderless: the step from the sidebar material to the workspace is the only edge; a soft shadow lifts it.
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 12,
                                          topTrailingRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 2)
    }
}

/// The traffic lights' row: their height, their centre line.
private struct Toolbar: View {
    @EnvironmentObject private var model: AppModel
    @Binding var railOpen: Bool

    var body: some View {
        HStack(spacing: 8) {
            // The traffic lights end ~72 pt in.
            Color.clear.frame(width: 70)
            ToolbarButton(icon: "SidebarSimple", label: railOpen ? "Collapse sidebar" : "Expand sidebar") { railOpen.toggle() }
            Spacer()
            StatusPill()
            ToolbarButton(icon: "ArrowSquareOut", label: "Open Console") { model.openConsole() }
        }
        .padding(.trailing, 12)
        .frame(height: 40)
    }
}

private struct ToolbarButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            PhosphorIcon(name: icon, size: 16)
                .foregroundStyle(hovering ? Theme.text : Theme.secondary)
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.text.opacity(hovering ? 0.06 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// What dictation is doing right now, from the engine.
private struct StatusPill: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button { if !model.isSetUp { model.showOnboarding = true } } label: {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                if model.isSetUp, case .idle = model.dictation.phase {
                    Text(model.fnKeyIsFree ? "fn" : "⌃⌘").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Theme.text.opacity(0.05), in: Capsule())
            .contentTransition(.opacity)
        }
        .buttonStyle(.plain)
        .animation(Theme.settle, value: model.dictation.phase)
    }

    private var text: String {
        switch model.dictation.phase {
        case .listening: return model.dictation.isMicrophoneReady ? "Listening" : "Starting microphone"
        case .finishing: return "Writing"
        case .done(_, let success): return success ? (model.dictation.toMemory ? "Saved" : "Inserted") : "Kept"
        case .idle: return model.isSetUp ? "Ready" : "Finish setup"
        }
    }

    private var color: Color {
        switch model.dictation.phase {
        case .listening, .finishing: return Theme.live
        case .done(_, let success): return success ? Theme.live : Theme.warning
        case .idle: return model.isSetUp ? Theme.live : Theme.warning
        }
    }
}

/// The left rail: no edge, no background of its own.
struct Rail: View {
    @EnvironmentObject private var model: AppModel
    @Binding var page: Page
    /// Collapsed: icons only, each with its name on hover.
    var compact = false
    var onBrandClick: () -> Void = {}
    @State private var hovered: Page?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onBrandClick) {
            HStack(spacing: 9) {
                Image(nsImage: BrandMark.color).resizable().interpolation(.high).frame(width: 28, height: 28)
                    .anchorPreference(key: BrandOrigin.self, value: .bounds) { $0 }
                if !compact {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("Enkeon").font(.system(size: 18, weight: .semibold)).tracking(-0.4).foregroundStyle(Theme.text)
                        Text("Voice").font(.system(size: 13, weight: .medium, design: .serif)).italic().foregroundStyle(Theme.accent)
                    }
                    .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            }
            .buttonStyle(BrandButtonStyle())
            .accessibilityLabel("Enkeon")
            .accessibilityHint("Play a brief ripple")
            .padding(.horizontal, compact ? 11 : 12)
            .padding(.top, 10)
            .padding(.bottom, 20)

            ForEach(Page.allCases) { item in
                Button { page = item } label: {
                    HStack(spacing: 12) {
                        Group {
                            if item == .notes { MemoryCardsIcon().frame(width: 18, height: 18) }
                            else { PhosphorIcon(name: item.icon, weight: page == item ? .fill : .regular, size: 18) }
                        }.frame(width: 20)
                        if !compact {
                            Text(item.title).font(.system(size: 15, weight: page == item ? .semibold : .regular))
                                .lineLimit(1)
                                .transition(.opacity)
                            Spacer(minLength: 0)
                        }
                    }
                    .foregroundStyle(page == item ? Theme.accent : Theme.text.opacity(0.85))
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(page == item ? Theme.accent.opacity(0.14) : (hovered == item ? Theme.text.opacity(0.05) : .clear))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(compact ? item.title : "")
                .accessibilityLabel(item.title)
                .onHover { hovered = $0 ? item : (hovered == item ? nil : hovered) }
            }

            Spacer()

            AccountCard(compact: compact)
        }
        .padding(.leading, 10)
        .frame(width: compact ? 54 : 228)
        .animation(.easeOut(duration: 0.14), value: hovered)
    }
}

private struct BrandButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1, anchor: .leading)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Who's using Enkeon on this Mac, at the foot of the rail: your Mac account's picture and name,
/// and whether Enkeon memory is connected. Click for Connections, the Console, sign in or out.
private struct AccountCard: View {
    @EnvironmentObject private var model: AppModel
    var compact = false
    @State private var hovering = false

    var body: some View {
        // A plain button opening a native menu: a SwiftUI Menu redraws its label as a menu button,
        // which ignores the avatar's size and clip.
        Button(action: showMenu) {
            HStack(spacing: 10) {
                Avatar(size: compact ? 30 : 34, signedIn: model.account.isSignedIn)
                if !compact {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(status).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    PhosphorIcon(name: "ArrowsDownUp", size: 13).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(compact ? 6 : 10)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .background(Theme.surface.opacity(hovering ? 1 : 0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(compact ? "\(Self.name) · \(status)" : "")
        .accessibilityLabel("\(Self.name), \(status)")
    }

    static let name = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()

    private func showMenu() {
        let menu = NSMenu()
        let model = model
        menu.addItem(MenuAction.item("Connections") { model.page = .connections })
        menu.addItem(MenuAction.item("Open Console") { model.openConsole() })
        menu.addItem(.separator())
        if model.account.isSignedIn {
            menu.addItem(MenuAction.item("Sign out of Enkeon") { model.account.signOut() })
        } else {
            menu.addItem(MenuAction.item("Sign in to Enkeon") { model.account.signIn() })
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private var status: String {
        switch model.account.phase {
        case .signedIn: return "Connected to Enkeon"
        case .waitingForBrowser: return "Signing in…"
        case .signedOut: return "Not connected"
        case .failed: return "Sign-in failed"
        }
    }
}

/// Your Mac account picture in a circle (initials when there's none), with a dot for Enkeon.
private struct Avatar: View {
    let size: CGFloat
    let signedIn: Bool

    static let picture: NSImage? = CBUserIdentity(posixUID: getuid(), authority: .local())?.image

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let picture = Self.picture {
                    Image(nsImage: picture).resizable().interpolation(.high).scaledToFill()
                } else {
                    Text(initials).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            Circle().fill(signedIn ? Theme.live : Theme.tertiary)
                .frame(width: size * 0.3, height: size * 0.3)
                .overlay(Circle().stroke(Theme.background, lineWidth: 2))
        }
    }

    private var initials: String {
        AccountCard.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// A menu item that runs a closure.
private final class MenuAction: NSObject {
    private let run: () -> Void
    private init(_ run: @escaping () -> Void) { self.run = run }
    @objc private func fire() { run() }

    static func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let target = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
        item.target = target
        item.representedObject = target  // the item holds its target
        return item
    }
}
