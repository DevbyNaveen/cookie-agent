import EnkeonVoiceKit
import SwiftUI

@MainActor
final class SnippetStore: ObservableObject {
    static let key = "enkeon.snippets"

    @Published private(set) var snippets: [Snippet] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Snippet].self, from: data) { snippets = saved }
    }

    func save(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) { snippets[index] = snippet } else { snippets.append(snippet) }
        persist()
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snippets) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func request(in transcript: String) -> SnippetRequest? { SnippetRequest.find(in: transcript, snippets: snippets) }
}

struct SnippetEditor: View {
    @State var snippet: Snippet
    let save: (Snippet) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Snippet").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
            field("Cue (what you say)", text: $snippet.cue, prompt: "my calendar link")
            Picker("Kind", selection: $snippet.kind) {
                Text("Text").tag(Snippet.Kind.text)
                Text("From memory").tag(Snippet.Kind.memory)
            }
            .pickerStyle(.segmented)
            field(snippet.kind == .memory ? "What to look up in your memory" : "Text that goes in",
                  text: $snippet.body, prompt: snippet.kind == .memory ? "Halvorsen pricing" : "https://cal.com/…")
            HStack {
                Button("Cancel", action: cancel).buttonStyle(.plain).foregroundStyle(Theme.secondary)
                Spacer()
                Button("Save") { save(snippet) }
                    .buttonStyle(PrimaryButton())
                    .disabled(snippet.cue.trimmingCharacters(in: .whitespaces).isEmpty || snippet.body.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.background)
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            TextField(prompt, text: text, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...5)
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
