//
//  CookieTimeMachine.swift
//  Cookie
//
//  Every change Cookie makes to your work gets a receipt: what the field read
//  before and after, or a copy of the document taken before a script touched
//  it. Kept a week on this Mac, scrubbable on the Board, and put back only
//  after you say yes, and only if nothing changed since.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct CookieReceipt: Codable, Identifiable, Equatable {
    var id: UUID
    var date: Date
    var app: String
    var tool: String
    /// The field or document, in a few words ("Subject", "the focused field", "Budget.xlsx").
    var target: String
    /// Text: what it read, masked and bounded. Files: size and modified time. nil = before unknown.
    var before: String?
    var after: String?
    /// The document's path, for file receipts.
    var file: String?
    /// Cookie's copy of it, under snapshots/<id>/.
    var snapshot: String?
    var restorable: Bool
}

@MainActor
final class CookieTimeMachine: ObservableObject {
    static let shared = CookieTimeMachine(folder: defaultFolder, proof: .shared)
    static let defaultFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cookie")

    static let keep: TimeInterval = 7 * 24 * 3600
    /// A field's before and after are kept up to this many characters each.
    static let maxText = 20_000

    /// A text field Cookie can read and write again, for a restore. Live only while Cookie runs.
    struct Field {
        let read: () -> String?
        let write: (String) -> Bool
    }

    /// Newest first.
    @Published private(set) var receipts: [CookieReceipt] = []
    /// nil keeps receipts in memory only (checks).
    private let folder: URL?
    private let proof: CookieProof
    let maxFileBytes: Int
    let maxSnapshotBytes: Int
    /// The exact words (unmasked) and the field, so a restore writes back what was really there; never on disk.
    private var live: [UUID: (field: Field, before: String, after: String)] = [:]

    init(folder: URL?, proof: CookieProof, maxFileBytes: Int = 50 << 20, maxSnapshotBytes: Int = 1 << 30) {
        self.folder = folder
        self.proof = proof
        self.maxFileBytes = maxFileBytes
        self.maxSnapshotBytes = maxSnapshotBytes
        if let file = ledger, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([CookieReceipt].self, from: data) {
            receipts = saved.sorted { $0.date > $1.date }
            prune()
        }
    }

    private var ledger: URL? { folder?.appendingPathComponent("time-machine.json") }
    private var snapshots: URL? { folder?.appendingPathComponent("snapshots") }

    var today: [CookieReceipt] { receipts.filter { Calendar.current.isDateInToday($0.date) } }

    func receipt(_ id: String) -> CookieReceipt? {
        let key = id.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return receipts.first { $0.id.uuidString.lowercased().hasPrefix(key) }
    }

    // MARK: Text

    /// A field Cookie changed. Only the masked, bounded words are kept on disk.
    @discardableResult
    func recordText(tool: String, app: String, target: String, before: String?, after: String?, field: Field?) -> CookieReceipt {
        let id = UUID()
        let restorable = field != nil && before != nil && after != nil
            && before!.count <= Self.maxText && after!.count <= Self.maxText
        if restorable, let field, let before, let after { live[id] = (field, before, after) }
        let receipt = CookieReceipt(id: id, date: Date(), app: app, tool: tool, target: target,
                                    before: before.map(Self.mask), after: after.map(Self.mask),
                                    file: nil, snapshot: nil, restorable: restorable)
        add(receipt, summary: "kept a before and after of \(Self.plain(tool))")
        return receipt
    }

    /// Dictation went in. The kit owns the field and its own "scratch that" undo, so this receipt
    /// only shows what the field reads now; the before is unknown and it isn't restorable here.
    // ponytail: EnkeonVoiceKit keeps its TextDestination internal; expose before/after there if dictation receipts need restore.
    func recordDictation(app: String) {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(), !CaptureGuard.focusedElementIsSecure(),
              let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier,
              !MacSafety.blocked(bundleID: front.bundleIdentifier, category: MacOperator.category(front)) else { return }
        let after = MacOperator.focusedElement().flatMap { MacOperator.string($0, kAXValueAttribute) }
        recordText(tool: "dictation", app: app, target: "the focused field", before: nil, after: after, field: nil)
    }

