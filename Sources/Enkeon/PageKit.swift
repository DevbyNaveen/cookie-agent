import AppKit
import SwiftUI

// The grammar every page (but Home and Settings) is built from: a title with its actions, tabs, a hero
// that says what the page is for, then the page's own content — a list, cards or tiles — on one
// readable column. Each page composes these its own way.

/// The page's column: centred, readable, the header fixed and the content filling the rest.
struct PageColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) { content }
            .frame(maxWidth: 940, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 30)
            .padding(.top, 30)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Title on the left, the page's actions on the right.
struct PageTitle<Actions: View>: View {
    let title: String
    var badge: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.6).foregroundStyle(Theme.text)
            if let badge {
                Text(badge).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
            }
            Spacer()
            actions
        }
    }
}

extension PageTitle where Actions == EmptyView {
    init(_ title: String, badge: String? = nil) { self.init(title: title, badge: badge) { EmptyView() } }
}

/// A plain button for the title bar: light fill, dark label.
struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Theme.text.opacity(configuration.isPressed ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Underlined tabs, with room on the right for search and other tools.
struct TabStrip<Tab: Hashable, Tools: View>: View {
    let tabs: [(Tab, String)]
    @Binding var selection: Tab
    @ViewBuilder var tools: Tools
    @Namespace private var underline

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                ForEach(tabs, id: \.0) { tab, title in
                    Button { withAnimation(Theme.settle) { selection = tab } } label: {
                        Text(title)
                            .font(.system(size: 14, weight: selection == tab ? .semibold : .regular))
                            .foregroundStyle(selection == tab ? Theme.text : Theme.secondary)
                            .padding(.bottom, 10)
                            .overlay(alignment: .bottom) {
                                if selection == tab {
                                    Capsule().fill(Theme.text).frame(height: 2).matchedGeometryEffect(id: "underline", in: underline)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                tools.padding(.bottom, 10)
            }
        }
    }
}

/// The hero: an atmosphere in Enkeon's colors, a serif headline, what the page is for, examples and one action.
struct HeroBanner<Content: View>: View {
    let headline: Text
    let message: String
    var dismissKey: String? = nil
    @ViewBuilder var content: Content
    @State private var dismissed = false

    var body: some View {
        if !dismissed {
            VStack(alignment: .leading, spacing: 14) {
                headline
                    .font(.system(size: 30, weight: .regular, design: .serif))
                    .tracking(-0.6)
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
                content
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { Atmosphere() }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if let dismissKey {
                    Button {
                        withAnimation(Theme.settle) { dismissed = true }
                        UserDefaults.standard.set(true, forKey: dismissKey)
                    } label: {
                        PhosphorIcon(name: "X", size: 13).foregroundStyle(.white.opacity(0.85))
                            .frame(width: 26, height: 26).background(.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                    .help("Hide")
                }
            }
            .onAppear { dismissed = dismissKey.map { UserDefaults.standard.bool(forKey: $0) } ?? false }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }
}

/// A slow mesh of Enkeon teal, deep ink and a warm amber glow — light through frosted glass.
struct Atmosphere: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = Float(context.date.timeIntervalSinceReferenceDate)
            let drift = (sin(t * 0.18) * 0.08, cos(t * 0.14) * 0.07)
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.45 + drift.0, 0.5 + drift.1], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: [
                Color(hex: 0x0F2A35), Color(hex: 0x1F5468), Color(hex: 0x3B2A1E),
                Color(hex: 0x173C4A), Color(hex: 0x2F7A9C), Color(hex: 0x8A5A32),
                Color(hex: 0x0B1B22), Color(hex: 0x24485A), Color(hex: 0x5A3B24),
            ])
        }
        .overlay(LinearGradient(colors: [.black.opacity(0.25), .clear], startPoint: .leading, endPoint: .trailing))
    }
}

/// A chip on a hero: frosted, white text.
struct HeroChip: View {
    let text: String
    var italic = false

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .italic(italic)
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The hero's action: a dark, solid button over the atmosphere.
struct HeroButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(.black.opacity(configuration.isPressed ? 0.5 : 0.38), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Rows in one rounded container, no lines: space and a hover fill tell them apart; scrolls when long.
struct ListBox<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(items) { row($0) }
            }
            .padding(.vertical, 6)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .scrollIndicators(.automatic)
    }
}

/// Nothing to show yet: an icon, a line, and what to do.
struct EmptyState<Action: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if icon == "MemoryCards" { MemoryCardsIcon().frame(width: 28, height: 28) }
                else { PhosphorIcon(name: icon, size: 28) }
            }.foregroundStyle(Theme.tertiary)
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            Text(message).font(.system(size: 13)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            action.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 30)
    }
}

extension EmptyState where Action == EmptyView {
    init(icon: String, title: String, message: String) { self.init(icon: icon, title: title, message: message) { EmptyView() } }
}

/// A search field that opens from a magnifier.
struct SearchToggle: View {
    @Binding var query: String
    @State private var open = false

    var body: some View {
        HStack(spacing: 6) {
            if open {
                TextField("Search", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 13)).frame(width: 160)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            Button {
                withAnimation(Theme.settle) { open.toggle() }
                if !open { query = "" }
            } label: {
                PhosphorIcon(name: open ? "X" : "MagnifyingGlass", size: 16).foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help(open ? "Close search" : "Search")
        }
    }
}
