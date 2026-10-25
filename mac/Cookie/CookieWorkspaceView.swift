import AppKit
import SwiftUI
import Charts
import UniformTypeIdentifiers

struct CookieWorkspaceView: View {
    @ObservedObject var store: CookieWorkspaceStore
    @ObservedObject var manager: CompanionManager
    let thread: UUID
    var showsComposer = true
    @State private var prompt = ""
    @State private var projectPanel = false
    @State private var inspector = false
    @State private var history = false
    @State private var editing = false
    @State private var draft = ""
    @State private var editBase: String?
    @State private var editTarget = ""
    @State private var cellBase: String?
    @State private var error: String?
    @State private var filter = ""
    @State private var sortColumn: Int?
    @State private var descending = false
    @State private var chart = false
    @State private var chartColumn = 1
    @State private var cellDraft = ""
    @State private var compared: CookieArtifact.Revision?
    @State private var importing = false
    @State private var scrollPosition = ScrollPosition(x: 0, y: 0)
    @State private var scrollOffset = CGPoint.zero
    @State private var selectedChartLabel: String?

    private var artifact: CookieArtifact? { store.selected(thread) }
    private var state: CookieWorkspaceSession { store.session(thread) }
    private var target: String { state.selection.components(separatedBy: " | ").first ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if state.proposedPreference != nil {
                HStack { Text("A format preference is ready to review"); Spacer(); Button("Review") { projectPanel = true } }.font(.caption).padding(10)
            }
            if let proposal = state.proposal {
                HStack { Image(systemName: "square.and.pencil"); Text(proposal.summary).lineLimit(1); Spacer(); Button("Review change") { projectPanel = true } }
                    .font(.system(size: 12)).padding(10).background(CK.accent.opacity(0.08))
            }
            if let artifact {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        outputToolbar(artifact)
                        output(artifact).frame(maxWidth: .infinity, maxHeight: .infinity)
                        if !state.selection.isEmpty {
                            HStack {
                                Image(systemName: "cursorarrow.click")
                                Text(state.selection).lineLimit(1)
                                let evidence = artifact.current.content.sources.filter { $0.target == target }
                                if evidence.isEmpty { Text("No linked evidence").foregroundStyle(CK.tertiary) }
                                else { Button("\(evidence.count) sources") { inspector = true } }
                                Spacer()
                                Button("Explain") { send("Explain the selected target in this output and highlight it while speaking.") }
                                Button { store.setSession(thread) { $0.selection = "" } } label: { Image(systemName: "xmark") }
                            }.font(.system(size: 11)).padding(8).background(CK.fill)
                        }
                    }
                    
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 32)).foregroundStyle(CK.accent)
                    Text("Make something with Cookie").font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("A website, spreadsheet, document, diagram, or 3D model.").foregroundStyle(CK.secondary)
                    Button("Import a file") { importFile() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = error ?? store.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange).padding(8).textSelection(.enabled) }
            if showsComposer {
            HStack(spacing: 10) {
                Image(systemName: "waveform").foregroundStyle(CK.accent)
                TextField("Ask for a change, or hold Control–Option to talk", text: $prompt).textFieldStyle(.plain).onSubmit { submit() }
                if manager.isWorking { Button("Stop") { manager.stopResponse() } }
                else { Button { submit() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 23)) }.disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(13).background(CK.fill, in: RoundedRectangle(cornerRadius: 16)).padding(12)
            }
        }
        .foregroundStyle(CK.text)
        .buttonStyle(CookieWorkspaceButtonStyle())
        .sheet(isPresented: $projectPanel) { CookieProjectPanel(store: store, manager: manager, thread: thread) { projectPanel = false } }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit selected content").font(.headline)
                TextEditor(text: $draft).font(.system(size: 13, design: .monospaced)).frame(minWidth: 480, minHeight: 300)
                HStack { Button("Cancel") { editing = false }; Spacer(); Button("Save version") { saveEdit() }.keyboardShortcut(.defaultAction) }
            }.padding(20)
        }
        .sheet(isPresented: $inspector) {
            if let artifact { VStack { HStack { Text("Sources and checks").font(.headline); Spacer(); Button("Done") { inspector = false } }; inspection(artifact) }.padding(20).frame(width: 380, height: 440) }
        }
        .sheet(isPresented: $history) {
            if let artifact { versions(artifact).padding(20).frame(width: 560, height: 440) }
        }
        .onDisappear { CookieHand.shared.stopTeaching(owner: store.pointerOwner) }
        .onChange(of: artifact?.id) { _, _ in filter = ""; sortColumn = nil; chart = false; compared = nil; error = nil }
        .onChange(of: target) { _, _ in updateCellDraft() }
    }
    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { store.setSession(thread) { $0.showing = false } } label: { Label(showsComposer ? "Chat" : "Close output", systemImage: showsComposer ? "bubble.left" : "sidebar.right") }
            Divider().frame(height: 16)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(store.project(thread)) { item in
                        Button {
                            store.setSession(thread) { $0.artifactID = item.id; $0.selection = ""; $0.scrollY = 0 }
                        } label: {
                            Text(item.title).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(item.id == artifact?.id ? CK.fillHover : .clear, in: Capsule())
                        }.help(item.title)
                    }
                }
            }.scrollIndicators(.hidden)
            Button { projectPanel = true } label: { Image(systemName: "slider.horizontal.3") }.help("Project, scratchpad and background work")
            Button { importFile() } label: { Image(systemName: "plus") }.help("Import output")
        }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 8)
    }
    private func outputToolbar(_ artifact: CookieArtifact) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 12) {
                Text(artifact.kind.rawValue.capitalized).foregroundStyle(CK.secondary)
                Text("Draft · v\(artifact.revisions.count)").foregroundStyle(CK.tertiary)
                if !store.staleDependencies(artifact).isEmpty { Label("Needs refresh", systemImage: "arrow.clockwise").foregroundStyle(.orange) }
                Spacer(minLength: 0)
                if artifact.kind == .html {
                    Button { store.setSession(thread) { $0.mobile.toggle() } } label: { Image(systemName: state.mobile ? "iphone" : "desktopcomputer") }.help("Phone / desktop width")
                }
                Button { draft = artifact.kind == .document ? (artifact.current.content.blocks.first { $0.id == target }?.text ?? artifact.current.content.body) : artifact.current.content.body; editBase = artifact.current.id; editTarget = target; editing = true } label: { Image(systemName: "pencil") }.disabled(![.html, .document].contains(artifact.kind)).help("Edit selected block or source")
                Button { history = true } label: { Image(systemName: "clock.arrow.circlepath") }.help("Versions and changes")
                Button { inspector.toggle() } label: { Image(systemName: "checkmark.shield") }.help("Sources, dependencies and checks")
                Menu {
                    Button("Export file…") { export(artifact, open: false) }
                    Button("Save and open in default app…") { export(artifact, open: true) }
                } label: { Image(systemName: "square.and.arrow.up") }
            }.font(.system(size: 11)).padding(.horizontal, 14)
            if artifact.kind == .sheet {
                ViewThatFits(in: .horizontal) {
                    sheetControls(artifact)
                    ScrollView(.horizontal) { sheetControls(artifact).frame(minWidth: 520) }.scrollIndicators(.hidden)
                }
            }
        }.padding(.vertical, 8).background(CK.fill.opacity(0.5))
    }
    private func sheetControls(_ artifact: CookieArtifact) -> some View {
                HStack {
                    TextField("Filter rows", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                    Button(chart ? "Grid" : "Chart") { chart.toggle() }
                    if chart {
                        Picker("Values", selection: $chartColumn) {
                            ForEach(0..<(artifact.current.content.grid.map(\.count).max() ?? 0), id: \.self) { column in Text(CookieSheet.address(0, column).filter(\.isLetter)).tag(column) }
                        }.frame(width: 100)
                    }
                    Text(target.isEmpty ? "Select a cell" : target).font(.system(size: 11, design: .monospaced))
                    TextField("Value or formula", text: $cellDraft).textFieldStyle(.roundedBorder).onSubmit { saveCell(artifact) }
                    Button("Apply") { saveCell(artifact) }.disabled(CookieSheet.coordinate(target) == nil)
                }.padding(.horizontal, 12)
    }
    @ViewBuilder private func output(_ artifact: CookieArtifact) -> some View {
        switch artifact.kind {
        case .html:
            CookieWorkspaceWeb(artifact: artifact, scrollY: state.scrollY,
                               focus: store.focusedTarget?.hasPrefix(artifact.id + ":") == true ? String(store.focusedTarget!.dropFirst(artifact.id.count + 1)) : nil,
                               onSelection: { select($0) }, onScroll: { y in store.setSession(thread) { $0.scrollY = y } },
                               onIssue: { issue in
                var issues = store.runtimeIssues[artifact.current.id] ?? []
                if issues.count < 30 && !issues.contains(issue) { issues.append(issue); store.runtimeIssues[artifact.current.id] = issues }
            }).frame(maxWidth: state.mobile ? 390 : .infinity).background(Color.white).id(artifact.id)
        case .sheet: sheet(artifact)
        case .document:
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if artifact.current.content.blocks.isEmpty { Text(artifact.current.content.body).textSelection(.enabled) }
                        ForEach(artifact.current.content.blocks) { block in
                            Text(block.text).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(target == block.id ? CK.fillHover : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .leading) { cue(artifact, block.id) }
                                .contentShape(Rectangle()).onTapGesture { select(block.id + " | " + String(block.text.prefix(300))) }.id(block.id)
                        }
                    }.padding(24).frame(maxWidth: 760)
                }.scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, point in scrollOffset = point }
                    .onScrollPhaseChange { _, phase in if phase == .idle { saveScroll() } }
                    .onAppear { scrollPosition.scrollTo(x: state.scrollX ?? 0, y: state.scrollY) }
                    .onChange(of: store.focusedTarget) { _, value in
                        if let value, value.hasPrefix(artifact.id + ":") { proxy.scrollTo(String(value.dropFirst(artifact.id.count + 1)), anchor: .center) }
                    }
            }
        case .diagram: diagram(artifact)
        case .scene: WorkspaceScene(artifact: artifact, focus: store.focusedTarget, selection: select, close: { store.setSession(thread) { $0.showing = false } })
        }
    }
    private func cue(_ artifact: CookieArtifact, _ id: String) -> some View {
        Image(systemName: "arrowtriangle.right.fill").font(.system(size: 12)).foregroundStyle(.orange)
            .opacity(store.focusedTarget == artifact.id + ":" + id ? 1 : 0).offset(x: -12)
            .background(CookieWorkspacePointer(active: store.focusedTarget == artifact.id + ":" + id, owner: store.pointerOwner))
            .allowsHitTesting(false)
    }
    private func select(_ value: String) { store.setSession(thread) { $0.selection = value; $0.selectionRevision = artifact?.current.id }; updateCellDraft() }
    private func submit() { let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }; prompt = ""; send(text) }
    private func send(_ text: String) { guard !manager.isWorking else { return }; manager.sendTypedMessage(text) }
    private func updateCellDraft() {
        cellBase = artifact?.current.id
        guard let grid = artifact?.current.content.grid, let (row, column) = CookieSheet.coordinate(target), grid.indices.contains(row), grid[row].indices.contains(column) else { cellDraft = ""; return }
        cellDraft = grid[row][column]
    }
    private func saveCell(_ artifact: CookieArtifact) {
        guard cellBase == artifact.current.id else { error = "This output changed. Select the cell again before applying your edit."; updateCellDraft(); return }
        guard let (row, column) = CookieSheet.coordinate(target), artifact.current.content.grid.indices.contains(row), column < 50 else { return }
        var content = artifact.current.content
        while content.grid[row].count <= column { content.grid[row].append("") }; content.grid[row][column] = cellDraft
        commit(artifact, content, "Edited \(target)"); updateCellDraft()
    }
    private func saveEdit() {
        guard let artifact else { return }
        guard editBase == artifact.current.id else { error = "This output changed while you were editing. Copy your draft, then reopen the editor."; return }
        var content = artifact.current.content
        if let index = content.blocks.firstIndex(where: { $0.id == editTarget }) { content.blocks[index].text = draft }
        else if !content.blocks.isEmpty { error = "Select a document block before editing."; editing = false; return }
        else { content.body = draft }
        commit(artifact, content, "Edited selected content"); editing = false
    }
    private func commit(_ artifact: CookieArtifact, _ content: CookieArtifact.Content, _ summary: String) {
        do { _ = try store.put(thread: thread, id: artifact.id, title: artifact.title, kind: artifact.kind, content: content, base: artifact.current.id, summary: summary) }
        catch { self.error = error.localizedDescription }
    }
    private func sheet(_ artifact: CookieArtifact) -> some View {
        let content = artifact.current.content, calculator = CookieSheet(grid: content.grid)
        let columns = content.grid.map(\.count).max() ?? 0
        var rows = Array(content.grid.indices).filter { filter.isEmpty || content.grid[$0].joined(separator: " ").localizedCaseInsensitiveContains(filter) }
        if let column = sortColumn {
            rows.sort { left, right in
                let lhs = calculator.display(left, column), rhs = calculator.display(right, column)
                let order = lhs.localizedStandardCompare(rhs)
                return descending ? order == .orderedDescending : order == .orderedAscending
            }
        }
        return Group {
            if chart {
                Chart(rows, id: \.self) { row in
                    if case .success(let value) = calculator.value(row: row, column: chartColumn) {
                        BarMark(x: .value("Label", calculator.display(row, 0)), y: .value("Value", value)).foregroundStyle(CK.accent)
                            .annotation(position: .top) { if store.focusedTarget == artifact.id + ":" + CookieSheet.address(row, chartColumn) { Image(systemName: "arrowtriangle.down.fill").foregroundStyle(.orange) } }
                    }
                }.chartXSelection(value: $selectedChartLabel)
                    .onChange(of: selectedChartLabel) { _, label in
                        if let label, let row = rows.first(where: { calculator.display($0, 0) == label }) { select(CookieSheet.address(row, chartColumn)) }
                    }.padding(20)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            Text("").frame(width: 38)
                            ForEach(0..<columns, id: \.self) { column in
                                Button { if sortColumn == column { descending.toggle() }; sortColumn = column } label: {
                                    Text(CookieSheet.address(0, column).filter(\.isLetter) + (sortColumn == column ? (descending ? " ↓" : " ↑") : ""))
                                        .frame(width: 140, height: 28).background(CK.fillHover)
                                }
                            }
                        }
                        ForEach(rows, id: \.self) { row in
                            HStack(spacing: 0) {
                                Text(String(row + 1)).font(.system(size: 10, design: .monospaced)).foregroundStyle(CK.tertiary).frame(width: 38)
                                ForEach(0..<columns, id: \.self) { column in
                                    let address = CookieSheet.address(row, column)
                                    Button {
                                        if NSEvent.modifierFlags.contains(.shift), CookieSheet.coordinate(target) != nil { select(target + ":" + address) }
                                        else { select(address) }
                                        updateCellDraft()
                                    } label: {
                                        Text(calculator.display(row, column)).font(.system(size: 12)).lineLimit(2)
                                            .frame(width: 124, height: 36, alignment: .leading).padding(.horizontal, 8)
                                            .background(target == address ? CK.accent.opacity(0.18) : CK.fill.opacity(row % 2 == 0 ? 0.45 : 0.15))
                                            .overlay(Rectangle().stroke(CK.hairline, lineWidth: 0.5))
                                            .overlay(alignment: .leading) { cue(artifact, address) }
                                    }.help(content.grid[row].indices.contains(column) ? content.grid[row][column] : "")
                                }
                            }
                        }
                    }
                }.scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, point in scrollOffset = point }
                    .onScrollPhaseChange { _, phase in if phase == .idle { saveScroll() } }
                    .onAppear { scrollPosition.scrollTo(x: state.scrollX ?? 0, y: state.scrollY) }
                    .onChange(of: store.focusedTarget) { _, value in
                        guard let value, value.hasPrefix(artifact.id + ":"), let (row, column) = CookieSheet.coordinate(String(value.dropFirst(artifact.id.count + 1))) else { return }
                        scrollPosition.scrollTo(x: CGFloat(max(0, column * 140 - 100)), y: CGFloat(max(0, row * 36 - 80)))
                    }
            }
        }
    }
    private func saveScroll() { store.setSession(thread) { $0.scrollY = max(0, scrollOffset.y); $0.scrollX = max(0, scrollOffset.x) } }
    private func diagram(_ artifact: CookieArtifact) -> some View {
        GeometryReader { geometry in
            let nodes = artifact.current.content.nodes
            let width = max(1, geometry.size.width - 150), height = max(1, geometry.size.height - 90)
            ZStack {
                ForEach(Array(artifact.current.content.edges.enumerated()), id: \.offset) { _, edge in
                    if let from = nodes.first(where: { $0.id == edge.from }), let to = nodes.first(where: { $0.id == edge.to }) {
                        Path { path in path.move(to: CGPoint(x: 75 + from.x * width, y: 45 + from.y * height)); path.addLine(to: CGPoint(x: 75 + to.x * width, y: 45 + to.y * height)) }.stroke(CK.secondary.opacity(0.6), lineWidth: 1.5)
                    }
                }
                ForEach(nodes) { node in
                    Button { select(node.id + " | " + node.label) } label: {
                        Text(node.label).font(.system(size: 13, weight: .medium, design: .rounded)).multilineTextAlignment(.center)
                            .padding(12).frame(width: 140).background(CK.fillHover, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(target == node.id ? CK.accent : CK.hairline))
                            .overlay(alignment: .leading) { cue(artifact, node.id) }
                    }.position(x: 75 + node.x * width, y: 45 + node.y * height)
                }
            }
        }.padding(12)
    }
    private func inspection(_ artifact: CookieArtifact) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Checks & sources").font(.headline)
                let issues = store.checks(artifact)
                Text(issues.isEmpty ? "No issues found in supported checks." : "\(issues.count) items to review").foregroundStyle(issues.isEmpty ? CK.secondary : .orange)
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in Text(issue).font(.system(size: 11)) }
                Text("Checks aren't proof of factual accuracy or full app compatibility.").font(.system(size: 10)).foregroundStyle(CK.tertiary)
                Divider()
                Text("Sources").font(.subheadline.bold())
                Text("Links are evidence to inspect, not automatic proof. A retrieval date does not guarantee a claim is still current.").font(.caption).foregroundStyle(CK.secondary)
                if artifact.current.content.sources.isEmpty { Text("No sources attached.").foregroundStyle(CK.secondary) }
                ForEach(artifact.current.content.sources) { source in
                    VStack(alignment: .leading, spacing: 3) {
                        if CookieWorkspaceStore.webURL(source.url), let url = URL(string: source.url) { Link(source.title, destination: url) }
                        else { Text(source.title) }
                        if let date = ISO8601DateFormatter().date(from: source.retrievedAt), Date().timeIntervalSince(date) > 30 * 86400 { Text("Retrieved over 30 days ago").font(.caption).foregroundStyle(.orange) }
                        Text(source.retrievedAt).font(.system(size: 10)).foregroundStyle(CK.tertiary)
                        if let target = source.target { Text(target).font(.system(size: 10, design: .monospaced)) }
                    }
                }
                Divider()
                Text("Connected outputs").font(.subheadline.bold())
                ForEach(artifact.current.content.dependencies.keys.sorted(), id: \.self) { id in
                    Button(id) { store.setSession(thread) { $0.artifactID = id; $0.selection = "" } }
                }
                if !store.staleDependencies(artifact).isEmpty { Button("Refresh from sources") { send("Refresh output \(artifact.id) using the latest revisions of its dependencies. Preserve unrelated edits and record the revisions used.") } }
            }.padding(14)
        }.font(.system(size: 12))
    }
    private func versions(_ artifact: CookieArtifact) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Versions").font(.headline); Spacer(); Button("Done") { history = false } }
            ScrollView {
                ForEach(artifact.revisions.reversed()) { revision in
                    HStack {
                        VStack(alignment: .leading) { Text(revision.summary); Text(revision.date.formatted()).font(.caption).foregroundStyle(CK.secondary) }
                        Spacer()
                        Button("Compare") { compared = revision }
                        Button("Undo change") { do { try store.undoChange(artifact, revision: revision); history = false } catch { self.error = error.localizedDescription } }.disabled(revision.id == artifact.revisions.first?.id)
                        Button("Restore") { do { try store.restore(artifact, revision: revision); history = false } catch { self.error = error.localizedDescription } }.disabled(revision.id == artifact.current.id)
                    }.padding(8)
                }
            }
            if let compared {
                Divider()
                ScrollView { Text(Self.difference(compared.content, artifact.current.content)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 150)
            }
        }
    }
    static func difference(_ before: CookieArtifact.Content, _ after: CookieArtifact.Content) -> String {
        var changes: [String] = []
        if before.body != after.body {
            let old = Set(before.body.components(separatedBy: .newlines)), new = Set(after.body.components(separatedBy: .newlines))
            changes += old.subtracting(new).sorted().prefix(40).map { "− " + $0 }
            changes += new.subtracting(old).sorted().prefix(40).map { "+ " + $0 }
        }
        for row in 0..<max(before.grid.count, after.grid.count) {
            let old = before.grid.indices.contains(row) ? before.grid[row] : [], new = after.grid.indices.contains(row) ? after.grid[row] : []
            for column in 0..<max(old.count, new.count) {
                let a = old.indices.contains(column) ? old[column] : "", b = new.indices.contains(column) ? new[column] : ""
                if a != b { changes.append("\(CookieSheet.address(row, column)): \(a) → \(b)") }
            }
        }
        for block in after.blocks where before.blocks.first(where: { $0.id == block.id }) != block { changes.append("\(block.id): \(block.text)") }
        for block in before.blocks where !after.blocks.contains(where: { $0.id == block.id }) { changes.append("Removed block: \(block.id)") }
        if before.nodes != after.nodes || before.edges != after.edges { changes.append("Diagram nodes or connectors changed.") }
        if before.sources != after.sources { changes.append("Source metadata changed.") }
        if before.dependencies != after.dependencies { changes.append("Dependency revisions changed.") }
        return changes.isEmpty ? "No content changes." : changes.prefix(100).joined(separator: "\n")
    }
    private func export(_ artifact: CookieArtifact, open: Bool) {
        let panel = NSSavePanel()
        let extensionName = artifact.kind == .sheet ? "xlsx" : artifact.kind == .html ? "html" : artifact.kind == .document ? "md" : "json"
        panel.nameFieldStringValue = artifact.title.replacingOccurrences(of: "/", with: "-") + "." + extensionName
        panel.allowedContentTypes = [UTType(filenameExtension: extensionName) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            switch artifact.kind {
            case .sheet: data = CookieWorkbookExport.data(artifact.current.content.grid)
            case .document: data = Data((artifact.current.content.blocks.isEmpty ? artifact.current.content.body : artifact.current.content.blocks.map(\.text).joined(separator: "\n\n")).utf8)
            case .html, .scene: data = Data(artifact.current.content.body.utf8)
            case .diagram: data = try JSONEncoder().encode(artifact.current.content)
            }
            try data.write(to: url, options: .atomic)
            if open { NSWorkspace.shared.open(url) }
        } catch { self.error = error.localizedDescription }
    }
    private func importFile() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.html, .plainText, .commaSeparatedText, .json, UTType(filenameExtension: "xlsx") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if url.pathExtension.lowercased() == "xlsx" {
                var content = CookieArtifact.Content(); content.grid = try CookieWorkbookImport.load(url)
                _ = try store.put(thread: thread, id: UUID().uuidString, title: url.deletingPathExtension().lastPathComponent, kind: .sheet, content: content, base: nil, summary: "Imported first worksheet")
                self.error = "Imported the first sheet. Formatting, macros and unsupported formulas are not reproduced."
                return
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 1_000_000, let text = String(data: data, encoding: .utf8) else { throw CookieWorkspaceStore.Failure("Import UTF-8 files up to 1 MB.") }
            var content = CookieArtifact.Content()
            let kind: CookieArtifact.Kind
            switch url.pathExtension.lowercased() {
            case "html", "htm": kind = .html; content.body = text
            case "csv": kind = .sheet; content.grid = try CookieWorkspaceCSV.parse(text)
            case "json": kind = .diagram; content = try JSONDecoder().decode(CookieArtifact.Content.self, from: data)
            default: kind = .document; content.body = text
            }
            _ = try store.put(thread: thread, id: UUID().uuidString, title: url.deletingPathExtension().lastPathComponent, kind: kind, content: content, base: nil, summary: "Imported file")
        } catch { self.error = error.localizedDescription }
    }
}

