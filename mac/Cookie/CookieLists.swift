//
//  CookieLists.swift
//  Cookie
//
//  Lists: everyone you could work with (an ICP list, intros to make), as
//  opposed to Work: the few things in motion. A row becomes work only when
//  you start something with it; the row then shows that work's stage.
//  Kept on this Mac, sealed like the chats. Not sent to Enkeon: a prospect
//  list is the person's to share.
//

import Foundation

struct ListRow: Codable, Equatable, Identifiable {
    var id = UUID()
    var company: String
    var website = ""
    var contact = ""
    /// Why they fit, or any note.
    var note = ""
    /// Imported columns Cookie has no field for, kept so an import loses nothing.
    var extra: [String: String] = [:]
    /// The work started from this row.
    var workID: UUID?
}

struct CookieList: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var rows: [ListRow] = []
    var created = Date()
}

/// What starting work on a row asks for.
enum ListAction: String, CaseIterable, Identifiable {
    case research, intro, followUp
    var id: String { rawValue }

    var title: String {
        switch self {
        case .research: return "Research"
        case .intro: return "Draft an intro"
        case .followUp: return "Follow up"
        }
    }

    var symbol: String {
        switch self {
        case .research: return "sparkle.magnifyingglass"
        case .intro: return "envelope"
        case .followUp: return "arrow.uturn.forward"
        }
    }

    func nextStep(for row: ListRow) -> String {
        let who = row.contact.isEmpty ? row.company : "\(row.contact) at \(row.company)"
        switch self {
        case .research: return "Research \(row.company)\(row.website.isEmpty ? "" : " (\(row.website))"): who to talk to and why they'd care"
        case .intro: return "Draft an intro to \(who)"
        case .followUp: return "Follow up with \(who)"
        }
    }
}

@MainActor
final class ListStore: ObservableObject {
    static let shared = CommandLine.arguments.contains("--sample-work") ? ListStore.sample(linkedTo: WorkStore.shared) : ListStore()

    @Published private(set) var lists: [CookieList] = []
    @Published private(set) var problem: String?

    /// Off for samples and tests: nothing is read from or written to this Mac.
    private let connected: Bool
    private var file: URL { ChatVault.directory.appendingPathComponent("lists.sealed") }

    init(connected: Bool = true) {
        self.connected = connected
        if connected { load() }
    }

    func list(_ id: UUID?) -> CookieList? { lists.first { $0.id == id } }

    @discardableResult
    func create(name: String, rows: [ListRow] = []) -> CookieList {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = CookieList(name: trimmed.isEmpty ? "Untitled list" : trimmed, rows: rows)
        lists.append(list)
        save()
        return list
    }

    func rename(_ id: UUID, to name: String) {
        edit(id) { $0.name = name }
    }

    func delete(_ id: UUID) {
        lists.removeAll { $0.id == id }
        save()
    }

    @discardableResult
    func addRow(to id: UUID, _ row: ListRow = ListRow(company: "")) -> UUID {
        edit(id) { $0.rows.append(row) }
        return row.id
    }

    func updateRow(_ listID: UUID, _ rowID: UUID, _ change: (inout ListRow) -> Void) {
        edit(listID) { list in
            guard let index = list.rows.firstIndex(where: { $0.id == rowID }) else { return }
            change(&list.rows[index])
        }
    }

    func removeRows(_ listID: UUID, _ rowIDs: Set<UUID>) {
        edit(listID) { $0.rows.removeAll { rowIDs.contains($0.id) } }
    }

    /// Starts work on each row that has none yet; returns the work created.
    @discardableResult
    func startWork(_ listID: UUID, rows rowIDs: Set<UUID>, action: ListAction, in work: WorkStore) -> [WorkItem] {
        guard let list = list(listID) else { return [] }
        var created: [WorkItem] = []
        for row in list.rows where rowIDs.contains(row.id) && !row.company.isEmpty {
            if let existing = row.workID, work.item(existing) != nil { continue }
            let item = work.add(title: "\(row.company): \(action.title.lowercased())", nextStep: action.nextStep(for: row),
                                to: row.company)
            updateRow(listID, row.id) { $0.workID = item.id }
            created.append(item)
        }
        return created
    }

    private func edit(_ id: UUID, _ change: (inout CookieList) -> Void) {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
        change(&lists[index])
        save()
    }

    // MARK: Disk

