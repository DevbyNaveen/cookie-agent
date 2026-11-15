import AppKit

/// Time machine: word diffs read right; receipts keep a week, owner-only, never a secret; snapshots
/// respect their caps; a text restore refuses a changed field; a file round-trips with the current
/// version kept; the Mac tools and the model's tool are really wired to it.
@MainActor
enum CookieTimeMachineTests {
    static func run() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cookie-time-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }

        // Word diff: kept, taken out, put in, in order; both sides rebuild exactly.
        let runs = CookieTimeMachine.wordDiff("the quick brown fox", "the slow brown fox jumps")
        check(runs.map(\.change) == [.same, .removed, .added, .same, .added]
              && runs.map(\.text) == ["the", "quick", "slow", "brown fox", "jumps"], "\(runs)")
        let before = runs.filter { $0.change != .added }.map(\.text).joined(separator: " ")
        let after = runs.filter { $0.change != .removed }.map(\.text).joined(separator: " ")
        check(before == "the quick brown fox" && after == "the slow brown fox jumps", "diff rebuilds both sides")
        check(CookieTimeMachine.wordDiff("", "hello").map(\.change) == [.added]
              && CookieTimeMachine.wordDiff("same words", "same words").map(\.change) == [.same], "empty and unchanged")

        // Store: newest first, 0600, read back; secrets masked, 20 KB bound; one .acted proof row, no content.
        let proof = CookieProof(file: nil)
        let store = folder.appendingPathComponent("store")
        let machine = CookieTimeMachine(folder: store, proof: proof)
        machine.recordText(tool: "set_value", app: "Notes", target: "Title", before: "Draft", after: "Final", field: nil)
        machine.recordText(tool: "type_text", app: "Mail", target: "the focused field", before: "",
                           after: "key sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123 " + String(repeating: "a", count: 30_000), field: nil)
        let ledger = store.appendingPathComponent("time-machine.json")
        let mode = (try? FileManager.default.attributesOfItem(atPath: ledger.path)[.posixPermissions] as? Int) ?? 0
        check(machine.receipts.map(\.app) == ["Mail", "Notes"] && mode == 0o600, "newest first, owner-only: \(String(mode, radix: 8))")
        check(CookieTimeMachine(folder: store, proof: proof).receipts == machine.receipts, "persists and reads back")
        let typed = machine.receipts[0].after ?? ""
        check(!typed.contains("sk-ant") && typed.contains("•••") && typed.count <= CookieTimeMachine.maxText + 1, "masked and bounded")
        check(!machine.receipts[0].restorable, "a bounded field isn't restorable")
        check(proof.entries.count == 2 && proof.entries.allSatisfy { $0.kind == .acted && $0.feature == "time machine" }
              && !proof.entries.contains { $0.summary.contains("Final") || $0.summary.contains("Draft") }, "proof rows carry no content")
        var old = machine.receipts[1]
        old.id = UUID()
        old.date = Date().addingTimeInterval(-8 * 24 * 3600)
        try? JSONEncoder().encode(machine.receipts + [old]).write(to: ledger)
        check(!CookieTimeMachine(folder: store, proof: proof).receipts.contains { $0.id == old.id }, "older than a week is dropped")

        // Text restore: refuses a field that changed since; otherwise writes the exact before back and keeps a receipt of that.
        var value = "Hello Anna"
        let field = CookieTimeMachine.Field(read: { value }, write: { value = $0; return true })
        let memory = CookieTimeMachine(folder: nil, proof: proof)
        let edit = memory.recordText(tool: "set_value", app: "Notes", target: "Greeting", before: "Hi Anna", after: "Hello Anna", field: field)
        value = "Hello Anna, see you"
        let refused = await memory.restore(edit.id)
        check(!refused.success && value == "Hello Anna, see you", "a changed field is left alone: \(refused.message)")
        value = "Hello Anna"
        let restored = await memory.restore(edit.id)
        check(restored.success && value == "Hi Anna" && memory.receipts[0].tool == "restore", "restored: \(restored.message)")
        check(CookieTimeMachine.question(for: edit).hasPrefix("Put Greeting in Notes back to"), CookieTimeMachine.question(for: edit))

        // Files: copy before, restore after a yes, the current version kept as its own snapshot.
        let document = folder.appendingPathComponent("Budget.numbers")
        try? "version one".write(to: document, atomically: true, encoding: .utf8)
        let files = CookieTimeMachine(folder: folder.appendingPathComponent("files"), proof: proof, maxFileBytes: 1_000, maxSnapshotBytes: 25)
        let first = files.snapshotBefore(document, tool: "run_script", app: "Numbers")
        try? "version two".write(to: document, atomically: true, encoding: .utf8)
        files.finishSnapshot(first.id)
        check(first.restorable && first.before != nil && files.receipts[0].after != nil && files.canRestore(first), "snapshot taken")
        check(CookieTimeMachine.question(for: first).hasPrefix("Put Budget.numbers back to"), "approval wording names the file")
        let back = await files.restore(first.id)
        check(back.success && (try? String(contentsOf: document, encoding: .utf8)) == "version one", "file restored: \(back.message)")
        let kept = files.receipts.first { $0.tool == "restore" }
        check(kept?.snapshot.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } == "version two", "current version kept first")
        // 1 GB cap (25 bytes here): a third copy pushes it over; the oldest snapshot goes, its receipt stays but can't restore.
        files.snapshotBefore(document, tool: "run_script", app: "Numbers")
        check(files.receipts.last?.snapshot == nil && files.receipts.last?.restorable == false
              && !FileManager.default.fileExists(atPath: first.snapshot ?? ""), "oldest snapshot pruned over the cap")
        let big = folder.appendingPathComponent("Huge.xlsx")
        try? Data(repeating: 1, count: 2_000).write(to: big)
        let tooBig = files.snapshotBefore(big, tool: "run_script", app: "Microsoft Excel")
        check(tooBig.snapshot == nil && tooBig.before == nil && !tooBig.restorable, "over 50 MB (1 KB here): before unknown")

        // The Mac tools' hook: a text write leaves a receipt; a failed one doesn't; a script with no document still says so.
        let hooked = CookieTimeMachine(folder: nil, proof: proof)
        var reads = ["old title", "new title"]
        let element = AXUIElementCreateApplication(getpid())
        _ = await MacOperator.withReceipt("set_value", app: "Pages", target: "Title", field: element, machine: hooked,
                                          read: { _ in reads.removeFirst() }, write: { _, _ in true }) { ("Set.", false) }
        check(hooked.receipts.first.map { $0.tool == "set_value" && $0.before == "old title" && $0.after == "new title" && $0.restorable } == true,
              "set_value leaves a restorable receipt")
        _ = await MacOperator.withReceipt("type_text", app: "Pages", target: "the focused field", field: nil, machine: hooked) { ("Typed 3 characters.", false) }
        check(hooked.receipts[0].before == nil && !hooked.receipts[0].restorable, "an unreadable field: before unknown, still recorded")
        _ = await MacOperator.withReceipt("type_text", app: "Pages", target: "x", field: nil, machine: hooked) { ("No.", true) }
        check(hooked.receipts.count == 2, "a failed write leaves no receipt")
        _ = MacOperator.withSnapshot("run_script", app: "Keynote", document: nil, machine: hooked) { ("Done.", false) }
        check(hooked.receipts[0].tool == "run_script" && hooked.receipts[0].before == nil, "a script with no resolvable document says before unknown")
        let mac = (try? String(contentsOfFile: "Cookie/CookieMac.swift", encoding: .utf8)) ?? ""
        check(["case \"set_value\": result = await Self.withReceipt(", "case \"type_text\": result = await Self.withReceipt(",
               "case \"replace_selection\": result = await Self.withReceipt(", ": Self.withSnapshot(name, app: target, document: target.flatMap(Self.frontDocument))"]
              .allSatisfy(mac.contains), "MacOperator.perform routes its writes through the time machine")

        // The model's tool: outbound, registered and dispatched; looking needs no card, restoring does.
        check(CookieTimeMachineTool.tool.effect == "outbound" && CookieTimeMachineTool.tool.name == "time_machine", "restore asks")
        let harness = (try? String(contentsOfFile: "Cookie/HarnessClient.swift", encoding: .utf8)) ?? ""
        check(harness.contains("CookieTimeMachineTool.tool] + MacOperator.tools") && harness.contains("await CookieTimeMachineTool.perform(args)"),
              "registered in every run and dispatched")
        let list = await CookieTimeMachineTool.perform(["action": "list", "query": "Pages"], machine: hooked, proof: proof)
        check(!list.1 && list.0.contains("set value · Pages · Title"), list.0)
        let id = String(hooked.receipts.last!.id.uuidString.prefix(8))
        let shown = await CookieTimeMachineTool.perform(["action": "show", "id": id], machine: hooked, proof: proof)
        check(shown.0.contains("before: old title") && proof.entries[0].kind == .sent, "show names the before, and it's proof")
        reads = ["new title", "old title"]
        let undone = await CookieTimeMachineTool.perform(["action": "restore", "id": id], machine: hooked, proof: proof)
        check(!undone.1, "restore through the tool: \(undone.0)")
        let look = HarnessAction(tool: "time_machine", effect: "outbound", preview: #"time_machine {"action":"list"}"#, reason: "")
        let put = HarnessAction(tool: "time_machine", effect: "outbound", preview: #"time_machine {"action":"restore","id":"\#(id)"}"#, reason: "")
        check(CookieTimeMachineTool.answersForYou(HarnessApproval(id: "a", actions: [look]))
              && !CookieTimeMachineTool.answersForYou(HarnessApproval(id: "b", actions: [put])), "only a restore shows a card")
        check(CookieTimeMachineTool.question(for: put, machine: hooked)?.hasPrefix("Put Title in Pages back to") == true, "the card's words")
        print("\(checks) time machine checks passed.")
    }
}