private struct WorkspaceScene: View {
    let artifact: CookieArtifact
    let focus: String?
    let selection: (String) -> Void
    let close: () -> Void
    @State private var stage: CookieSceneStage?
    var body: some View {
        VStack {
            if let stage {
                ScrollView([.horizontal, .vertical]) { CookieSceneView(stage: stage, onClose: close) }
                ScrollView(.horizontal) { HStack { ForEach(stage.scene.parts, id: \.id) { part in
                    Button(part.label ?? part.id) { selection(part.id); stage.focus(part.id) }
                } } }
            }
        }.task(id: artifact.current.id) {
            if let scene = CookieScene(tag: .init(kind: "SCENE", body: artifact.current.content.body, offset: 0)) {
                stage = CookieSceneStage(scene: scene, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
        }.onChange(of: focus) { _, value in
            if let value, value.hasPrefix(artifact.id + ":") { stage?.focus(String(value.dropFirst(artifact.id.count + 1))) }
        }
    }
}

enum CookieWorkspaceCSV {
    static func parse(_ text: String) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        let characters = Array(text); var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted, index + 1 < characters.count, characters[index + 1] == "\"" { field.append("\""); index += 1 }
                else { quoted.toggle() }
            } else if character == "," && !quoted { row.append(field); field = "" }
            else if (character == "\n" || character == "\r\n" || character == "\r") && !quoted { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(character) }
            index += 1
        }
        guard !quoted else { throw CookieWorkspaceStore.Failure("CSV has an unclosed quoted field.") }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

private struct CookieWorkspaceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1).cookiePointingCursor()
    }
}

private struct CookieWorkspacePointer: NSViewRepresentable {
    let active: Bool
    let owner: UUID
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        guard active else { return }
        DispatchQueue.main.async {
            guard let window = view.window, !view.visibleRect.isEmpty else { return }
            let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
            CookieHand.shared.teach(owner: owner, at: CGPoint(x: rect.minX, y: rect.midY))
        }
    }
}
