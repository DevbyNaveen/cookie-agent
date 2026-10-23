//
//  CookieUI.swift
//  Cookie
//
//  Cookie's look: black glass that grows out of the notch, SF Pro, one blue.
//  Shared pieces every Cookie screen is built from.
//

import AppKit
import SwiftUI

enum CK {
    static let accent = DS.Colors.overlayCursorBlue
    /// Graphite, not pure black — the open island and the window.
    static let island = Color(white: 0.12)
    static let text = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.36)
    static let hairline = Color.white.opacity(0.08)
    static let fill = Color.white.opacity(0.06)
    static let fillHover = Color.white.opacity(0.10)
    static let selected = Color.white.opacity(0.12)
    static let sidebar = Color.white.opacity(0.035)
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.84)
    static let quick = Animation.easeOut(duration: 0.16)

    enum Key {
        static let showInDock = "cookie.showInDock"
        static let showInRecordings = "cookie.showInRecordings"
        static let peekOnHover = "cookie.peekOnHover"
        static let sounds = "cookie.sounds"
    }
}

/// Which screen the Home surface shows. Shared by the notch and the window,
/// and kept outside the views so it survives the island folding away.
@MainActor
final class CookieNavigation: ObservableObject {
    enum SettingsPage: String, CaseIterable, Identifiable {
        case account, general, privacy, permissions, voice, shortcuts, cursor, connectors, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .account: return "Account"
            case .general: return "General"
            case .privacy: return "Privacy & safety"
            case .permissions: return "Permissions"
            case .voice: return "Voice"
            case .shortcuts: return "Shortcuts"
            case .cursor: return "Cursor"
            case .connectors: return "Connected apps"
            case .about: return "About"
            }
        }
        var symbol: String {
            switch self {
            case .account: return "person.crop.circle"
            case .general: return "gearshape"
            case .privacy: return "hand.raised"
            case .permissions: return "lock.shield"
            case .voice: return "waveform"
            case .shortcuts: return "command"
            case .cursor: return "cursorarrow"
            case .connectors: return "square.grid.2x2"
            case .about: return "info.circle"
            }
        }
    }

    enum Section: String { case board, chats }
    /// Making a new Cookie, or one Cookie's profile. Sits on top of the section like the work composer.
    enum AgentPage: Equatable { case new, profile(UUID) }

    /// Where the window is: the Board, Agents or a chat. Settings sit on top of any.
    @Published var section: Section = .chats
    /// The work item open on the Board; nil shows the feed.
    @Published var openWork: UUID?
    @Published var agentPage: AgentPage?
    let agentCreation = CookieCreationSession()
    let workDraft = CookieWorkDraft()
    @Published var showsWorkComposer = false
    @Published var settingsPage: SettingsPage?
    @Published var preview: CookieAttachment?
    @Published var search = ""
    @Published var showsShortcuts = false
    @Published var peekDraft = ""
    @Published var showsSidebarDrawer = false
}

/// Small Cookie for strips and labels: chips, no face.
struct CookieMark: View {
    var size: CGFloat = 12
    var body: some View { ClayCookie(size: size * 1.55, face: false, alive: false) }
}

/// Cookie herself by default; a Cookie the person made has its own creature, the same one every time.
struct CookieAvatar: View {
    var size: CGFloat = 32
    var agent: CookieAgent? = nil
    var mood: ClayCookie.Mood = .idle
    var animatesIdle = false
    var isEngaged = false
    var gaze: CGFloat? = nil

    var body: some View {
        ChatCompanionAvatar(size: size, threadID: agent.flatMap { $0.builtIn ? nil : $0.id },
                            mood: mood, animatesIdle: animatesIdle, isEngaged: isEngaged, gaze: gaze)
    }
}

/// Round icon button used in island strips and headers.
struct IslandButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 26
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(active ? CK.accent : CK.text)
                .frame(width: size, height: size)
                .background(Circle().fill(hovering || active ? CK.fillHover : CK.fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .cookiePointingCursor()
        .animation(CK.quick, value: hovering)
    }
}

/// A key as it looks on the keyboard: ⌃, ⌥, fn.
struct KeyCap: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(CK.secondary)
            .frame(minWidth: 18)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(CK.fill))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(CK.hairline))
    }
}

struct TalkKeys: View {
    var body: some View {
        HStack(spacing: 3) { KeyCap(label: "⌃"); KeyCap(label: "⌥") }
    }
}

/// Capsule button. Primary = blue fill; otherwise quiet glass.
struct PillButton: View {
    let title: String
    var symbol: String?
    var primary = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(primary ? Color.white : CK.text)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(primary ? CK.accent.opacity(hovering ? 1 : 0.9) : (hovering ? CK.fillHover : CK.fill)))
            .overlay(Capsule().strokeBorder(primary ? Color.white.opacity(0.18) : CK.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .cookiePointingCursor()
        .animation(CK.quick, value: hovering)
    }
}

/// Three soft dots that breathe while Cookie works.
struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(0.3 + 0.55 * (sin(t * 5 - Double(i) * 0.75) + 1) / 2))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .frame(height: 12)
    }
}

/// File icon or image thumbnail.
struct FileThumbnail: View {
    let attachment: CookieAttachment
    var size: CGFloat = 34

    var body: some View {
        Group {
            if attachment.isImage, let image = NSImage(contentsOf: attachment.url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: attachment.path)).resizable().aspectRatio(contentMode: .fit).padding(2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(CK.hairline))
    }
}

extension View {
    func cookiePointingCursor() -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }

    func cookieMotionPreferences() -> some View {
        modifier(CookieMotionPreferences())
    }

    /// Inset-grouped card, like System Settings.
    func cookieCard() -> some View {
        self
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(CK.fill))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(CK.hairline))
    }
}

private struct CookieMotionPreferences: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .transaction { transaction in
                if reduceMotion {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
            .symbolEffectsRemoved(reduceMotion)
    }
}
