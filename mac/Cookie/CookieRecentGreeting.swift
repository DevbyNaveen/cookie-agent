import Foundation

enum CookieRecentGreeting {
    static func title(in threads: [CookieThread]) -> String? {
        guard let recent = threads.filter({ $0.messages.contains { $0.role == .user && !$0.text.isEmpty } })
            .max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
        let savedTitle = recent.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = savedTitle.isEmpty || savedTitle.caseInsensitiveCompare("New chat") == .orderedSame
            ? (recent.messages.last { $0.role == .user && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.text
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : savedTitle
        guard !title.isEmpty else { return nil }
        return title.count > 56 ? String(title.prefix(55)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" : title
    }
}
