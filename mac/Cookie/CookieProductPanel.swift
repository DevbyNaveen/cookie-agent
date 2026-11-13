import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Explicit, local controls for reference material and reviewable work.
struct CookieProductPanel: View {
    @ObservedObject var store: CookieWorkspaceStore
    @ObservedObject var manager: CompanionManager
    let thread: UUID
    let close: () -> Void
    @State var tab = "Context"
    @State private var title = ""
    @State private var source = ""
    @State private var timeline = ""
    @State private var message: String?
    @State private var markerPreview: String?
    @State private var showingMarkers = false
    private var selected: CookieArtifact? { store.selected(thread) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Work with Cookie").font(.title2.weight(.semibold)); Spacer(); Button("Done", action: close) }
            Picker("Tools", selection: $tab) { ForEach(["Context", "Review", "Workflows"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if tab == "Context" { context }
                    else if tab == "Review" { review }
                    else { workflows }
                    if let message { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(22).frame(width: 620, height: 580).background(CK.island).foregroundStyle(CK.text).buttonStyle(.bordered)
        .sheet(isPresented: $showingMarkers) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review Resolve marker script").font(.headline)
                Text("This script changes the named timeline only when you run it in Resolve. Cookie has not run it.").font(.caption).foregroundStyle(CK.secondary)
                ScrollView { Text(markerPreview ?? "").font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 350)
                HStack { Button("Cancel") { showingMarkers = false }; Spacer(); Button("Export…") { exportMarkers() }.buttonStyle(.borderedProminent) }
            }.padding(20).frame(width: 580).background(CK.island).foregroundStyle(CK.text)
        }
    }
    private var context: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bring context from any app").font(.headline)
            Text("Copy text, an image or a captured video frame, then add it here. Included items are sent with future requests in this project; nothing is collected automatically.").font(.callout).foregroundStyle(CK.secondary)
            TextField("Short name", text: $title)
            TextField("Source URL, app, or video timecode", text: $source)
            Button("Add from clipboard") { perform { try store.clipboardClip(title: title, source: source, thread: thread); title = ""; source = "" } }
            ForEach(store.session(thread).contextClips ?? []) { clip in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle(clip.title, isOn: Binding(get: { clip.included }, set: { included in store.setSession(thread) { state in if let index = state.contextClips?.firstIndex(where: { $0.id == clip.id }) { state.contextClips?[index].included = included } } }))
                        Spacer()
                        Button { store.setSession(thread) { $0.contextClips?.removeAll { $0.id == clip.id } } } label: { Image(systemName: "trash") }.accessibilityLabel("Remove " + clip.title)
                    }
                    if let data = clip.image, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 110) }
                    Text(clip.text).font(.callout).lineLimit(4).textSelection(.enabled)
                    Text(clip.source.isEmpty ? "Source not provided" : clip.source).font(.caption).foregroundStyle(CK.secondary).textSelection(.enabled)
                    Text(clip.capturedAt, style: .date).font(.caption).foregroundStyle(CK.secondary)
                }.padding(12).background(CK.fill, in: RoundedRectangle(cornerRadius: 12))
            }
            Menu("Reuse context from another project") {
                ForEach(store.sessions.keys.compactMap(UUID.init(uuidString:)).filter { $0 != thread }.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                    ForEach(store.session(id).contextClips ?? []) { clip in
                        Button(clip.title) { perform { var copy = clip; copy.id = UUID().uuidString; copy.included = true; try store.addClip(copy, thread: thread) } }
                    }
                }
            }
        }
    }
    @ViewBuilder private var review: some View {
        if let artifact = selected {
            Text(artifact.title).font(.headline)
            Text("Checks belong to one saved revision. Editing the output makes its previous receipt out of date.").font(.callout).foregroundStyle(CK.secondary)
            Button("Check this revision") { _ = store.verify(artifact) }
            if let receipt = store.session(thread).receipts?[artifact.id] {
                Text(receipt.revision == artifact.current.id ? "Current revision checked" : "Outdated receipt — check again").font(.headline)
                Text(receipt.checkedAt, style: .time).font(.caption)
                DisclosureGroup("Checks and limits") {
                VStack(alignment: .leading, spacing: 8) {
                Text("Checks performed").font(.subheadline.bold())
                ForEach(receipt.checks, id: \.self) { Text("• " + $0).font(.callout) }
                ForEach(receipt.issues, id: \.self) { Text($0).foregroundStyle(.orange) }
                Text("Still unverified").font(.subheadline.bold())
                ForEach(receipt.unverified, id: \.self) { Text("• " + $0).font(.callout).foregroundStyle(CK.secondary) }
                }.padding(.top, 8)
                }
            }
            Divider()
            Text("Explore an alternative").font(.headline)
            Text("Create a separate output, edit it, then compare. Your original stays available.").font(.callout).foregroundStyle(CK.secondary)
            Button("Create independent alternative") { perform { _ = try store.makeAlternative(artifact) } }
            if let origin = store.session(thread).alternatives?[artifact.id], let original = store.project(thread).first(where: { $0.id == origin.artifact }) {
                Text("Original: " + original.title)
                Text(CookieWorkspaceView.difference(original.current.content, artifact.current.content)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Button("Propose replacing original") { perform { try store.proposeAlternative(artifact); message = "Proposal saved. Review and accept it in Project controls." } }
            }
        } else { Text("Select an output to check or create an alternative.").foregroundStyle(CK.secondary) }
    }
    private var workflows: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Spreadsheet review").font(.headline)
            Text("Clean surrounding whitespace without moving rows or changing formulas. Duplicate rows are reported for review.").foregroundStyle(CK.secondary)
            Button("Review selected sheet") {
                perform {
                    guard let artifact = selected, artifact.kind == .sheet else { throw CookieWorkspaceStore.Failure("Select a spreadsheet first.") }
                    let duplicates = CookieSheetWorkflow.duplicateRows(artifact.current.content)
                    let cleaned = CookieSheetWorkflow.cleaned(artifact.current.content)
                    if cleaned != artifact.current.content { try store.propose(thread: thread, artifact: artifact, content: cleaned, base: artifact.current.id, title: artifact.title, summary: "Trim surrounding whitespace; preserve row positions and formulas") }
                    message = (cleaned == artifact.current.content ? "No whitespace changes needed. " : "Cleanup proposed for review. ") + (duplicates.isEmpty ? "No exact duplicate rows." : "Duplicate rows: " + duplicates.map(String.init).joined(separator: ", "))
                }
            }
            Divider()
            Text("Browser research").font(.headline)
            Text("Use the included context as a starting point. Cookie builds a source-linked table and marks missing evidence.").foregroundStyle(CK.secondary)
            Button("Build research table") { close(); manager.sendTypedMessage("Research the topic in my included context tray. Retrieve sources, then create a workspace sheet with Claim, Evidence, Source URL, Retrieved date, and Uncertainty. Never invent sources; mark anything you could not verify. Show the first useful results before a long explanation.") }
            Divider()
            Text("DaVinci Resolve · marker handoff").font(.headline)
            Text("Select a sheet with Frame, Name, Note columns. Export a Lua script for review and run it inside Resolve. Frames are offsets from timeline start. This is a file handoff, not a live connection.").foregroundStyle(CK.secondary)
            TextField("Exact Resolve timeline name", text: $timeline)
            Button("Review & export marker script") { perform {
                guard let artifact = selected, artifact.kind == .sheet else { throw CookieWorkspaceStore.Failure("Select a marker spreadsheet first.") }
                let script = try CookieResolveWorkflow.markerScript(grid: artifact.current.content.grid, timeline: timeline)
                markerPreview = script; showingMarkers = true
            } }
            Divider()
            Text("Interactive lesson").font(.headline)
            Button("Explore voltage, resistance & current") { perform {
                var content = CookieArtifact.Content()
                content.controls = [.init(id: "voltage", label: "Voltage", minimum: 0, maximum: 24, value: 12, unit: "V"), .init(id: "resistance", label: "Resistance", minimum: 1, maximum: 100, value: 10, unit: "Ω")]
                content.nodes = [.init(id: "voltage", label: "Voltage (V)", x: 0.15, y: 0.25, formula: "=A1"), .init(id: "resistance", label: "Resistance (Ω)", x: 0.85, y: 0.25, formula: "=A2"), .init(id: "current", label: "Current (A) · I = V / R", x: 0.5, y: 0.75, formula: "=A1/A2")]
                content.edges = [.init(from: "voltage", to: "current"), .init(from: "resistance", to: "current")]
                _ = try store.put(thread: thread, id: UUID().uuidString, title: "Ohm’s law · explore", kind: .diagram, content: content, base: nil, summary: "Interactive ideal resistor model")
                close()
            } }
        }.font(.callout)
    }
    private func exportMarkers() {
        guard let script = markerPreview else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Cookie-Markers.lua"; panel.allowedContentTypes = [.plainText]; panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            perform { try script.write(to: url, atomically: true, encoding: .utf8); message = "Script exported. No timeline was changed by Cookie."; showingMarkers = false }
        }
    }
    private func perform(_ action: () throws -> Void) { do { message = nil; try action() } catch { message = error.localizedDescription } }
}
