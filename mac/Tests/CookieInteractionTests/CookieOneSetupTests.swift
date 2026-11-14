import EnkeonVoiceKit
import AppKit

/// One setup and one Settings for voice and Cookie.
@MainActor
enum CookieOneSetupTests {
    static func run() {
        precondition(CookieSetupStep.allCases.map(\.label) == ["Welcome", "Voice", "Shortcuts", "Practice", "Screen", "Ready"],
                     "practice comes after the shortcut permissions it needs")

        // Speech: Apple on this Mac unless Settings picked another; Parakeet only when chosen.
        let suite = "cookie.checks.speech.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(BuddyTranscriptionProviderFactory.preferredName(defaults: defaults, bundleValue: nil) == "apple")
        precondition(BuddyTranscriptionProviderFactory.preferredName(defaults: defaults, bundleValue: "parakeet") == "parakeet")
        defaults.set("parakeet", forKey: BuddyTranscriptionProviderFactory.speechProviderKey)
        precondition(BuddyTranscriptionProviderFactory.preferredName(defaults: defaults, bundleValue: "apple") == "parakeet", "Settings wins over the bundle")
        defaults.set("anything", forKey: BuddyTranscriptionProviderFactory.speechProviderKey)
        precondition(BuddyTranscriptionProviderFactory.preferredName(defaults: defaults, bundleValue: nil) == "apple", "unknown means Apple")

        // Practice: dictation into Cookie's own window lands in the practice field.
        let words = CookieDictation.shared.words
        let before = words.practiceText
        defer { words.practiceText = before }
        words.practiceText = ""
        words.dictation.ownWindowSink?("hello from practice")
        precondition(words.practiceText == "hello from practice")

        // One vocabulary: Settings, Dictionary and talk hints read the same list.
        precondition(CookieDictationText.vocabularyKey == DictationText.vocabularyKey)
        print("4 one-setup checks passed.")
    }
}