    /// No secrets, at most 20 KB.
    static func mask(_ text: String) -> String {
        var kept = text.count > maxText ? String(text.prefix(maxText)) + "…" : text
        for range in SensitiveText.ranges(in: kept).reversed() { kept.replaceSubrange(range, with: "•••") }
        return kept
    }

    // MARK: Files

    /// A copy of the document before a script runs. Never throws: a copy that can't be made
    /// still leaves a receipt that says the before is unknown.
    @discardableResult
    func snapshotBefore(_ file: URL?, tool: String, app: String) -> CookieReceipt {
        let id = UUID()
        var receipt = CookieReceipt(id: id, date: Date(), app: app, tool: tool, target: file?.lastPathComponent ?? "the front document",
                                    before: nil, after: nil, file: file?.path, snapshot: nil, restorable: false)
        if let file, let size = Self.size(file), size <= maxFileBytes, let snapshots {
            let folder = snapshots.appendingPathComponent(id.uuidString)
            let copy = folder.appendingPathComponent(file.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: file, to: copy)
                receipt.snapshot = copy.path
                receipt.before = Self.describe(file)
                receipt.restorable = true
            } catch {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        add(receipt, summary: "kept a copy of a document before \(Self.plain(tool))")
        return receipt
    }

    /// After the script: the document's size and time now.
    func finishSnapshot(_ id: UUID) {
        guard let index = receipts.firstIndex(where: { $0.id == id }), let path = receipts[index].file else { return }
        receipts[index].after = Self.describe(URL(fileURLWithPath: path))
        save()
    }

    static func describe(_ file: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? Int, let modified = attributes[.modificationDate] as? Date else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) + " · modified " + time.string(from: modified)
    }

    private static func size(_ file: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int
    }

    // MARK: Restore

    func canRestore(_ receipt: CookieReceipt) -> Bool {
        if let snapshot = receipt.snapshot { return receipt.restorable && FileManager.default.fileExists(atPath: snapshot) }
        return live[receipt.id] != nil
    }

    /// The approval's words. Nothing is put back without a yes to these.
    static func question(for receipt: CookieReceipt) -> String {
        let when = time.string(from: receipt.date)
        if receipt.file != nil { return "Put \(receipt.target) back to \(when)? The version there now is kept first." }
        return "Put \(receipt.target) in \(receipt.app) back to how it read at \(when)?"
    }

