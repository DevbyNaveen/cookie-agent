import Foundation

/// Local receipts for explicit panel saves, separate from dictation usage statistics.
@MainActor final class MemoryNoteStore: ObservableObject {
    struct Note: Codable, Identifiable {
        var id = UUID()
        var date = Date()
        var text: String
        var branch: String
        var originalVoiceID: UUID?
        var memoryID: String?
        var message = "Save not confirmed. Check memory before retrying."
    }
    @Published private(set) var notes: [Note] = []
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Enkeon/memory-notes.json")

    init() {
        guard UserDefaults.standard.object(forKey: HistoryStore.enabledKey) as? Bool != false else { return }
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Note].self, from: data) { notes = saved }
    }

    func put(_ note: Note) throws {
        guard UserDefaults.standard.bool(forKey: HistoryStore.enabledKey) else { return }
        var next = notes.filter { $0.id != note.id }
        next.insert(note, at: 0)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        notes = next
    }

    func clear() {
        notes = []
        try? FileManager.default.removeItem(at: file)
    }
}
