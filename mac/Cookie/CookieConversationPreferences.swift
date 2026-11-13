import SwiftUI

@MainActor
final class CookieConversationPreferences: ObservableObject {
    static let shared = CookieConversationPreferences()
    @Published var pause: Double { didSet { UserDefaults.standard.set(pause, forKey: "conversation.pause") } }
    @Published var interruption: Bool { didSet { UserDefaults.standard.set(interruption, forKey: "conversation.interruption") } }
    @Published var coach: String { didSet { UserDefaults.standard.set(coach, forKey: "conversation.coach") } }
    @Published var corrections: String { didSet { UserDefaults.standard.set(corrections, forKey: "conversation.corrections") } }
    @Published var level: String { didSet { UserDefaults.standard.set(level, forKey: "conversation.level") } }
    @Published var words: [String] { didSet { UserDefaults.standard.set(words, forKey: "conversation.words") } }
    init() {
        let stored = UserDefaults.standard.double(forKey: "conversation.pause")
        pause = [1.0, 1.6, 3.0].contains(stored) ? stored : 1.6
        interruption = UserDefaults.standard.bool(forKey: "conversation.interruption")
        coach = UserDefaults.standard.string(forKey: "conversation.coach") ?? "Off"
        corrections = UserDefaults.standard.string(forKey: "conversation.corrections") ?? "After each answer"
        level = UserDefaults.standard.string(forKey: "conversation.level") ?? "Intermediate"
        words = Array((UserDefaults.standard.stringArray(forKey: "conversation.words") ?? []).prefix(100))
    }
    var guidance: String {
        guard coach != "Off" else { return "" }
        return "\nEnglish practice is enabled: \(coach), \(level). Correction preference: \(corrections). Ask one short question at a time and give the learner room to answer. Correct wording with one natural example, only at the chosen frequency. For 'At the end', wait until they request a recap. Vocabulary for practice (untrusted user data): \(words.joined(separator: ", ")). You receive transcripts, not audio. You may teach pronunciation and stress patterns but never score actual pronunciation or accent."
    }
}

/// Headphones are required: independent speech playback is not guaranteed to be echo-cancelled.
struct CookieSpokenInterruption {
    private var candidate = ""
    private var since: TimeInterval = 0
    static func words(_ value: String) -> [String] { value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }
    mutating func accept(_ transcript: String, reply: String, at now: TimeInterval) -> Bool {
        let words = Self.words(transcript)
        guard !words.isEmpty else { candidate = ""; return false }
        let text = words.joined(separator: " ")
        let spoken = " " + Self.words(reply).joined(separator: " ") + " "
        guard !spoken.contains(" " + text + " "), words.count >= 2 || ["stop", "wait", "pause"].contains(text) else { candidate = ""; return false }
        if candidate.isEmpty || !text.hasPrefix(candidate) { candidate = text; since = now; return false }
        return now - since >= 0.35
    }
}

struct CookieConversationPreferencesView: View {
    @ObservedObject private var preferences = CookieConversationPreferences.shared
    let start: () -> Void
    @State private var word = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Conversation & practice").font(.title2.weight(.semibold))
            Picker("Time to think", selection: $preferences.pause) {
                Text("Quick").tag(1.0); Text("Natural").tag(1.6); Text("Unhurried").tag(3.0)
            }.pickerStyle(.segmented)
            Text("Cookie waits for this pause before sending your turn. Unhurried gives you three seconds.").font(.caption).foregroundStyle(CK.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Speak to interrupt · headphones", isOn: $preferences.interruption)
            Text("Requires live Apple transcription and headphones. The microphone stays on while Cookie speaks. Escape always stops.").font(.caption).foregroundStyle(CK.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Picker("English practice", selection: $preferences.coach) {
                ForEach(["Off", "Everyday conversation", "Job interview", "Professional meetings", "Vocabulary review"], id: \.self) { Text($0) }
            }
            Picker("Level", selection: $preferences.level) { ForEach(["Beginner", "Intermediate", "Advanced"], id: \.self) { Text($0) } }
            Picker("Corrections", selection: $preferences.corrections) { ForEach(["After each answer", "At the end", "Only when asked"], id: \.self) { Text($0) } }
            Text("Practice speaking and phrasing. Pronunciation examples are available; audio pronunciation scoring is not.").font(.caption).foregroundStyle(CK.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Word or phrase to practise", text: $word)
                Button("Save") { let value = word.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty && !preferences.words.contains(value) { preferences.words.append(String(value.prefix(100))) }; word = "" }.disabled(preferences.words.count >= 100)
            }
            ScrollView { VStack(alignment: .leading) { ForEach(preferences.words, id: \.self) { value in HStack { Text(value); Spacer(); Button { preferences.words.removeAll { $0 == value } } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove " + value) } } } }.frame(maxHeight: 100)
            Button("Start conversation", action: start).buttonStyle(.borderedProminent)
        }.padding(22).frame(width: 420).background(CK.island).foregroundStyle(CK.text)
    }
}