    /// Called only after the person said yes.
    func restore(_ id: UUID) async -> (message: String, success: Bool) {
        guard let receipt = receipts.first(where: { $0.id == id }) else { return ("Cookie has no receipt like that.", false) }
        if receipt.file != nil { return restoreFile(receipt) }
        guard let (field, before, after) = live[id] else {
            return ("Cookie can't put this one back: the before wasn't known, or Cookie restarted since.", false)
        }
        // The same rule as undoing a dictation: only if the field still holds exactly what Cookie wrote.
        guard field.read() == after else { return ("The field changed after Cookie wrote it. I left your newer edits untouched.", false) }
        guard field.write(before) else { return ("This field can't be written back. Use the app's Undo.", false) }
        for _ in 0..<8 {
            if field.read() == before {
                live[id] = nil
                recordText(tool: "restore", app: receipt.app, target: receipt.target, before: after, after: before, field: field)
                return ("Put \(receipt.target) back as it was.", true)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return ("The app didn't confirm the restore. Check the field before trying again.", false)
    }

    private func restoreFile(_ receipt: CookieReceipt) -> (message: String, success: Bool) {
        guard let path = receipt.file, let snapshot = receipt.snapshot, canRestore(receipt) else {
            return ("Cookie has no copy of \(receipt.target) from then.", false)
        }
        let file = URL(fileURLWithPath: path)
        // Staged first: keeping the current version may prune the oldest snapshots, this one included.
        let staged = file.deletingLastPathComponent().appendingPathComponent(".cookie-restore-\(UUID().uuidString)-\(file.lastPathComponent)")
        do { try FileManager.default.copyItem(at: URL(fileURLWithPath: snapshot), to: staged) } catch {
            return ("Couldn't put \(receipt.target) back: \(error.localizedDescription)", false)
        }
        // The version there now becomes its own receipt first, so this can be undone too.
        let current = snapshotBefore(file, tool: "restore", app: receipt.app)
        guard current.snapshot != nil else {
            try? FileManager.default.removeItem(at: staged)
            return ("Cookie couldn't keep the version of \(receipt.target) there now, so it left it alone.", false)
        }
        do { _ = try FileManager.default.replaceItemAt(file, withItemAt: staged) } catch {
            try? FileManager.default.removeItem(at: staged)
            return ("Couldn't put \(receipt.target) back: \(error.localizedDescription)", false)
        }
        finishSnapshot(current.id)
        return ("Put \(receipt.target) back to \(Self.time.string(from: receipt.date)). If it's open, close it without saving and open it again.", true)
    }

    // MARK: Keeping

    private func add(_ receipt: CookieReceipt, summary: String) {
        receipts.insert(receipt, at: 0)
        proof.record(.acted, feature: "time machine", app: receipt.app, summary: summary)
        prune()
        save()
    }

    /// A week of receipts; snapshots at most 1 GB, oldest let go first.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.keep)
        for receipt in receipts where receipt.date < cutoff { dropSnapshot(receipt) }
        receipts.removeAll { $0.date < cutoff }
        live = live.filter { id, _ in receipts.contains { $0.id == id } }
        var total = receipts.compactMap(\.snapshot).compactMap { Self.size(URL(fileURLWithPath: $0)) }.reduce(0, +)
        for index in receipts.indices.reversed() where total > maxSnapshotBytes {
            guard let snapshot = receipts[index].snapshot else { continue }
            total -= Self.size(URL(fileURLWithPath: snapshot)) ?? 0
            dropSnapshot(receipts[index])
            receipts[index].snapshot = nil
            receipts[index].restorable = false
        }
    }

    private func dropSnapshot(_ receipt: CookieReceipt) {
        guard let snapshots else { return }
        try? FileManager.default.removeItem(at: snapshots.appendingPathComponent(receipt.id.uuidString))
    }

    /// Written whole, owner-only, renamed into place (as Proof does).
    private func save() {
        guard let folder, let ledger else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let temporary = folder.appendingPathComponent(".time-machine-\(UUID().uuidString).json")
            guard FileManager.default.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(receipts),
                                                 attributes: [.posixPermissions: 0o600]) else { return }
            if rename(temporary.path, ledger.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
        } catch {
            print("⚠️ Cookie: couldn't save the time machine: \(error)")
        }
    }

    static func plain(_ tool: String) -> String { tool.replacingOccurrences(of: "_", with: " ") }

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: Word diff

    enum Change: Equatable { case same, removed, added }

    /// Before and after as runs of words: kept, taken out, put in.
    static func wordDiff(_ before: String, _ after: String) -> [(change: Change, text: String)] {
        let old = before.split(whereSeparator: \.isWhitespace).map(String.init)
        let new = after.split(whereSeparator: \.isWhitespace).map(String.init)
        var removed = Set<Int>(), added = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        var runs: [(change: Change, text: String)] = []
        func push(_ change: Change, _ word: String) {
            if runs.last?.change == change { runs[runs.count - 1].text += " " + word } else { runs.append((change, word)) }
        }
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) { push(.removed, old[i]); i += 1 }
            else if j < new.count, added.contains(j) { push(.added, new[j]); j += 1 }
            else { push(.same, old[i]); i += 1; j += 1 }
        }
        return runs
    }
}

// MARK: - Hooks in the Mac tools

