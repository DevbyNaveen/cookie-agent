//
//  CookieModels.swift
//  Cookie
//
//  Chats, messages and files as Cookie keeps them. Threads are saved as JSON
//  in Application Support so they survive a restart. Screenshots are never
//  saved: they live only for the one request.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

struct CookieAttachment: Codable, Hashable, Identifiable {
    let path: String
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var kind: String { url.pathExtension.uppercased().isEmpty ? "File" : url.pathExtension.uppercased() }
    var isImage: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false }

    /// Images are re-encoded as JPEG for the model, capped at 1600px on the long side.
    func jpegData() -> Data? {
        guard let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        let longSide = max(bitmap.pixelsWide, bitmap.pixelsHigh)
        guard longSide > 1600 else { return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) }
        let scale = 1600 / CGFloat(longSide)
        let size = NSSize(width: CGFloat(bitmap.pixelsWide) * scale, height: CGFloat(bitmap.pixelsHigh) * scale)
        let resized = NSImage(size: size)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        resized.unlockFocus()
        guard let small = resized.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else { return nil }
        return small.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

/// One thing Cookie did on the way to a reply, with how long it took.
struct CookieStep: Codable, Hashable {
    let title: String
    let seconds: Double
}

struct CompanionChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant, failure, note }
    var id = UUID()
    let role: Role
    let text: String
    var date = Date()
    var attachments: [CookieAttachment] = []
    var steps: [CookieStep] = []
    var duration: Double?
    var nextSteps: [String] = []
    /// The reply was built from a screenshot or file, so on later turns it is
    /// untrusted context, never your words. Nil: saved before this was recorded.
    var readUntrusted: Bool?
}

/// Each chat is handled by one specialist, picked from its first message.
/// The specialist sets the chat's badge and adds a short brief to the system prompt.
enum CookieSpecialist: String, Codable, CaseIterable {
    case general, research, writer, sales, mac

    var title: String {
        switch self {
        case .general: return "Cookie"
        case .research: return "Research"
        case .writer: return "Writer"
        case .sales: return "Sales"
        case .mac: return "Mac"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "sparkle"
        case .research: return "magnifyingglass"
        case .writer: return "pencil.line"
        case .sales: return "person.2"
        case .mac: return "cursorarrow.click.2"
        }
    }

    /// Appended to the system prompt for every turn of this chat.
    var brief: String {
        switch self {
        case .general: return ""
        case .research:
            return "this chat's specialist: research. find out, compare and verify before answering; say what you checked and what you couldn't; separate facts from your read of them."
        case .writer:
            return "this chat's specialist: writer. drafts, emails, replies, brainstorms and lists are your work. when a field, email or document is on screen, write the finished text there with type_text instead of reading it aloud; match the tone already on screen."
        case .sales:
            return "this chat's specialist: sales. icp lists, prospects, outreach, follow-ups and crm updates. be concrete: names of segments, roles, triggers and the next step; draft into whatever the user has open."
        case .mac:
            return "this chat's specialist: mac. the user wants something done in an app. start_task first, act step by step, look after each step, and report only what the last look shows."
        }
    }

    // ponytail: keyword routing on the first message; swap for a model call if it misroutes often.
    static func infer(from text: String) -> CookieSpecialist {
        let words = text.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { words.contains($0) } }
        if has("write", "draft", "reply", "email", "brainstorm", "rewrite", "summar", "post", "message") { return .writer }
        if has("icp", "prospect", "lead", "outreach", "crm", "pipeline", "sell", "customer", "gtm", "pitch") { return .sales }
        if has("research", "find out", "compare", "look up", "what is", "who is", "why", "how does") { return .research }
        if has("open ", "click", "fill", "spreadsheet", "excel", "do this", "change the", "set the", "type ") { return .mac }
        return .general
    }
}

struct CookieThread: Identifiable, Codable, Equatable {
    var id = UUID()
    var messages: [CompanionChatMessage] = []
    var updatedAt = Date()
    /// The agent this chat belongs to (CookieAgentStore). Nil for chats saved before agents existed.
    var agentID: UUID?

    var title: String {
        let first = messages.first { $0.role == .user }
        if let text = first?.text, !text.isEmpty { return text }
        return first?.attachments.first?.name ?? "New chat"
    }

    var preview: String {
        guard let last = messages.last(where: { $0.role != .note }) else { return "" }
        return last.text.isEmpty ? (last.attachments.first?.name ?? "") : last.text
    }

    var latestAttachment: CookieAttachment? {
        messages.reversed().lazy.flatMap(\.attachments).first
    }
}

/// Chats on disk, encrypted (ChatVault). A plaintext file from before
/// encryption existed is sealed on first load and then destroyed.
enum CookieThreadStore {
    static func load() -> [CookieThread] {
        let fm = FileManager.default
        if let sealed = try? Data(contentsOf: ChatVault.encryptedFile) {
            do {
                return try decode(ChatVault.open(sealed))
            } catch {
                // Never overwrite chats we couldn't read: keep the file aside for recovery.
                print("⚠️ Cookie: could not open saved chats: \(error)")
                let aside = ChatVault.directory.appendingPathComponent("threads.unreadable-\(Int(Date().timeIntervalSince1970)).sealed")
                try? fm.moveItem(at: ChatVault.encryptedFile, to: aside)
                return []
            }
        }
        guard let plaintext = try? Data(contentsOf: ChatVault.legacyPlaintextFile) else { return [] }
        let threads = (try? decode(plaintext)) ?? []
        do {
            try ChatVault.write(plaintext)
            ChatVault.destroy(ChatVault.legacyPlaintextFile)
        } catch {
            print("⚠️ Cookie: could not encrypt old chats, leaving them in place: \(error)")
        }
        return threads
    }

    static func save(_ threads: [CookieThread]) {
        do {
            try ChatVault.write(JSONEncoder().encode(threads))
        } catch {
            print("⚠️ Cookie: could not save chats: \(error)")
        }
    }

    private static func decode(_ data: Data) throws -> [CookieThread] {
        try JSONDecoder().decode([CookieThread].self, from: data).sorted { $0.updatedAt > $1.updatedAt }
    }
}

/// "Today 19:41", "Yesterday", "Mon", "12 Oct" — the way Messages labels time.
enum CookieTime {
    static func short(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func separator(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday \(time)" }
        return "\(date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))) \(time)"
    }

    static func duration(_ seconds: Double) -> String {
        seconds < 60 ? String(format: seconds < 10 ? "%.1fs" : "%.0fs", seconds) : "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }

    static func greeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Evening" : hour < 12 ? "Morning" : hour < 18 ? "Afternoon" : "Evening"
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "Good \(part.lowercased())." : "\(part), \(first)."
    }
}
