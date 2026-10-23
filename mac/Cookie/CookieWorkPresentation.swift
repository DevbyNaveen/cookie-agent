import SwiftUI

/// Navigation owns the draft, so folding the notch or changing pages cannot erase it.
@MainActor
final class CookieWorkDraft: ObservableObject {
    @Published var title = ""
    @Published var nextStep = ""
    @Published var person = ""
    @Published var outcome = ""
    @Published var hasDueDate = false
    @Published var dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()

    var canCreate: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasContent: Bool { canCreate || !nextStep.isEmpty || !person.isEmpty || !outcome.isEmpty || hasDueDate }

    @discardableResult
    func create(in store: WorkStore) -> WorkItem? {
        guard canCreate else { return nil }
        let item = store.add(title: title, nextStep: nextStep, outcome: outcome, to: person,
                             due: hasDueDate ? dueDate : nil)
        title = ""
        nextStep = ""
        person = ""
        outcome = ""
        hasDueDate = false
        dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return item
    }
}

struct CookieWorkLayout {
    let width: CGFloat
    var padding: CGFloat { width < 480 ? 20 : 28 }
    var contentWidth: CGFloat { max(0, width - padding * 2) }
}

enum CookieWorkSort {
    static func matching(_ items: [WorkItem], query: String) -> [WorkItem] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return items.filter { item in
            let text = [item.title, item.nextStep, item.to, item.outcome, item.column.title].joined(separator: " ")
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
    }
}

extension WorkColumn {
    var tint: Color {
        switch self {
        case .needsYou: return CK.accent
        case .cookie: return Color(red: 0.48, green: 0.77, blue: 0.63)
        case .waiting: return Color(red: 0.88, green: 0.68, blue: 0.40)
        case .done: return Color(red: 0.61, green: 0.66, blue: 0.73)
        }
    }
    var symbol: String {
        switch self {
        case .needsYou: return "circle.inset.filled"
        case .cookie: return "sparkles"
        case .waiting: return "clock"
        case .done: return "checkmark.circle"
        }
    }
    var emptyTitle: String {
        switch self {
        case .needsYou: return "A little breathing room"
        case .cookie: return "Ready for the next step"
        case .waiting: return "No loose ends here"
        case .done: return "Good things take a first step"
        }
    }
    var emptyDetail: String {
        switch self {
        case .needsYou: return "Your next decisions will land here."
        case .cookie: return "Open a piece of work and ask Cookie to help."
        case .waiting: return "Keep track of what’s with someone else."
        case .done: return "Finished work stays here, out of your way."
        }
    }
}

struct WorkAvatar: View {
    let item: WorkItem
    var size: CGFloat = 30
    var body: some View { CookieAvatar(size: size) }
}

struct WorkButtonStyle: ButtonStyle {
    var primary = false
    var quiet = false
    func makeBody(configuration: Configuration) -> some View {
        WorkButtonBody(configuration: configuration, primary: primary, quiet: quiet)
    }
    private struct WorkButtonBody: View {
        let configuration: Configuration
        let primary: Bool
        let quiet: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 13).frame(minHeight: 32)
                .foregroundStyle(primary ? Color.white : hovering ? CK.text : CK.secondary)
                .background(primary ? CK.accent.opacity(configuration.isPressed ? 0.7 : hovering ? 0.9 : 1)
                            : Color.white.opacity(configuration.isPressed ? 0.10 : hovering ? 0.08 : quiet ? 0 : 0.045),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(enabled ? 1 : 0.38)
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onHover { hovering = $0 }
                .cookiePointingCursor()
                .animation(CK.quick, value: hovering)
        }
    }
}

struct WorkSectionHeading: View {
    let title: String
    var count: Int?
    var body: some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(CK.text)
            if let count { Text("\(count)").monospacedDigit().foregroundStyle(CK.tertiary) }
        }
        .font(.system(size: 12, weight: .semibold))
    }
}

struct WorkStageLabel: View {
    let column: WorkColumn
    var body: some View {
        Label(column.title, systemImage: column.symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(column.tint)
            .lineLimit(1)
    }
}

struct WorkStageMenu: View {
    let item: WorkItem
    let store: WorkStore
    var body: some View {
        CookieMenu("Stage for \(item.title): \(item.column.title)", items: WorkColumn.allCases.map { column in
            CookieMenuItem(column.title, symbol: column.symbol, tint: column.tint, checked: item.column == column) {
                store.move(item.id, to: column)
            }
        }) {
            HStack(spacing: 5) {
                WorkStageLabel(column: item.column)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(CK.tertiary)
            }
            .padding(.horizontal, 9).frame(height: 28)
            .background(item.column.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .fixedSize()
        }
        .help("Change stage")
    }
}

struct WorkEmptyState: View {
    var symbol = "sparkles"
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 24, weight: .light)).foregroundStyle(CK.tertiary)
                .padding(.bottom, 4)
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(CK.text)
            Text(detail).font(.system(size: 12.5)).foregroundStyle(CK.secondary)
                .frame(maxWidth: 300).fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity).padding(.vertical, 46)
    }
}

struct WorkField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(CK.secondary)
            content.font(.system(size: 13)).textFieldStyle(.plain)
                .padding(13).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
