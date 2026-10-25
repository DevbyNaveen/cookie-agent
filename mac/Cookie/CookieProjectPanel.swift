import SwiftUI

struct CookieProjectPanel: View {
    @ObservedObject var store: CookieWorkspaceStore
    @ObservedObject var manager: CompanionManager
    @ObservedObject private var jobs = CookieProjectJobs.shared
    let thread: UUID
    let close: () -> Void
    @State private var brief = ""
    @State private var preference = ""
    @State private var problem: String?
    @State private var scratch = false
    private var session: CookieWorkspaceSession { store.session(thread) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Your project").font(.system(size: 20, weight: .semibold, design: .rounded)); Spacer(); Button("Done", action: close) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("How should Cookie help?", selection: Binding(get: { session.assistance ?? .together }, set: { mode in store.setSession(thread) { $0.assistance = mode } })) {
                        ForEach(CookieAssistance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Text((session.assistance ?? .together).guidance).font(.caption).foregroundStyle(CK.secondary)
                    GroupBox("Continue where you stopped") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(session.checkpoint ?? "Start with an idea, or select an existing output.").textSelection(.enabled)
                            if let activity = session.activity, !activity.isEmpty { Text("Latest: \(activity)").font(.caption).foregroundStyle(CK.secondary).lineLimit(3) }
                            if let selected = store.selected(thread) { Text("\(selected.title) · v\(selected.revisions.count)").foregroundStyle(CK.secondary) }
                            if !session.selection.isEmpty { Text("Selected: \(session.selection)").lineLimit(3) }
                            if let next = session.nextStep, !next.isEmpty { Text("Next: \(next)") }
                            Button("Continue this project") { close(); manager.sendTypedMessage("Continue this project from its saved checkpoint and current output. State the next step briefly, then follow my assistance mode.") }.disabled(manager.isWorking)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    if let proposal = session.proposal, let artifact = store.project(thread).first(where: { $0.id == proposal.outputID }) {
                        GroupBox("Review proposed change") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(proposal.summary).font(.headline)
                                HStack(alignment: .top, spacing: 14) {
                                    reviewColumn("Current", content: artifact.current.content)
                                    reviewColumn("Proposed", content: proposal.content)
                                }
                                DisclosureGroup("Changes") { Text(CookieWorkspaceView.difference(artifact.current.content, proposal.content)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                                HStack {
                                    Button("Dismiss") { store.setSession(thread) { $0.proposal = nil } }
                                    Button("Adjust…") { store.setSession(thread) { $0.proposal = nil }; manager.drafts.draft(for: thread).text = "Adjust the proposed change: "; close() }
                                    Spacer()
                                    Button("Accept change") { do { try store.acceptProposal(thread) } catch { problem = error.localizedDescription } }.buttonStyle(.borderedProminent)
                                }
                            }.padding(8)
                        }
                    }
                    GroupBox("Scratchpad") {
                        HStack { Text("Sketch connected boxes, then turn them into an editable output."); Spacer(); Button("Open scratchpad") { scratch = true } }.padding(8)
                    }
                    GroupBox("Use this format next time") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let proposed = session.proposedPreference {
                                Text(proposed).font(.callout)
                                HStack {
                                    Button("Keep this preference") { preference = proposed; store.setSession(thread) { $0.formatPreference = proposed; $0.proposedPreference = nil } }
                                    Button("Dismiss suggestion") { store.setSession(thread) { $0.proposedPreference = nil } }
                                }
                            }
                            TextField("Describe your preferred structure and tone", text: $preference, axis: .vertical).lineLimit(2...5)
                            HStack {
                                Button("Save preference") { store.setSession(thread) { $0.formatPreference = String(preference.prefix(2000)) } }
                                Button("Remove") { preference = ""; store.setSession(thread) { $0.formatPreference = nil } }
                                Menu("Reuse a saved preference") {
                                    ForEach(Array(Set(store.sessions.values.compactMap(\.formatPreference).filter { !$0.isEmpty })).sorted(), id: \.self) { value in Button(String(value.prefix(60))) { preference = value } }
                                }
                            }
                            Text("Applied to this project after you save. Reuse it in another project's settings.").font(.caption).foregroundStyle(CK.secondary)
                        }.padding(8)
                    }
                    GroupBox("Work quietly in the background") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("What should Cookie work on?", text: $brief, axis: .vertical).lineLimit(2...5)
                            Text(jobStatus).font(.caption).foregroundStyle(CK.secondary)
                            HStack {
                                if jobs.active.contains(thread) {
                                    Button("Pause") { jobs.stop(thread, pause: true) }
                                    Button("Cancel") { jobs.stop(thread, pause: false) }
                                } else {
                                    Button(session.jobBrief == nil ? "Start" : "Resume from checkpoint") { jobs.start(thread: thread, brief: brief) }.disabled(brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || jobs.active.count >= 2 || manager.isWorking)
                                }
                            }
                            if let approval = jobs.approvals[thread] {
                                BatchApprovalCard(approval: approval) { answers in jobs.answer(thread, answers: answers) }
                            }
                            Text("Pause stops execution. Resume starts from saved outputs and progress; it does not replay completed external actions automatically.").font(.caption).foregroundStyle(CK.secondary)
                        }.padding(8)
                    }
                    if let problem { Text(problem).foregroundStyle(.orange) }
                }
            }
        }.padding(20).frame(width: 640, height: 620).foregroundStyle(CK.text).background(CK.island)
            .buttonStyle(.bordered).onAppear { preference = session.formatPreference ?? ""; brief = session.jobBrief ?? "" }
            .sheet(isPresented: $scratch) { CookieScratchpad(store: store, thread: thread) { scratch = false } }
    }
    private var jobStatus: String {
        let state = session.jobState ?? "Ready"
        return !jobs.active.contains(thread) && ["Running", "Needs your decision"].contains(state) ? "Interrupted — resume from the saved checkpoint" : state
    }
    private func reviewColumn(_ title: String, content: CookieArtifact.Content) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption.bold())
            ScrollView {
                Text(summary(content)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 150)
        }.padding(10).frame(maxWidth: .infinity).background(CK.fill, in: RoundedRectangle(cornerRadius: 10))
    }
    private func summary(_ content: CookieArtifact.Content) -> String {
        if !content.grid.isEmpty { return content.grid.prefix(40).map { $0.joined(separator: " | ") }.joined(separator: "\n") }
        if !content.blocks.isEmpty { return content.blocks.map(\.text).joined(separator: "\n\n") }
        if !content.nodes.isEmpty { return content.nodes.map(\.label).joined(separator: " → ") }
        return String(content.body.prefix(12000))
    }
}

