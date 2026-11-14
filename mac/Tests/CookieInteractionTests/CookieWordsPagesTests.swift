import EnkeonVoiceKit
import AppKit
import SwiftUI

/// Enkeon Voice's pages in Cookie's console, in Cookie's look, on Cookie's one controller.
@MainActor
enum CookieWordsPagesTests {
    static func run() {
        precondition(CookieNavigation.Section(rawValue: "words") != nil && CookieNavigation.Section(rawValue: "memory") != nil)
        precondition(Page.yourWords.map(\.title) == ["Home", "Dictionary", "Snippets", "Styles"])
        precondition(Page.memory.map(\.title) == ["Notes", "Context"])
        precondition(Theme.accent == CK.accent && Theme.text == CK.text, "Voice's pages wear Cookie's colours")

        let words = CookieDictation.shared.words
        precondition(words.dictation === CookieDictation.shared.controller, "one controller, never a second keyboard tap")
        precondition(words.history.file.path.hasSuffix("Application Support/Enkeon/history.json"), "your Enkeon Voice history carries over")
        precondition(words.dictation.onRecord != nil, "dictations land in Your words' history")

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cookie-words-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = HistoryStore(directory: scratch)
        store.add(DictationRecord(id: UUID(), date: Date(), app: "Notes", text: "ship Friday", outcome: .inserted, note: nil, durationSeconds: 1))
        precondition(store.records.first?.text == "ship Friday")
        print("4 words page checks passed.")
    }
}
