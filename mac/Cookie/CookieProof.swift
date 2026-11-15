//
//  CookieProof.swift
//  Cookie
//
//  Private by proof. A ledger, on this Mac, of what Cookie saw, sent, hid,
//  did and remembered: only what kind of thing, which app, how much and where
//  to. Never the words on screen, never what you typed, never a secret. Kept
//  a week. A small pill under the notch says so the moment a picture leaves.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class CookieProof: ObservableObject {
    static let shared = CookieProof(file: defaultFile, screenMemory: .shared)

    enum Kind: String, Codable { case saw, sent, redacted, acted, remembered }
    /// What a `.sent` row carried, so the pill says "lines" for lines and "a picture" only for one.
    enum Payload: String, Codable { case screen, picture, lines, name, words }

    struct Entry: Codable, Identifiable, Equatable {
        var id: UUID
        var date: Date
        var kind: Kind
        var feature: String
        var app: String?
        var summary: String
        var destination: String?
        var bytes: Int?
        var hidden: Int
        /// Left out of rows written before payloads were kept: those read as pictures, as they were.
        var payload: Payload? = nil
        /// How many: lines, names or characters, as the payload counts them.
        var count: Int? = nil
    }

    static let keep: TimeInterval = 7 * 24 * 3600
    static let maxEntries = 2_000
    /// How long the notch pill stays after something was sent.
    static let meterSeconds: TimeInterval = 10
    static let defaultFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cookie/proof.json")

    /// Newest first.
    @Published private(set) var entries: [Entry] = []
    /// nil keeps the ledger in memory only (checks).
    private let file: URL?
    private weak var screenMemory: CookieScreenMemory?

    init(file: URL?, screenMemory: CookieScreenMemory? = nil) {
        self.file = file
        self.screenMemory = screenMemory
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved.sorted { $0.date > $1.date }
            prune()
        }
    }

    func record(_ kind: Kind, feature: String, app: String? = nil, summary: String,
                destination: String? = nil, bytes: Int? = nil, hidden: Int = 0, payload: Payload? = nil, count: Int? = nil) {
        let entry = Entry(id: UUID(), date: Date(), kind: kind, feature: feature, app: app,
                          summary: Self.clean(summary), destination: destination, bytes: bytes, hidden: hidden,
                          payload: payload, count: count)
        entries.insert(entry, at: 0)
        prune()
        save()
    }

    /// Pictures going to the model: one `.sent` row each, with its size and the model it goes to.
    func recordSent(_ images: [HarnessRequest.Image], model: String, feature: String) {
        for image in images {
            record(.sent, feature: feature, app: image.source == "screen" ? Self.frontApp : nil,
                   summary: image.source == "screen" ? Self.screenSummary : "an attached picture", destination: model,
                   bytes: Data(base64Encoded: image.data)?.count ?? image.data.count * 3 / 4,
                   payload: image.source == "screen" ? .screen : .picture)
        }
    }

    /// Words going to the model (a selection, what the pointer rests on, what Cookie read earlier):
    /// how many characters and what kind, never the words.
    func recordText(_ characters: Int, of what: String, feature: String, app: String? = nil, model: String) {
        guard characters > 0 else { return }
        record(.sent, feature: feature, app: app, summary: "\(characters) \(characters == 1 ? "character" : "characters") of \(what)",
               destination: model, bytes: characters, payload: .words, count: characters)
    }

    /// One row gone, and the copy Cookie kept of it here (the words it read off that screen).
    func forget(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        forgetLocalCopies(of: entry)
        entries.removeAll { $0.id == id }
        save()
    }

    func forgetToday() {
        let today = entries.filter { Calendar.current.isDateInToday($0.date) }
        today.forEach(forgetLocalCopies)
        entries.removeAll { Calendar.current.isDateInToday($0.date) }
        save()
    }

    var today: [Entry] { entries.filter { Calendar.current.isDateInToday($0.date) } }

    var lastMinute: (sent: Int, saw: Int) { lastMinute(now: Date()) }

    func lastMinute(now: Date) -> (sent: Int, saw: Int) {
        let recent = entries.filter { now.timeIntervalSince($0.date) < 60 }
        return (recent.filter { $0.kind == .sent }.count, recent.filter { $0.kind == .saw }.count)
    }

    /// The notch pill's words, or nil when nothing was sent in the last 10 s.
    static func meterText(_ entries: [Entry], now: Date = Date()) -> String? {
        let sent = entries.filter { $0.kind == .sent && now.timeIntervalSince($0.date) < meterSeconds }
        guard !sent.isEmpty else { return nil }
        // ponytail: hidden counts the last minute's redactions, since a circled area may be sent a while after it was checked.
        let hidden = entries.filter { $0.kind == .redacted && now.timeIntervalSince($0.date) < 60 }.reduce(0) { $0 + $1.hidden }
        let parts = [Payload.screen, .picture, .lines, .name, .words].compactMap { payload -> String? in
            let rows = sent.filter { ($0.payload ?? ($0.summary == screenSummary ? .screen : .picture)) == payload }
            guard !rows.isEmpty else { return nil }
            let total = payload == .screen || payload == .picture ? rows.count : rows.reduce(0) { $0 + max(1, $1.count ?? 1) }
            switch payload {
            case .screen: return "\(total) \(total == 1 ? "screen" : "screens")"
            case .picture: return "\(total) \(total == 1 ? "picture" : "pictures")"
            case .lines: return "\(total) \(total == 1 ? "line" : "lines")"
            case .name: return total == 1 ? "a name" : "\(total) names"
            case .words: return "\(total) \(total == 1 ? "character" : "characters")"
            }
        }
        return "Sent " + parts.joined(separator: " · ") + (hidden > 0 ? " · \(hidden) hidden" : "")
    }

    static let screenSummary = "a picture of the screen"

    /// What a summary may hold: no secrets, ever, and short.
    static func clean(_ summary: String) -> String {
        var text = summary
        for range in SensitiveText.ranges(in: text).reversed() { text.replaceSubrange(range, with: "•••") }
        return String(text.prefix(120))
    }

    private func forgetLocalCopies(of entry: Entry) {
        guard entry.kind == .saw else { return }
        screenMemory?.forget(app: entry.app, around: entry.date)
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.keep)
        entries.removeAll { $0.date < cutoff }
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
    }

    /// Written whole, owner-only, renamed into place so a crash never leaves half a file.
    // ponytail: the whole ledger per write (≤2,000 small rows); append-only when it shows up in a profile.
    private func save() {
        guard let file else { return }
        do {
            let folder = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let temporary = folder.appendingPathComponent(".proof-\(UUID().uuidString).json")
            guard FileManager.default.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(entries),
                                                 attributes: [.posixPermissions: 0o600]) else { return }
            if rename(temporary.path, file.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
        } catch {
            print("⚠️ Cookie: couldn't save the proof ledger: \(error)")
        }
    }

    static var frontApp: String? { NSWorkspace.shared.frontmostApplication?.localizedName }

    static func symbol(_ kind: Kind) -> String {
        switch kind {
        case .saw: return "eye"
        case .sent: return "arrow.up.circle"
        case .redacted: return "eye.slash"
        case .acted: return "cursorarrow.click"
        case .remembered: return "brain"
        }
    }
}