struct CookieScratchpad: View {
    @ObservedObject var store: CookieWorkspaceStore
    let thread: UUID
    let close: () -> Void
    @State private var nodes: [CookieArtifact.Node] = []
    @State private var label = ""
    @State private var connect = true
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Scratchpad").font(.title2.bold()); Spacer(); Button("Done", action: close) }
            HStack {
                TextField("Name a box", text: $label).onSubmit(add)
                Button("Add box", action: add).disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nodes.count >= 30)
                Toggle("Connect in order", isOn: $connect)
            }
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(CK.fill)
                        .gesture(DragGesture(minimumDistance: 12).onEnded { value in
                            guard nodes.count < 30 else { return }
                            let center = CGPoint(x: (value.startLocation.x + value.location.x) / 2, y: (value.startLocation.y + value.location.y) / 2)
                            let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
                            nodes.append(.init(id: "box-\(UUID().uuidString)", label: name.isEmpty ? "Idea \(nodes.count + 1)" : String(name.prefix(120)), x: min(0.87, max(0.13, center.x / geometry.size.width)), y: min(0.9, max(0.1, center.y / geometry.size.height))))
                            label = ""
                        })
                    if connect {
                        Path { path in
                            for index in nodes.indices.dropFirst() {
                                path.move(to: CGPoint(x: nodes[index-1].x * geometry.size.width, y: nodes[index-1].y * geometry.size.height))
                                path.addLine(to: CGPoint(x: nodes[index].x * geometry.size.width, y: nodes[index].y * geometry.size.height))
                            }
                        }.stroke(CK.accent.opacity(0.5), lineWidth: 2)
                    }
                    ForEach(nodes) { node in
                        Text(node.label).font(.system(size: 13, weight: .medium)).lineLimit(3).padding(10).frame(width: 130)
                            .background(CK.island, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(CK.hairline))
                            .position(x: node.x * geometry.size.width, y: node.y * geometry.size.height)
                            .gesture(DragGesture(coordinateSpace: .named("scratch")).onChanged { value in
                                if let index = nodes.firstIndex(where: { $0.id == node.id }) { nodes[index].x = min(0.87, max(0.13, value.location.x / geometry.size.width)); nodes[index].y = min(0.9, max(0.1, value.location.y / geometry.size.height)) }
                            }).cookiePointingCursor()
                    }
                }.coordinateSpace(name: "scratch")
            }.frame(height: 320)
            HStack {
                Button("Undo box") { if !nodes.isEmpty { nodes.removeLast() } }
                Spacer()
                ForEach([CookieArtifact.Kind.diagram, .sheet, .html], id: \.self) { kind in Button("Make \(kind.rawValue)") { make(kind) }.disabled(nodes.isEmpty) }
            }
            if let error { Text(error).foregroundStyle(.orange) }
        }.padding(20).frame(width: 640).background(CK.island).foregroundStyle(CK.text)
            .onAppear { nodes = store.session(thread).scratchNodes ?? []; connect = store.session(thread).scratchConnected ?? true }
            .onChange(of: nodes) { _, value in store.setSession(thread) { $0.scratchNodes = value } }
            .onChange(of: connect) { _, value in store.setSession(thread) { $0.scratchConnected = value } }
    }
    private func add() {
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, nodes.count < 30 else { return }
        nodes.append(.init(id: "box-\(UUID().uuidString)", label: String(value.prefix(120)), x: 0.2 + Double(nodes.count % 3) * 0.3, y: 0.2 + Double(nodes.count / 3 % 3) * 0.3)); label = ""
    }
    private func make(_ kind: CookieArtifact.Kind) {
        var content = CookieArtifact.Content()
        if kind == .diagram {
            content.nodes = nodes
            if connect { content.edges = nodes.indices.dropFirst().map { .init(from: nodes[$0-1].id, to: nodes[$0].id) } }
        } else if kind == .sheet {
            content.grid = [["Step", "Idea"]] + nodes.enumerated().map { [String($0.offset + 1), $0.element.label] }
        } else {
            func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
            content.body = "<style>body{font:17px system-ui;padding:32px;background:#181818;color:#eee}section{padding:20px;margin:12px 0;background:#282828;border-radius:16px}</style><h1>My idea</h1>" + nodes.map { "<section id='\($0.id)'>\(escape($0.label))</section>" }.joined()
        }
        do { _ = try store.put(thread: thread, id: UUID().uuidString, title: "Scratchpad \(kind.rawValue)", kind: kind, content: content, base: nil, summary: "Created from scratchpad"); close() } catch { self.error = error.localizedDescription }
    }
}