extension MacOperator {
    /// Runs a text-writing tool with a receipt around it: the field's value before and after.
    /// A read that fails never stops the action; the receipt then says the before is unknown.
    static func withReceipt(_ tool: String, app: String?, target: String, field: AXUIElement?,
                            machine: CookieTimeMachine = .shared,
                            read: @escaping (AXUIElement) -> String? = { MacOperator.string($0, kAXValueAttribute) },
                            write: @escaping (AXUIElement, String) -> Bool = { AXUIElementSetAttributeValue($0, kAXValueAttribute as CFString, $1 as CFString) == .success },
                            act: () async -> (String, Bool)) async -> (String, Bool) {
        let before = field.flatMap(read)
        let result = await act()
        guard !result.1 else { return result }
        let after = field.flatMap(read)
        machine.recordText(tool: tool, app: app ?? "the app", target: target, before: before, after: after,
                           field: field.map { element in .init(read: { read(element) }, write: { write(element, $0) }) })
        return result
    }

    /// The file behind the app's front window (AXDocument): no Automation prompt, the same in Office and iWork.
    static func frontDocument(of appName: String) -> URL? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            guard let window = attribute(element, name), CFGetTypeID(window) == AXUIElementGetTypeID(),
                  let document = string(window as! AXUIElement, kAXDocumentAttribute),
                  let url = URL(string: document), url.isFileURL else { continue }
            return url
        }
        return nil
    }

    /// run_script with a copy of the front document kept first.
    static func withSnapshot(_ tool: String, app: String?, document: URL?, machine: CookieTimeMachine = .shared,
                             act: () -> (String, Bool)) -> (String, Bool) {
        let receipt = machine.snapshotBefore(document, tool: tool, app: app ?? "the app")
        let result = act()
        machine.finishSnapshot(receipt.id)
        return result
    }
}

// MARK: - The model's tool

@MainActor
enum CookieTimeMachineTool {
    static let tool = HarnessRequest.Tool(
        name: "time_machine",
        description: "Cookie's receipts of its own edits today: what a field or document looked like before and after Cookie changed it. list (optional query: an app or field), show {id} for the before and after, restore {id} to put it back (the person approves; it only works if the field still reads what Cookie wrote).",
        effect: "outbound",
        schema: .init(properties: ["action": .init(description: "list, show or restore"),
                                   "id": .init(description: "A receipt id from list (its first characters are enough)."),
                                   "query": .init(description: "Optional for list: an app or field name.")],
                      required: ["action"]),
        parallel_safe: false)

    static func perform(_ args: [String: Any], machine: CookieTimeMachine = .shared, proof: CookieProof = .shared) async -> (String, Bool) {
        let action = (args["action"] as? String ?? "").lowercased()
        if action == "list" {
            let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let found = machine.today.filter { query.isEmpty || "\($0.app) \($0.target) \($0.tool)".localizedStandardContains(query) }
            guard !found.isEmpty else { return ("No receipts today\(query.isEmpty ? "" : " for \(query)").", false) }
            return (found.map { receipt in
                "\(receipt.id.uuidString.prefix(8).lowercased()): \(CookieTimeMachine.time.string(from: receipt.date)) · \(CookieTimeMachine.plain(receipt.tool)) · \(receipt.app) · \(receipt.target)"
                    + (machine.canRestore(receipt) ? "" : " · can't be restored")
            }.joined(separator: "\n"), false)
        }
        guard let receipt = machine.receipt(args["id"] as? String ?? "") else { return ("Give an id from list.", true) }
        switch action {
        case "show":
            proof.record(.sent, feature: "time machine", app: receipt.app, summary: "a receipt's before and after", destination: "the model")
            return ("\(receipt.target) in \(receipt.app), \(CookieTimeMachine.time.string(from: receipt.date))\nbefore: \(receipt.before ?? "unknown")\nafter: \(receipt.after ?? "unknown")", false)
        case "restore":
            let result = await machine.restore(receipt.id)
            return (result.message, !result.success)
        default:
            return ("action is list, show or restore.", true)
        }
    }

    /// Looking needs no card; only a restore asks.
    static func answersForYou(_ approval: HarnessApproval) -> Bool {
        !approval.actions.isEmpty && approval.actions.allSatisfy {
            $0.tool == tool.name && (MacOperator.args(of: $0)["action"] as? String)?.lowercased() != "restore"
        }
    }

