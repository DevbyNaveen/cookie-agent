import AppKit

/// Private by proof: the ledger keeps a week, at most 2,000 rows, owner-only on disk, never a
/// secret; Forget takes Cookie's own copy with it; the hooks really write to it.
@MainActor
enum CookieProofTests {
    static func run() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cookie-proof-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("proof.json")
        let memory = CookieScreenMemory(connected: false)
        let proof = CookieProof(file: file, screenMemory: memory)

        // Recorded newest first, written 0600, read back the same.
        proof.record(.saw, feature: "screen look", app: "Safari", summary: "the screen", bytes: 1_000)
        proof.record(.sent, feature: "screen look", app: "Safari", summary: CookieProof.screenSummary, destination: "anthropic:claude-sonnet-4-6", bytes: 900)
        proof.record(.saw, feature: "hover", app: "Mail", summary: "an area of the screen")
        precondition(proof.entries.map(\.feature) == ["hover", "screen look", "screen look"], "newest first")
        let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0
        precondition(mode == 0o600, "the ledger is owner-only: \(String(mode, radix: 8))")
        precondition(CookieProof(file: file).entries == proof.entries, "persists and reads back")

        // A secret can't ride in a summary.
        proof.record(.acted, feature: "Mac action", summary: "typed sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123 into Terminal")
        precondition(!proof.entries[0].summary.contains("sk-ant"), "masked: \(proof.entries[0].summary)")
        precondition(proof.entries[0].summary.contains("•••"))

        // The meter: what the last minute holds; the pill only for 10 s after a send.
        precondition(proof.lastMinute == (sent: 1, saw: 2), "\(proof.lastMinute)")
        precondition(proof.lastMinute(now: Date().addingTimeInterval(61)) == (sent: 0, saw: 0))
        proof.record(.redacted, feature: "screen look", app: "Safari", summary: "2 private items hidden on this Mac", hidden: 2)
        precondition(CookieProof.meterText(proof.entries) == "Sent 1 screen · 2 hidden", "\(CookieProof.meterText(proof.entries) ?? "nil")")
        precondition(CookieProof.meterText(proof.entries, now: Date().addingTimeInterval(11)) == nil, "the pill goes after 10 s")

        // Forget one row: Cookie's copy of what it read in that app that minute goes too, nothing else.
        memory.add(ScreenMemoryEntry(date: Date(), app: "Mail", text: "words read off the Mail window"))
        memory.add(ScreenMemoryEntry(date: Date(), app: "Notes", text: "words read off the Notes window"))
        let mailLook = proof.entries.first { $0.app == "Mail" }!
        proof.forget(mailLook.id)
        precondition(!proof.entries.contains { $0.id == mailLook.id })
        precondition(memory.entries.map(\.app) == ["Notes"], "\(memory.entries.map(\.app))")
        precondition(CookieProof(file: file).entries == proof.entries, "a forgotten row is gone from disk")

        // Forget today leaves earlier days; a week and 2,000 rows are the limits.
        let yesterday = CookieProof.Entry(id: UUID(), date: Date().addingTimeInterval(-26 * 3600), kind: .saw, feature: "screen look",
                                          app: nil, summary: "the screen", destination: nil, bytes: nil, hidden: 0)
        var old = yesterday
        old.id = UUID()
        old.date = Date().addingTimeInterval(-8 * 24 * 3600)
        var many = (0..<2_005).map { index -> CookieProof.Entry in
            var entry = yesterday
            entry.id = UUID()
            entry.date = Date().addingTimeInterval(-26 * 3600 - Double(index))
            return entry
        }
        many.append(old)
        try? JSONEncoder().encode(many).write(to: file)
        let reloaded = CookieProof(file: file)
        precondition(reloaded.entries.count == CookieProof.maxEntries, "\(reloaded.entries.count)")
        precondition(!reloaded.entries.contains { $0.id == old.id }, "older than a week is dropped")
        precondition(reloaded.entries.first?.id == many[0].id, "the newest are kept")
        reloaded.record(.saw, feature: "screen look", summary: "the screen")
        reloaded.forgetToday()
        precondition(reloaded.today.isEmpty && reloaded.entries.count == CookieProof.maxEntries - 1, "only today is forgotten")

