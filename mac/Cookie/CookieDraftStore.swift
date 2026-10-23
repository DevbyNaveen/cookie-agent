import Combine
import Foundation

@MainActor
final class CookieChatDraft: ObservableObject {
    @Published var text = ""
    @Published var attachments: [CookieAttachment] = []
    /// The screen button: this one message may look at the screen.
    @Published var withScreen = false

    func attach(_ attachment: CookieAttachment) {
        if !attachments.contains(attachment) { attachments.append(attachment) }
    }

    func clear() {
        text = ""
        attachments = []
        withScreen = false
    }
}

/// Drafts belong to conversations, not to a particular notch or window view.
/// They stay in memory only; collapsing the UI never writes unsent text to disk.
@MainActor
final class CookieDraftStore {
    private var threads: [UUID: CookieChatDraft] = [:]
    private var newChat = CookieChatDraft()

    func draft(for threadID: UUID?) -> CookieChatDraft {
        guard let threadID else { return newChat }
        if let existingDraft = threads[threadID] { return existingDraft }
        let draft = CookieChatDraft()
        threads[threadID] = draft
        return draft
    }

    func adoptNewChat(for threadID: UUID) {
        threads[threadID] = newChat
        newChat = CookieChatDraft()
    }

    func remove(threadID: UUID) {
        threads.removeValue(forKey: threadID)?.clear()
    }

    func removeAll() {
        threads.values.forEach { $0.clear() }
        threads.removeAll()
        newChat.clear()
        newChat = CookieChatDraft()
    }
}