    private func load() {
        guard let sealed = try? Data(contentsOf: file) else { return }
        do {
            lists = try JSONDecoder().decode([CookieList].self, from: ChatVault.open(sealed))
        } catch {
            // Never overwrite lists we couldn't read: set them aside for recovery.
            let aside = ChatVault.directory.appendingPathComponent("lists.unreadable-\(Int(Date().timeIntervalSince1970)).sealed")
            try? FileManager.default.moveItem(at: file, to: aside)
            problem = "Couldn't open your saved lists; they were set aside, not deleted."
        }
    }

    private func save() {
        guard connected else { return }
        do {
            try FileManager.default.createDirectory(at: ChatVault.directory, withIntermediateDirectories: true)
            try ChatVault.seal(JSONEncoder().encode(lists)).write(to: file, options: .atomic)
            problem = nil
        } catch {
            problem = "Couldn't save lists on this Mac: \(error.localizedDescription)"
        }
    }
}

// MARK: - CSV

enum ListCSV {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// RFC 4180: quoted fields, doubled quotes, commas and line breaks inside quotes.
    /// Semicolon files (common from European spreadsheets) are read too.
    static func parse(_ text: String) -> [[String]] {
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let firstLine = body.prefix { $0 != "\n" && $0 != "\r" }
        let separator: Character = firstLine.filter { $0 == ";" }.count > firstLine.filter { $0 == "," }.count ? ";" : ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(body)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == separator {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r" || c == "\r\n" {
                row.append(field); field = ""
                if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { rows.append(row) }
                row = []
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
            } else {
                field.append(c)
            }
            i += 1
        }
        return rows
    }

    /// The first row names the columns. Known names land in Cookie's fields;
    /// every other column is kept as it was.
    static func rows(from text: String) throws -> [ListRow] {
        let table = parse(text)
        guard let header = table.first, table.count > 1 else {
            throw Failure(message: "The file needs a header row and at least one company.")
        }
        let names = header.map { $0.trimmingCharacters(in: .whitespaces) }
        func column(_ keys: [String]) -> Int? {
            names.firstIndex { name in keys.contains(name.lowercased()) }
        }
        let company = column(["company", "company name", "name", "organization", "organisation", "account"])
        guard let company else {
            throw Failure(message: "No company column. Name one \u{201C}Company\u{201D} or \u{201C}Name\u{201D}.")
        }
        let website = column(["website", "domain", "url", "site", "web"])
        let contact = column(["contact", "contact name", "person", "email", "contact email"])
        let note = column(["note", "notes", "why", "why they fit", "fit", "reason", "description"])
        let known = Set([company, website, contact, note].compactMap { $0 })
        return table.dropFirst().compactMap { cells in
            func value(_ index: Int?) -> String {
                guard let index, index < cells.count else { return "" }
                return cells[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let name = value(company)
            guard !name.isEmpty else { return nil }
            var extra: [String: String] = [:]
            for (index, header) in names.enumerated() where !known.contains(index) && !header.isEmpty {
                let cell = value(index)
                if !cell.isEmpty { extra[header] = cell }
            }
            return ListRow(company: name, website: value(website), contact: value(contact), note: value(note), extra: extra)
        }
    }
}

// MARK: - Sample (screens only)

extension ListStore {
    static func sample(linkedTo work: WorkStore) -> ListStore {
        let store = ListStore(connected: false)
        let list = store.create(name: "ICP: engineering teams", rows: [
            ListRow(company: "Northwind", website: "northwind.example", contact: "Head of engineering", note: "Fleet software, Riga; asked about a team pilot"),
            ListRow(company: "Initech", website: "initech.example", note: "Large agency team, many parallel projects"),
            ListRow(company: "Globex", website: "globex.example", note: "Small product team, fast release cycle"),
            ListRow(company: "Umbrella", website: "umbrella.example", note: "AI tooling team, heavy Claude Code use"),
            ListRow(company: "Hooli", website: "hooli.example", note: "Already on the free plan"),
            ListRow(company: "Wonka", website: "wonka.example", note: "Riga engineering office"),
        ])
        // Link the rows that already have work in the sample board.
        for row in list.rows {
            if let item = work.items.first(where: { $0.to == row.company && $0.column != .done }) {
                store.updateRow(list.id, row.id) { $0.workID = item.id }
            }
        }
        return store
    }
}