        // The hooks write to it: a Mac action, a look with hidden items, pictures sent to a model.
        let hooked = CookieProof(file: nil)
        MacOperator.log("press", app: "Mail", element: "Send to Alice", ok: true, task: "send the note", folder: folder, proof: hooked)
        precondition(hooked.entries.first.map { $0.kind == .acted && $0.app == "Mail" && $0.summary == "press" } == true, "a Mac action is proof")
        precondition(!hooked.entries[0].summary.contains("Alice"), "never the element's words")
        precondition((try? String(contentsOf: folder.appendingPathComponent("actions.jsonl"), encoding: .utf8))?.contains("\"press\"") == true)
        CompanionScreenCaptureUtility.recordProof(feature: "circle", summary: "an area of the screen", bytes: 500, hidden: 3, into: hooked)
        precondition(hooked.entries.prefix(2).map(\.kind) == [.redacted, .saw] && hooked.entries[0].hidden == 3, "a look and what it hid")
        let picture = Data(repeating: 7, count: 300)
        hooked.recordSent([.init(media_type: "image/jpeg", data: picture.base64EncodedString(), source: "screen", caption: "")],
                          model: "anthropic:claude-sonnet-4-6", feature: "hover")
        precondition(hooked.entries[0].kind == .sent && hooked.entries[0].destination == "anthropic:claude-sonnet-4-6"
                     && hooked.entries[0].bytes == 300, "a sent picture names the model and its size")
        // The pill names what went: words aren't pictures.
        let words = CookieProof(file: nil)
        words.record(.sent, feature: "screen layer", app: "Safari", summary: "12 lines of the window as text, no picture",
                     destination: "test:model", bytes: 400, payload: .lines, count: 12)
        precondition(CookieProof.meterText(words.entries) == "Sent 12 lines", "\(CookieProof.meterText(words.entries) ?? "nil")")
        words.record(.sent, feature: "memory cursor", summary: "a person to look up", destination: "Enkeon", payload: .name, count: 1)
        words.recordText(230, of: "the text you had selected", feature: "question", model: "test:model")
        words.recordText(0, of: "nothing", feature: "hover", model: "test:model")
        precondition(CookieProof.meterText(words.entries) == "Sent 12 lines · a name · 230 characters", "\(CookieProof.meterText(words.entries) ?? "nil")")
        precondition(words.entries.count == 3 && words.entries[0].summary == "230 characters of the text you had selected"
                     && words.entries[0].payload == .words, "text sent is counted, never quoted; nothing sent, no row")
        // Rows from before payloads were kept still read (as pictures, which is all they were).
        let legacy = #"[{"id":"\#(UUID().uuidString)","date":\#(Date().timeIntervalSinceReferenceDate),"kind":"sent","feature":"hover","summary":"an attached picture","hidden":0}]"#
        let legacyFile = folder.appendingPathComponent("legacy.json")
        try? Data(legacy.utf8).write(to: legacyFile)
        precondition(CookieProof.meterText(CookieProof(file: legacyFile).entries) == "Sent 1 picture", "old rows decode")
        // What the model saves and what text goes up are proof too.
        let harness = (try? String(contentsOfFile: "Cookie/HarnessClient.swift", encoding: .utf8)) ?? ""
        precondition(harness.contains("record(.remembered") && harness.contains("CookieScreenMemory.shared.answer") && harness.contains("recordText("),
                     "the model's remember and recall_screen's words are proof")
        let manager = (try? String(contentsOfFile: "Cookie/CompanionManager.swift", encoding: .utf8)) ?? ""
        let hover = (try? String(contentsOfFile: "Cookie/CookieHover.swift", encoding: .utf8)) ?? ""
        precondition(manager.contains("recordText(selection.text.count") && hover.contains("recordText(reading.context.count"),
                     "selected text and hover's words are proof")
        print("8 proof checks passed.")
    }
}
