import AppKit
import EnkeonVoiceKit
import SwiftUI

/// One change on the Context page: what kind, what was heard (struck), what was typed.
struct ChangeRow: View {
    let record: DictationRecord

    private var kept: Bool { (record.cleanup ?? "").hasPrefix("kept") }
    private var symbol: String {
        let note = record.cleanup ?? ""
        if note.hasPrefix("filled") { return "Brain" }
        if note.hasPrefix("snippet") { return "Scissors" }
        return kept ? "ArrowUUpLeft" : "Sparkle"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PhosphorIcon(name: symbol, size: 13).foregroundStyle(kept ? Theme.warning : Theme.accent)
                Text(record.cleanup == "cleaned" ? "Cleaned" : (record.cleanup ?? "").capitalizedFirst)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer()
                Text("\(record.app) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            if let heard = record.heard {
                Text(heard).font(.system(size: 13)).foregroundStyle(Theme.tertiary).strikethrough(color: Theme.tertiary)
            }
            Text(record.text).font(.system(size: 14)).foregroundStyle(Theme.text).textSelection(.enabled)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
