import AppKit
import SwiftUI

@MainActor
enum CookieWorkspaceTests {
    static func run() {
        testFormulasAndExports()
        testVersionsIsolationAndDependencies()
        testToolAndSources()
        testHTMLPreviewIsolation()
        testProjectReviewAndResume()
        print("5 workspace checks passed.")
    }
    static func testFormulasAndExports() {
        let grid = [["Name", "Price", "Quantity", "Total"], ["A", "12.5", "2", "=B2*C2"], ["B", "5", "4", "=B3*C3"], ["All", "", "", "=SUM(D2:D3)"]]
        let sheet = CookieSheet(grid: grid)
        precondition(sheet.value(row: 3, column: 3) == .success(45))
        precondition(CookieSheet(grid: [["=A1"]]).value(row: 0, column: 0) == .failure("#CYCLE!"))
        precondition(CookieSheet(grid: [["=1/0"]]).value(row: 0, column: 0) == .failure("#DIV/0!"))
        precondition(CookieSheet(grid: [["=SUM(1,2)*3-4/2"]]).value(row: 0, column: 0) == .success(7))
        precondition(CookieSheet(grid: [["=BOGUS(1)"]]).value(row: 0, column: 0) == .failure("#NAME?"))
        precondition(CookieSheet.coordinate("AX1000")?.1 == 49 && CookieSheet.coordinate("AY1") == nil)
        let blanks = CookieSheet(grid: [["", "10", "text", "=AVERAGE(A1:C1)", "=COUNT(A1:C1)", "=SUM(A1:A1)"]])
        precondition(blanks.value(row: 0, column: 3) == .success(10))
        precondition(blanks.value(row: 0, column: 4) == .success(1))
        precondition(blanks.value(row: 0, column: 5) == .success(0))
        // Anchored references are references.
        precondition(CookieSheet(grid: [["2", "3", "=$A$1*B$1+$A1"]]).value(row: 0, column: 2) == .success(8))
        // A range's errors are the total's error; its text is left out.
        precondition(CookieSheet(grid: [["=1/0", "5", "=SUM(A1:B1)"]]).value(row: 0, column: 2) == .failure("#DIV/0!"))
        precondition(CookieSheet(grid: [["=A2*2", "4", "=SUM(A1:B1)"], ["n/a"]]).value(row: 0, column: 2) == .failure("#VALUE!"))
        // A thousand rows under a row of full-column totals evaluate whole.
        var long = (1...1000).map { [String($0)] + Array(repeating: "", count: 20) }
        long.append(Array(repeating: "=SUM($A$1:$A$1000)", count: 21))
        let longSheet = CookieSheet(grid: long)
        precondition((0..<21).allSatisfy { longSheet.value(row: 1000, column: $0) == .success(500500) }, "full-column totals must not hit the work limit")
        // What reads back differently stays text.
        precondition(!CookieWorkbookExport.isPlainNumber("007") && !CookieWorkbookExport.isPlainNumber("+15551234") && !CookieWorkbookExport.isPlainNumber("1e3"))
        precondition(CookieWorkbookExport.isPlainNumber("12.5") && CookieWorkbookExport.isPlainNumber("-3"))
        // Shared formulas move with their cell; anchors and quoted text don't.
        precondition(CookieWorkbookImport.shift("B2*C2", rows: 1, columns: 0) == "B3*C3")
        precondition(CookieWorkbookImport.shift("$B$2*C2&\"A1\"", rows: 2, columns: 1) == "$B$2*D4&\"A1\"")
        precondition(CookieWorkbookImport.shift("SUM(A1:A3)+LOG10(B$1)", rows: 1, columns: 0) == "SUM(A2:A4)+LOG10(B$1)")
        precondition(CookieWorkbookImport.shift("A1", rows: 0, columns: -1) == "#REF!")
        func xml(_ text: String) -> Data { Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + text).utf8) }
        let workbook = xml("<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Totals\" sheetId=\"3\" r:id=\"rId3\"/><sheet name=\"Old\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>")
        let rels = xml("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"x\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId3\" Type=\"x\" Target=\"worksheets/sheet3.xml\"/></Relationships>")
        precondition(CookieWorkbookImport.firstSheetPath(workbook: workbook, relationships: rels) == "xl/worksheets/sheet3.xml", "the first tab, not the first file")
        precondition(CookieWorkbookImport.firstSheetPath(workbook: workbook, relationships: xml("<Relationships><Relationship Id=\"rId3\" Target=\"../../secret.xml\"/></Relationships>")) == nil)
        let filled = xml("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
            + "<row r=\"1\"><c r=\"A1\"><v>2</v></c><c r=\"B1\"><v>3</v></c><c r=\"C1\"><f t=\"shared\" ref=\"C1:C3\" si=\"0\">A1*B1</f><v>6</v></c></row>"
            + "<row r=\"2\"><c r=\"A2\"><v>4</v></c><c r=\"B2\"><v>5</v></c><c r=\"C2\"><f t=\"shared\" si=\"0\"/><v>20</v></c></row>"
            + "<row r=\"3\"><c r=\"A3\"><v>6</v></c><c r=\"B3\"><v>7</v></c><c r=\"C3\"><f t=\"shared\" si=\"0\"/><v>42</v></c><c r=\"D3\"><f t=\"array\" ref=\"D3:E3\">A1:B1*2</f><v>4</v></c><c r=\"E3\"><v>6</v></c></row>"
            + "</sheetData></worksheet>")
        let book = CookieWorkbookExport.zip([("xl/workbook.xml", workbook), ("xl/_rels/workbook.xml.rels", rels), ("xl/worksheets/sheet3.xml", filled),
                                             ("xl/worksheets/sheet1.xml", xml("<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>wrong tab</t></is></c></row></sheetData></worksheet>"))])
        let bookURL = FileManager.default.temporaryDirectory.appendingPathComponent("cookie-shared-\(UUID().uuidString).xlsx")
        try! book.write(to: bookURL); defer { try? FileManager.default.removeItem(at: bookURL) }
        let imported = try! CookieWorkbookImport.load(bookURL)
        precondition(imported[1][2] == "=A2*B2" && imported[2][2] == "=A3*B3", "filled-down formulas stay formulas")
        precondition(imported[2][3] == "=ARRAY()" && imported[2][4] == "=ARRAY()", "an array formula's cells are never frozen numbers")
        precondition(CookieSheet(grid: imported).value(row: 2, column: 2) == .success(42))
        let parsed = try! CookieWorkspaceCSV.parse("Name,Note\r\n\"A,B\",\"line1\nline2\"\r\n")
        precondition(parsed == [["Name", "Note"], ["A,B", "line1\nline2"]])
        do { _ = try CookieWorkspaceCSV.parse("\"unclosed"); preconditionFailure("Malformed CSV accepted") } catch {}
        let data = CookieWorkbookExport.data(grid + [["007", "+15551234", "", ""]])
        precondition(data.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04]))
        try! data.write(to: URL(fileURLWithPath: "/tmp/cookie-workspace-test.xlsx"))
        precondition(try! CookieWorkbookImport.load(URL(fileURLWithPath: "/tmp/cookie-workspace-test.xlsx")) == grid + [["007", "+15551234", "", ""]])
    }
    static func testVersionsIsolationAndDependencies() {
        let store = CookieWorkspaceStore(persistent: false), thread = UUID(), other = UUID()
        var content = CookieArtifact.Content(); content.blocks = [.init(id: "intro", text: "First")]
        let original = try! store.put(thread: thread, id: "brief", title: "Brief", kind: .document, content: content, base: nil, summary: "Created")
        content.blocks[0].text = "Second"
        let edited = try! store.put(thread: thread, id: "brief", title: "Brief", kind: .document, content: content, base: original.current.id, summary: "Changed")
        do { _ = try store.put(thread: thread, id: "brief", title: "Brief", kind: .document, content: content, base: original.current.id, summary: "Stale"); preconditionFailure("Stale edit accepted") } catch {}
        precondition(store.project(other).isEmpty && store.project(thread)[0].revisions.count == 2)
        var derived = CookieArtifact.Content(); derived.body = "Summary"; derived.dependencies = ["brief": original.current.id]
        let summary = try! store.put(thread: thread, id: "summary", title: "Summary", kind: .document, content: derived, base: nil, summary: "Derived")
        precondition(store.staleDependencies(summary) == ["Brief"])
        content.dependencies = ["summary": summary.current.id]
        do { _ = try store.put(thread: thread, id: "brief", title: "Brief", kind: .document, content: content, base: edited.current.id, summary: "Cycle"); preconditionFailure("Dependency cycle accepted") } catch {}
        try! store.restore(edited, revision: original.current)
        precondition(store.project(thread)[0].current.content == original.current.content)
        precondition(store.project(thread)[0].revisions.count == 3)
        precondition(CookieWorkspaceView.difference(original.current.content, edited.current.content).contains("Second"))
        store.setSession(thread) { $0.artifactID = "brief"; $0.selection = "intro"; $0.scrollY = 120; $0.showing = false }
        precondition(store.session(thread).selection == "intro" && store.session(other).selection.isEmpty)
        var cells = CookieArtifact.Content(); cells.grid = [["1", "2"]]
        let first = try! store.put(thread: thread, id: "cells", title: "Cells", kind: .sheet, content: cells, base: nil, summary: "Initial")
        cells.grid[0][0] = "3"
        let second = try! store.put(thread: thread, id: "cells", title: "Cells", kind: .sheet, content: cells, base: first.current.id, summary: "A1")
        cells.grid[0][1] = "4"
        let third = try! store.put(thread: thread, id: "cells", title: "Cells", kind: .sheet, content: cells, base: second.current.id, summary: "B1")
        try! store.undoChange(third, revision: second.current)
        precondition(store.project(thread).first { $0.id == "cells" }!.current.content.grid == [["1", "4"]])
        try! store.removeProject(other)
        precondition(store.project(thread).count == 3)
        try! store.removeProject(thread)
        precondition(store.project(thread).isEmpty && store.session(thread).selection.isEmpty)

    }
    static func testToolAndSources() {
        let store = CookieWorkspaceStore(persistent: false), thread = UUID()
        let result = CookieWorkspaceTool.perform(["action": "put", "payload": #"{"id":"leads","title":"Leads","kind":"sheet","content":{"grid":[["Name","Source"],["Unknown",""]],"sources":[{"id":"s1","title":"Bad","url":"file:///secret","retrievedAt":"yesterday"}]}}"#], thread: thread, store: store)
        precondition(!result.1)
        precondition(store.checks(store.project(thread)[0]).contains(where: { $0.contains("valid web URL") }))
        precondition(CookieWorkspaceTool.perform(["action": "read", "payload": "{\"id\":\"leads\"}"], thread: UUID(), store: store).1)
        precondition(CookieWorkspaceTool.perform(["action": "put", "payload": "invalid"], thread: thread, store: store).1)
        precondition(CookieReplyTags.split("This [WORK:leads:A1]cell").spoken == "This cell")
        var invalid = CookieArtifact.Content(); invalid.grid = [Array(repeating: "x", count: 51)]
        do { try CookieWorkspaceStore.validateBounds(invalid, kind: .sheet); preconditionFailure("Oversize grid accepted") } catch {}
    }
    static func testHTMLPreviewIsolation() {
        var content = CookieArtifact.Content()
        content.body = """
        <h1 id="heading">Preview works</h1><button id="test" onclick="top.postMessage({selection:'forged'},'*');top.postMessage({issue:'clicked'},'*')">Click</button>
        <script>window.parent={postMessage(){}};addEventListener('DOMContentLoaded',()=>{document.getElementById('test').click();fetch('https://example.invalid/blocked').then(()=>top.postMessage({issue:'NETWORK ESCAPED'},'*')).catch(()=>top.postMessage({issue:'network-blocked'},'*'));});</script>
        """
        let artifact = CookieArtifact(id: "html-test", threadID: UUID(), title: "Test", kind: .html, revisions: [.init(summary: "Test", content: content)])
        var clicked = false, blocked = false, escaped = false, forged = false
        let view = CookieWorkspaceWeb(artifact: artifact, scrollY: 0, focus: nil,
            onSelection: { _ in forged = true },
            onScroll: { _ in }, onIssue: { clicked = clicked || $0 == "clicked"; blocked = blocked || $0 == "network-blocked"; escaped = escaped || $0 == "NETWORK ESCAPED" })
        let hosting = NSHostingView(rootView: view.frame(width: 500, height: 300))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; hosting.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(12)
        while !(clicked && blocked) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        window.close()
        precondition(clicked && blocked && !escaped, "HTML must execute local interactions but block network access")
        precondition(!forged, "a selection without a real click must never reach the model")
        var gate = CookieClickGate()
        precondition(!gate.take(now: 5), "no click, no selection")
        gate.click(at: 10)
        precondition(gate.take(now: 10.2) && !gate.take(now: 10.3), "one click, one selection")
        gate.click(at: 20)
        precondition(!gate.take(now: 21.5), "a stale click doesn't count")
        print("Workspace HTML interaction and network-isolation check passed.")
    }

    static func testProjectReviewAndResume() {
        let store = CookieWorkspaceStore(persistent: false), thread = UUID()
        var content = CookieArtifact.Content(); content.grid = [["Category", "Amount"], ["Rent", "100"]]
        let artifact = try! store.put(thread: thread, id: "budget", title: "Budget", kind: .sheet, content: content, base: nil, summary: "Created")
        store.setSession(thread) { $0.selection = "A2"; $0.selectionRevision = artifact.current.id; $0.checkpoint = "Next: review rent"; $0.assistance = .teach }
        precondition(store.referenceIsCurrent(thread))
        content.grid[1][1] = "200"
        try! store.propose(thread: thread, artifact: artifact, content: content, base: artifact.current.id, title: "Budget", summary: "Change rent")
        precondition(store.selected(thread)!.current.content.grid[1][1] == "100", "A proposal must not change the original")
        let (_, failed) = CookieWorkspaceTool.perform(["action": "checkpoint", "payload": #"{"summary":"Rows 1-40 verified","nextStep":"pricing column"}"#], thread: thread, store: store)
        precondition(!failed)
        try! store.acceptProposal(thread)
        precondition(store.selected(thread)!.current.content.grid[1][1] == "200" && store.session(thread).proposal == nil)
        store.setSession(thread) { $0.activity = "Updated workspace" }
        precondition(store.session(thread).checkpoint == "Rows 1-40 verified" && store.session(thread).nextStep == "pricing column", "only the checkpoint action writes the checkpoint")
        precondition(store.context(thread).contains("Rows 1-40 verified"), "resuming starts from the model's own checkpoint")
        precondition(!store.referenceIsCurrent(thread), "Changed row must invalidate old reference")
        do { try store.propose(thread: thread, artifact: store.selected(thread)!, content: content, base: artifact.current.id, title: "Budget", summary: "Stale"); preconditionFailure("Stale proposal accepted") } catch {}
        let oldSession = try! JSONDecoder().decode(CookieWorkspaceSession.self, from: Data(#"{"selection":"","scrollY":0,"mobile":false,"showing":false}"#.utf8))
        precondition(oldSession.assistance == nil && oldSession.proposal == nil)
        let saved = try! JSONDecoder().decode(CookieWorkspaceSession.self, from: JSONEncoder().encode(store.session(thread)))
        precondition(saved == store.session(thread))
        precondition(CompanionManager.visibleReply("Before\n\n[CARD {\"x\":1}]\n\nAfter") == "Before\n\nAfter")
        precondition(CookieRequestMode.choose("Take these features and explain the diagram", selection: false, visual: false) == .screen)
        precondition(!CompanionManager.pictureFailed(CookieReplyTags.split("A sequence diagram shows messages over time.").tags, shown: false), "mentioning a diagram is not a failed one")
        precondition(CompanionManager.pictureFailed(CookieReplyTags.split("Here [CARD {\"kind\":\"bogus\"}] it is.").tags, shown: false))
        precondition(!CompanionManager.pictureFailed(CookieReplyTags.split("Here [CARD {\"kind\":\"bogus\"}] it is.").tags, shown: true))
        precondition(CookieRequestMode.refersToPrevious("Explain that one"))
        precondition(!CookieRequestMode.refersToPrevious("Research manufacturers"))
    }

    static func render() {
        let store = CookieWorkspaceStore(persistent: false), thread = UUID()
        var content = CookieArtifact.Content()
        content.grid = [["Company", "Seats", "Monthly", "Annual"], ["Northwind", "12", "29", "=B2*C2*12"], ["Contoso", "8", "29", "=B3*C3*12"], ["Total", "", "", "=SUM(D2:D3)"]]
        _ = try! store.put(thread: thread, id: "forecast", title: "Revenue forecast", kind: .sheet, content: content, base: nil, summary: "Created forecast")
        for width: CGFloat in [900, 600] {
        let view = CookieWorkspaceView(store: store, manager: CompanionManager(), thread: thread)
            .frame(width: width, height: 550).background(CK.island).environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 550), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        hosting.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/cookie-workspace-preview-\(Int(width)).png"))
        window.close()
        }
    }
}