    static func question(for action: HarnessAction, machine: CookieTimeMachine = .shared) -> String? {
        guard action.tool == tool.name else { return nil }
        let args = MacOperator.args(of: action)
        guard (args["action"] as? String)?.lowercased() == "restore" else { return "Look at what Cookie changed today?" }
        return machine.receipt(args["id"] as? String ?? "").map(CookieTimeMachine.question) ?? "Put back what Cookie changed?"
    }
}

// MARK: - Board → Time machine

struct CookieTimeMachineSection: View {
    @ObservedObject var machine: CookieTimeMachine = .shared
    @State private var selected: UUID?
    @State private var confirming = false
    @State private var message: String?

    var body: some View {
        let today = Array(machine.today.reversed())
        if !today.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 12, weight: .medium)).foregroundStyle(CK.tertiary)
                    WorkSectionHeading(title: "Time machine", count: today.count)
                }
                .padding(.horizontal, 4).frame(height: 26)
                // Today, left to right.
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(today) { receipt in chip(receipt).id(receipt.id) }
                        }
                        .padding(.horizontal, 2)
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { proxy.scrollTo(today.last?.id, anchor: .trailing) }
                }
                if let receipt = today.first(where: { $0.id == selected }) ?? today.last {
                    detail(receipt)
                }
            }
        }
    }

    private func chip(_ receipt: CookieReceipt) -> some View {
        let isSelected = receipt.id == (selected ?? machine.today.first?.id)
        return Button {
            withAnimation(CK.quick) { selected = receipt.id; confirming = false; message = nil }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(CookieTimeMachine.time.string(from: receipt.date)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                Text(receipt.app).font(.system(size: 10)).foregroundStyle(CK.secondary).lineLimit(1)
            }
            .frame(width: 74, alignment: .leading)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(isSelected ? CK.selected : CK.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain).cookiePointingCursor()
        .accessibilityLabel("\(CookieTimeMachine.plain(receipt.tool)) in \(receipt.app) at \(CookieTimeMachine.time.string(from: receipt.date))")
    }

    private func detail(_ receipt: CookieReceipt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(CookieTimeMachine.plain(receipt.tool).capitalized) · \(receipt.target)")
                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
            if receipt.file != nil {
                VStack(alignment: .leading, spacing: 3) {
                    Text(receipt.target).font(.system(size: 11.5))
                    Text("Before: \(receipt.before ?? "unknown")").font(.system(size: 11)).foregroundStyle(CK.secondary)
                    Text("After: \(receipt.after ?? "unknown")").font(.system(size: 11)).foregroundStyle(CK.secondary)
                }
            } else if let before = receipt.before, let after = receipt.after {
                ScrollView { diff(before, after).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 110)
            } else {
                Text("Before unknown: Cookie couldn't read the field first.").font(.system(size: 11)).foregroundStyle(CK.secondary)
            }
            if confirming {
                HStack(spacing: 8) {
                    Text(CookieTimeMachine.question(for: receipt)).font(.system(size: 11.5)).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Cancel") { confirming = false }.buttonStyle(WorkButtonStyle(quiet: true)).fixedSize()
                    Button("Put it back") {
                        confirming = false
                        Task { message = await machine.restore(receipt.id).message }
                    }.buttonStyle(WorkButtonStyle(primary: true)).fixedSize()
                }
            } else if machine.canRestore(receipt) {
                Button("Restore") { confirming = true; message = nil }.buttonStyle(WorkButtonStyle()).fixedSize()
            }
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(CK.secondary) }
        }
        .padding(12)
        .background(CK.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func diff(_ before: String, _ after: String) -> Text {
        CookieTimeMachine.wordDiff(before, after).reduce(Text("")) { text, run in
            let word = Text(run.text + " ")
            switch run.change {
            case .same: return text + word.foregroundColor(CK.secondary)
            case .removed: return text + word.foregroundColor(.red.opacity(0.85)).strikethrough()
            case .added: return text + word.foregroundColor(.green)
            }
        }
        .font(.system(size: 11.5))
    }
}