// MARK: - Notch pills

/// The small pills under the notch, one stack: a live layer first (Esc to stop it), then the canvas,
/// then Proof's meter. Each pill says whether it's showing; each takes the next free place down, and
/// moves up the moment one above it goes, so no two are ever drawn over each other.
@MainActor
final class CookieNotchStack: ObservableObject {
    enum Slot: Int, Comparable, CaseIterable {
        case layer, canvas, proof
        static func < (a: Slot, b: Slot) -> Bool { a.rawValue < b.rawValue }
    }

    static let shared = CookieNotchStack()
    static let pill: CGFloat = 22
    static let gap: CGFloat = 4

    @Published private(set) var showing: Set<Slot> = []

    /// How far below the notch a slot sits, given what's showing.
    static func offset(_ slot: Slot, showing: Set<Slot>) -> CGFloat {
        CGFloat(showing.filter { $0 < slot }.count) * (pill + gap)
    }

    /// Puts the panel in its place (or hides it when `size` is nil) and says so to the others.
    func place(_ slot: Slot, panel: NSPanel, size: CGSize?) {
        guard let size, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else {
            if showing.contains(slot) { showing.remove(slot) }
            panel.orderOut(nil)
            return
        }
        if !showing.contains(slot) { showing.insert(slot) }
        let top = (screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : NSStatusBar.system.thickness)
            + Self.offset(slot, showing: showing)
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - top - size.height - 4,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }
}

