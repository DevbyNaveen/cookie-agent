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
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 18)
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

/// A dark, solid action button.
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
