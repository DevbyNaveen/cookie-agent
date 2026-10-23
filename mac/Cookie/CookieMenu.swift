//
//  CookieMenu.swift
//  Cookie
//
//  Cookie's own dropdown: the same dark card, rows and checkmark everywhere
//  a choice opens (stages, lists, settings), instead of the system menu.
//

import SwiftUI

struct CookieMenuItem: Identifiable {
    let id: String
    let title: String
    var symbol: String?
    var tint: Color?
    var checked = false
    var destructive = false
    /// Draws a line above this row, to set it apart from the ones before.
    var separated = false
    let action: () -> Void

    init(_ title: String, symbol: String? = nil, tint: Color? = nil, checked: Bool = false,
         destructive: Bool = false, separated: Bool = false, id: String? = nil, action: @escaping () -> Void) {
        self.id = id ?? title
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.checked = checked
        self.destructive = destructive
        self.separated = separated
        self.action = action
    }
}

struct CookieMenu<Label: View>: View {
    let items: [CookieMenuItem]
    var accessibilityLabel: String
    @ViewBuilder let label: () -> Label
    @State private var shown = false

    init(_ accessibilityLabel: String, items: [CookieMenuItem], @ViewBuilder label: @escaping () -> Label) {
        self.accessibilityLabel = accessibilityLabel
        self.items = items
        self.label = label
    }

    var body: some View {
        Button { shown.toggle() } label: { label() }
            .buttonStyle(.plain)
            .cookiePointingCursor()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Opens a list of choices")
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                CookieMenuList(items: items) { shown = false }
            }
    }
}

/// The common label: current value, then a small chevron, on a quiet fill.
struct CookieMenuLabel: View {
    let title: String
    var symbol: String?
    var tint: Color?
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).foregroundStyle(tint ?? CK.secondary) }
            Text(title).foregroundStyle(tint ?? CK.text).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(CK.tertiary)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10).frame(height: 30)
        .background((tint ?? Color.white).opacity(tint == nil ? 0.05 : 0.08), in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
    }
}

struct CookieMenuList: View {
    let items: [CookieMenuItem]
    let dismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(items) { item in
                    if item.separated { Divider().overlay(CK.hairline).padding(.vertical, 4).padding(.horizontal, 6) }
                    CookieMenuRow(item: item) {
                        dismiss()
                        item.action()
                    }
                }
            }
            .padding(6)
        }
        .scrollIndicators(.never)
        .frame(minWidth: 200, maxWidth: 320)
        .frame(maxHeight: 340)
        .fixedSize(horizontal: true, vertical: items.count <= 9)
        .background(CK.island)
        .foregroundStyle(CK.text)
        .environment(\.colorScheme, .dark)
    }
}

private struct CookieMenuRow: View {
    let item: CookieMenuItem
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 9) {
                if let symbol = item.symbol {
                    Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(item.destructive ? Color.red.opacity(0.9) : item.tint ?? CK.secondary)
                        .frame(width: 16)
                }
                Text(item.title).font(.system(size: 12.5))
                    .foregroundStyle(item.destructive ? Color.red.opacity(0.95) : CK.text).lineLimit(1)
                Spacer(minLength: 16)
                if item.checked {
                    Image(systemName: "checkmark").font(.system(size: 10.5, weight: .bold)).foregroundStyle(CK.accent)
                }
            }
            .padding(.horizontal, 9).frame(height: 30)
            .background(hovering ? CK.fillHover : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .cookiePointingCursor()
        .accessibilityAddTraits(item.checked ? .isSelected : [])
    }
}

/// A picker in Cookie's menu: one value from a few, shown as the current choice.
struct CookieChoice: View {
    let title: String
    @Binding var selection: String
    let options: [(value: String, title: String)]

    init(_ title: String, selection: Binding<String>, options: [(value: String, title: String)]) {
        self.title = title
        _selection = selection
        self.options = options
    }

    var body: some View {
        let current = options.first { $0.value == selection }?.title ?? options.first?.title ?? ""
        CookieMenu("\(title): \(current)", items: options.map { option in
            CookieMenuItem(option.title, checked: option.value == selection, id: option.value) { selection = option.value }
        }) {
            CookieMenuLabel(title: current)
        }
    }
}
