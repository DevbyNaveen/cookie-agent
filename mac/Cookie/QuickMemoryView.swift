import SwiftUI
import AppKit
import EnkeonVoiceKit

struct QuickMemoryView: View {
    @EnvironmentObject private var model: AppModel
    var dismiss: () -> Void = {}
    @State private var input = ""
    @State private var branch = ""
    @State private var branches: [String] = []
    @State private var mode = "Ask"
    @State private var results: [EnkeonClient.MemoryCandidate] = []
    @State private var resultBranch = ""
    @State private var message = ""
    @State private var failed = false
    @State private var busy = false
    @State private var loading = false
    @State private var branchError: String?
    @State private var manualProject = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                MemoryCardsIcon().frame(width: 20, height: 20)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                Text("Memory").font(.system(size: 17, weight: .semibold)).tracking(-0.3)
                Spacer(minLength: 0)
                Button { dismiss(); model.openPage(.notes) } label: {
                    PhosphorIcon(name: "ArrowSquareOut", size: 17)
                        .foregroundStyle(Theme.secondary).frame(width: 30, height: 30)
                }.buttonStyle(.plain).help("Open notes").accessibilityLabel("Open notes")
            }
            TabStrip(tabs: [("Ask", "Ask"), ("Save", "Save")], selection: $mode) { EmptyView() }
                .disabled(busy)
            HStack {
                    PhosphorIcon(name: "GitDiff", size: 14).foregroundStyle(Theme.accent)
                    if manualProject {
                        TextField(mode == "Ask" ? "All memory · optional project" : "Project name", text: $branch)
                            .textFieldStyle(.plain).font(.system(size: 12))
                            .disabled(busy).accessibilityLabel("Memory project name")
                    } else {
                    Menu {
                        if mode == "Ask" { Button("All memory") { branch = "" } }
                        ForEach(branches, id: \.self) { name in
                            Button { branch = name } label: {
                                if branch == name { Label(name, systemImage: "checkmark") }
                                else { Text(name) }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(loading ? "Loading projects…" : branch.isEmpty ? (mode == "Ask" ? "All memory" : "Choose a project") : branch)
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }.font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                    }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                        .disabled(loading || busy || branches.isEmpty)
                        .accessibilityLabel("Memory project")
                    }
                    Spacer(minLength: 0)
                    if loading { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.surface, in: Capsule())
            .frame(maxWidth: 230, alignment: .leading)
            TextField(mode == "Ask" ? "Ask your memory…" : "What would you like to remember?", text: $input, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .lineLimit(2...5).focused($inputFocused)
                    .disabled(busy)
                    .accessibilityLabel(mode == "Ask" ? "Search your memory" : "Memory to save")
                .padding(14)
                .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !model.account.isSignedIn {
                HStack {
                    Text("Connect Enkeon to use your memory.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Connect") { dismiss(); model.openPage(.connections) }.buttonStyle(SecondaryButton())
                }
            } else if let branchError {
                HStack(alignment: .top) {
                    Text(branchError).font(.system(size: 12)).foregroundStyle(Theme.warning)
                    Spacer()
                    Button("Retry") { Task { await loadBranches() } }.buttonStyle(SecondaryButton())
                }
            }
            if !message.isEmpty {
                Label(message, systemImage: failed ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.system(size: 12)).foregroundStyle(failed ? Theme.warning : Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !results.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(results) { result in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(result.statement).font(.system(size: 13)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    Text(resultBranch).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                                    Spacer()
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(result.statement, forType: .string)
                                    } label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(SecondaryButton())
                                }
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
                        }
                    }
                }.frame(maxHeight: 200)
            }
            HStack {
                if manualProject {
                    Text(mode == "Ask" ? "Project name is optional." : "Choose a project by name.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button(action: submit) {
                    HStack(spacing: 7) {
                        if busy { ProgressView().controlSize(.mini) }
                        Text(busy ? "Working…" : mode == "Ask" ? "Ask" : "Save")
                    }
                }.buttonStyle(PrimaryButton())
                    .disabled(busy || loading || (mode == "Save" && branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.account.isSignedIn)
            }
        }
        .padding(20).frame(width: 350).tint(Theme.accent)
        .background(MemoryGlass().clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous)))
        .onChange(of: mode) { _, _ in results = []; message = ""; inputFocused = true }
        .onChange(of: branch) { _, _ in results = []; message = "" }
        .task { await loadBranches() }
    }

    private func loadBranches() async {
        guard model.account.isSignedIn, !loading else { return }
        loading = true; branchError = nil
        defer { loading = false }
        do {
            branches = try await EnkeonClient.shared.branchNames()
            let selected = UserDefaults.standard.string(forKey: "enkeon.memory.writingBranch") ?? ""
            if branches.contains(selected) { branch = selected }
            else if branches.count == 1 { branch = branches[0] }
            else if !branches.contains(branch) { branch = "" }
            if branches.isEmpty { branchError = "No projects found. Open Enkeon to create or choose a memory project." }
        } catch {
            if EnkeonClient.projectListingUnavailable(error) {
                manualProject = true
            } else { branchError = "Can’t reach your projects. Try again." }
        }
    }

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !loading, model.account.isSignedIn, !text.isEmpty,
              mode == "Ask" || !target.isEmpty else { return }
        busy = true; message = ""; failed = false; results = []
        let action = mode
        Task {
            defer { busy = false }
            do {
                if action == "Ask" {
                    let reply = try await EnkeonClient.shared.recallMeeting(query: text, branch: target.isEmpty ? nil : target)
                    results = EnkeonClient.memoryCandidates(fromRecall: reply)
                    resultBranch = target.isEmpty ? "Your memory" : target
                    if results.isEmpty { message = target.isEmpty ? "No matching memory found." : "No matching memory found in this project." }
                } else {
                    let reply = try await EnkeonClient.shared.rememberNote(text, app: "Enkeon Voice memory panel", branch: target)
                    guard EnkeonClient.memoryID(fromReply: reply) != nil else {
                        failed = true; message = "Save wasn’t confirmed. Check your notes before trying again."; return
                    }
                    message = "Saved to \(target)."; input = ""
                }
            } catch { failed = true; message = error.localizedDescription }
        }
    }
}

/// Native vibrancy with no outline; the system respects Reduce Transparency.
private struct MemoryGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