// MARK: - Notch meter

/// The pill under the notch while something was sent in the last 10 s. Its own small panel, so
/// it never takes over the island's notice or dictation states; it steps aside while the island is open.
@MainActor
final class CookieProofMeter {
    private let panel: NSPanel
    private var text: String?
    private var timer: Timer?
    private var cancellable: AnyCancellable?
    private var stacked: AnyCancellable?
    var islandOpen = false { didSet { update() } }

    init(proof: CookieProof = .shared, open: @escaping () -> Void) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = CookieWindowLevel.notch
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        cancellable = proof.$entries.receive(on: RunLoop.main).sink { [weak self] entries in
            self?.refresh(entries, open: open)
        }
        // Moves when a pill above it comes or goes.
        stacked = CookieNotchStack.shared.$showing.map { $0.subtracting([.proof]) }
            .removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.update() }
    }

    /// The pill's words from the ledger, checked again each second until the last send is 10 s old.
    private func refresh(_ entries: [CookieProof.Entry], open: @escaping () -> Void) {
        let words = CookieProof.meterText(entries)
        if words != text {
            text = words
            panel.contentView = words.map { NSHostingView(rootView: CookieProofPill(text: $0, open: open)) }
        }
        update()
        timer?.invalidate()
        guard words != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(entries, open: open) }
        }
    }

    private func update() {
        let size = text != nil && !islandOpen ? panel.contentView?.fittingSize : nil
        CookieNotchStack.shared.place(.proof, panel: panel, size: size)
    }
}

private struct CookieProofPill: View {
    let text: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(CK.text)
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(Color.black))
            .overlay(Capsule().strokeBorder(CK.hairline))
        }
        .buttonStyle(.plain)
        .cookiePointingCursor()
        .accessibilityLabel("\(text). Open Proof")
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Settings → Privacy → Proof

struct CookieProofSection: View {
    @ObservedObject var proof: CookieProof = .shared
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        let today = proof.today
        SettingsGroup(label: "Proof") {
            SettingsRow(title: today.isEmpty ? "Nothing today" : "Today", caption: "What Cookie saw, sent, hid, did and remembered, kept on this Mac for a week. Never the words themselves. Forget removes the row and what Cookie kept here; a picture already sent to your model provider can't be recalled from there.",
                        symbol: "checkmark.shield", tint: CK.accent, divider: !today.isEmpty) {
                if !today.isEmpty { PillButton(title: "Forget today") { proof.forgetToday() } }
            }
            ForEach(Array(today.enumerated()), id: \.element.id) { index, entry in
                SettingsRow(title: entry.summary, caption: caption(entry), symbol: CookieProof.symbol(entry.kind),
                            tint: entry.kind == .sent ? .orange : nil, divider: index < today.count - 1) {
                    PillButton(title: "Forget") { proof.forget(entry.id) }
                }
            }
        }
    }

    private func caption(_ entry: CookieProof.Entry) -> String {
        var parts = [Self.time.string(from: entry.date), entry.feature]
        if let app = entry.app { parts.append(app) }
        if let destination = entry.destination { parts.append("to \(destination)") }
        if entry.hidden > 0 { parts.append("\(entry.hidden) hidden") }
        if let bytes = entry.bytes { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
        if entry.kind == .sent { parts.append("can't be recalled from the provider") }
        return parts.joined(separator: " · ")
    }
}
