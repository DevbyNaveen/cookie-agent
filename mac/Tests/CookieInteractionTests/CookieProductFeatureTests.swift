import Foundation

@MainActor
enum CookieProductFeatureTests {
    static func run() {
        var turn = CookieConversationTurn(at: 0, requiresRecognizedSpeech: true, pause: 3)
        turn.transcript("Let me think", at: 1)
        precondition(turn.sample(power: 0, at: 3) == .listen)
        precondition(turn.sample(power: 0, at: 4.1) == .finish)
        var interruption = CookieSpokenInterruption()
        precondition(!interruption.accept("the current increases", reply: "Then the current increases with voltage", at: 0))
        precondition(!interruption.accept("wait", reply: "The voltage is twelve", at: 1))
        precondition(interruption.accept("wait a moment", reply: "The voltage is twelve", at: 1.5))
        interruption = CookieSpokenInterruption()
        precondition(!interruption.accept("noise", reply: "", at: 0))
        precondition(!interruption.accept("noise", reply: "", at: 1))
        let store = CookieWorkspaceStore(persistent: false), thread = UUID()
        var content = CookieArtifact.Content(); content.grid = [["Name", "Total"], [" A ", "=2+3"], [" A ", "=2+3"]]
        let original = try! store.put(thread: thread, id: "sheet", title: "Sheet", kind: .sheet, content: content, base: nil, summary: "Created")
        let receipt = store.verify(original)
        precondition(receipt.issues.isEmpty && !receipt.unverified.isEmpty)
        let alternative = try! store.makeAlternative(original)
        content.grid[1][0] = "B"
        let edited = try! store.put(thread: thread, id: alternative.id, title: alternative.title, kind: .sheet, content: content, base: alternative.current.id, summary: "Alternative")
        precondition(store.project(thread).first { $0.id == original.id }?.current == original.current)
        try! store.proposeAlternative(edited)
        precondition(store.session(thread).proposal?.outputID == original.id)
        let changed = try! store.put(thread: thread, id: original.id, title: original.title, kind: .sheet, content: content, base: original.current.id, summary: "Original updated")
        precondition(store.session(thread).receipts?[original.id]?.revision != changed.current.id)
        do { try store.proposeAlternative(edited); preconditionFailure("Stale original replaced") } catch {}
        precondition(CookieSheetWorkflow.duplicateRows(original.current.content) == [3])
        let cleaned = CookieSheetWorkflow.cleaned(original.current.content)
        precondition(cleaned.grid[1] == ["A", "=2+3"] && cleaned.grid.count == original.current.content.grid.count)
        try! store.addClip(.init(title: "Frame", text: "A useful detail", source: "Video 00:12", image: nil), thread: thread)
        precondition(store.contextTrayText(thread).contains("Video 00:12"))
        store.setSession(thread) { $0.contextClips?[0].included = false }
        precondition(store.contextTrayText(thread).isEmpty)
        do { try store.addClip(.init(title: "Huge", text: String(repeating: "a", count: 12001), source: "", image: nil), thread: thread); preconditionFailure("Unbounded context") } catch {}
        var lesson = CookieArtifact.Content()
        lesson.controls = [.init(id: "v", label: "Voltage", minimum: 0, maximum: 24, value: 12, unit: "V"), .init(id: "r", label: "Resistance", minimum: 1, maximum: 100, value: 10, unit: "Ω")]
        lesson.nodes = [.init(id: "i", label: "Current", x: 0.5, y: 0.5, formula: "=A1/A2")]
        let first = store.lessonLabel(lesson.nodes[0], content: lesson)
        lesson.controls?[0].value = 24
        precondition(first != store.lessonLabel(lesson.nodes[0], content: lesson))
        let decoded = try! JSONDecoder().decode(CookieArtifact.Content.self, from: JSONEncoder().encode(lesson))
        precondition(decoded == lesson)
        let legacy = try! JSONDecoder().decode(CookieArtifact.Content.self, from: Data("{\"nodes\":[{\"id\":\"n\",\"label\":\"Old\",\"x\":0.5,\"y\":0.5}]}".utf8))
        precondition(legacy.controls == nil && legacy.nodes[0].formula == nil)
        lesson.controls?[0].value = 25
        do { try CookieWorkspaceStore.validateBounds(lesson, kind: .diagram); preconditionFailure("Invalid lesson range accepted") } catch {}
        let script = try! CookieResolveWorkflow.markerScript(grid: [["Frame", "Name", "Note"], ["12", "Cut \"here\"", "line\nnext"]], timeline: "Demo")
        precondition(script.contains("Cut \\\"here\\\"") && script.contains("line\\nnext") && script.contains("markers[row.frame] == nil"))
        do { _ = try CookieResolveWorkflow.markerScript(grid: [["Frame", "Name"], ["1", "A"], ["1", "B"]], timeline: "Demo"); preconditionFailure("Duplicate marker accepted") } catch {}
        let session = try! JSONDecoder().decode(CookieWorkspaceSession.self, from: JSONEncoder().encode(store.session(thread)))
        precondition(session == store.session(thread))
        print("Product features: pacing, interruption policy, alternatives, receipts, context, lessons and workflows passed.")
    }
}
