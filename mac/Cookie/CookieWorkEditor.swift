import AppKit
import SwiftUI

struct CookieNewWorkView: View {
    @ObservedObject var store: WorkStore
    @ObservedObject var navigation: CookieNavigation
    @ObservedObject var draft: CookieWorkDraft
    @FocusState private var titleFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let layout = CookieWorkLayout(width: geometry.size.width)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button { navigation.showsWorkComposer = false } label: { Label("Back", systemImage: "chevron.left") }
                        .buttonStyle(WorkButtonStyle(quiet: true))
                    Spacer()
                    Text("New work").font(.system(size: 11, weight: .medium)).foregroundStyle(CK.tertiary)
                }
                .padding(.horizontal, layout.padding - 10).padding(.top, 12).padding(.bottom, 18)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Make room for what’s next.").font(.system(size: 12)).foregroundStyle(CK.secondary)
                            TextField("What are you moving forward?", text: $draft.title, axis: .vertical)
                                .textFieldStyle(.plain).font(.system(size: 25, weight: .semibold)).tracking(-0.5)
                                .lineLimit(1...3).focused($titleFocused)
                                .accessibilityLabel("Work title")
                        }
                        WorkField(title: "NEXT STEP") {
                            TextField("The one thing that moves this forward", text: $draft.nextStep, axis: .vertical)
                                .lineLimit(2...4).accessibilityLabel("Next step")
                        }
                        let columns = layout.contentWidth < 500 ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 18), GridItem(.flexible())]
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                            WorkField(title: "WHO · OPTIONAL") {
                                TextField("A person, a team, or just you", text: $draft.person).accessibilityLabel("Who it concerns")
                            }
                            WorkField(title: "DUE · OPTIONAL") {
                                WorkDueField(hasDueDate: $draft.hasDueDate, dueDate: $draft.dueDate)
                            }
                        }
                        WorkField(title: "DONE WHEN · OPTIONAL") {
                            TextField("What would a good outcome look like?", text: $draft.outcome, axis: .vertical)
                                .lineLimit(1...3).accessibilityLabel("Desired outcome")
                        }
                        Label("Start small. You can add details and ask Cookie for help as you go.", systemImage: "sparkles")
                            .font(.system(size: 11.5)).foregroundStyle(CK.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, layout.padding).padding(.bottom, 22)
                }
                HStack(spacing: 10) {
                    Label("Draft kept while Cookie is open", systemImage: "checkmark")
                        .font(.system(size: 10.5)).foregroundStyle(CK.tertiary).lineLimit(2)
                    Spacer(minLength: 8)
                    Button("Create work", action: create)
                        .buttonStyle(WorkButtonStyle(primary: true))
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!draft.canCreate).help("Create work  ⌘↩")
                }
                .padding(.horizontal, layout.padding).padding(.vertical, 18)
            }
        }
        .onAppear { titleFocused = !draft.hasContent }
        .onExitCommand { navigation.showsWorkComposer = false }
    }

    private func create() {
        guard let item = draft.create(in: store) else { return }
        navigation.openWork = item.id
        navigation.showsWorkComposer = false
        navigation.section = .board
    }
}

struct WorkDueField: View {
    @Binding var hasDueDate: Bool
    @Binding var dueDate: Date
    var body: some View {
        HStack(spacing: 8) {
            if hasDueDate {
                DatePicker("Due date", selection: $dueDate, displayedComponents: .date)
                    .datePickerStyle(.field).labelsHidden().controlSize(.small)
                    .accessibilityLabel("Due date")
                Spacer(minLength: 0)
                Button { hasDueDate = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(CK.tertiary)
                }
                .buttonStyle(.plain).cookiePointingCursor().help("Remove due date").accessibilityLabel("Remove due date")
            } else {
                Button { hasDueDate = true } label: {
                    Label("Add a date", systemImage: "calendar").foregroundStyle(CK.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).cookiePointingCursor()
            }
        }
    }
}

struct WorkItemView: View {
    @ObservedObject var store: WorkStore
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var navigation: CookieNavigation
    let id: UUID

    private var item: WorkItem { store.item(id) ?? WorkItem(title: "") }
    private func binding<Value>(_ path: WritableKeyPath<WorkItem, Value>) -> Binding<Value> {
        Binding(get: { item[keyPath: path] }, set: { value in store.update(id) { $0[keyPath: path] = value } })
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = CookieWorkLayout(width: geometry.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack {
                        Button { navigation.openWork = nil } label: { Label("All work", systemImage: "chevron.left") }
                            .buttonStyle(WorkButtonStyle(quiet: true))
                        Spacer()
                        WorkStageMenu(item: item, store: store)
                    }
                    .padding(.leading, -12)
                    HStack(alignment: .top, spacing: 14) {
                        WorkAvatar(item: item, size: 42)
                        VStack(alignment: .leading, spacing: 9) {
                            TextField("Work title", text: binding(\.title), axis: .vertical)
                                .font(.system(size: 25, weight: .semibold)).tracking(-0.5).lineLimit(1...3)
                                .accessibilityLabel("Work title")
                            TextField("What does a good outcome look like?", text: binding(\.outcome), axis: .vertical)
                                .font(.system(size: 13)).foregroundStyle(CK.secondary).lineLimit(1...3)
                                .accessibilityLabel("Desired outcome")
                        }
                        .textFieldStyle(.plain)
                    }
                    nextStep
                    let columns = layout.contentWidth < 550 ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 28, alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)]
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                        details
                        activity
                    }
                }
                .frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                .padding(layout.padding)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var nextStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkSectionHeading(title: "Next step")
            TextField("What’s the one next thing?", text: binding(\.nextStep), axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 16, weight: .medium)).lineLimit(1...5)
                .accessibilityLabel("Next step")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { nextStepActions }
                VStack(alignment: .leading, spacing: 8) { nextStepActions }
            }
            Text("Cookie asks before sending, paying or deleting.")
                .font(.system(size: 11)).foregroundStyle(CK.tertiary)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(CK.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var nextStepActions: some View {
        Button { companionManager.startWork(on: id) } label: { Label("Ask Cookie", systemImage: "sparkles") }
            .buttonStyle(WorkButtonStyle(primary: true))
            .disabled(item.nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if let threadID = item.threadID {
            Button {
                companionManager.selectThread(threadID)
                navigation.section = .chats
            } label: { Label("Open chat", systemImage: "bubble.left") }
            .buttonStyle(WorkButtonStyle(quiet: true))
        }
        if item.column != .done {
            Button { store.move(id, to: .done) } label: { Label("Mark done", systemImage: "checkmark") }
                .buttonStyle(WorkButtonStyle(quiet: true))
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 20) {
            WorkSectionHeading(title: "Details")
            WorkField(title: "Who it concerns") {
                TextField("A person, a team, or just you", text: binding(\.to)).accessibilityLabel("Who it concerns")
            }
            WorkField(title: "Due date") {
                WorkDueField(hasDueDate: Binding(get: { item.due != nil }, set: { enabled in
                    store.update(id) { $0.due = enabled ? Calendar.current.date(byAdding: .day, value: 1, to: Date()) : nil }
                }), dueDate: Binding(get: { item.due ?? Date() }, set: { date in store.update(id) { $0.due = date } }))
            }
            HStack {
                WorkSectionHeading(title: "Files", count: item.files.isEmpty ? nil : item.files.count)
                Spacer()
                Button { addFiles() } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(WorkButtonStyle(quiet: true))
            }
            if item.files.isEmpty {
                Text("Keep the useful things with the work.").font(.system(size: 11.5)).foregroundStyle(CK.tertiary)
            }
            ForEach(item.files, id: \.self) { path in
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: {
                    HStack(spacing: 9) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 18, height: 18)
                        Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.up.right").font(.system(size: 9))
                    }
                    .padding(.vertical, 5)
                }
                .buttonStyle(WorkButtonStyle(quiet: true))
                .contextMenu { Button("Remove from this work") { store.update(id) { $0.files.removeAll { $0 == path } } } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkSectionHeading(title: "Activity")
            ForEach(item.history.reversed().prefix(20)) { event in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: event.by == "cookie" ? "sparkles" : "circle.fill")
                        .font(.system(size: event.by == "cookie" ? 11 : 5)).foregroundStyle(CK.tertiary)
                        .frame(width: 14, height: 17)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(event.by == "cookie" ? "Cookie: \(event.text)" : event.text)
                            .font(.system(size: 12)).foregroundStyle(CK.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(event.date.formatted(.relative(presentation: .named)))
                            .font(.system(size: 10.5)).foregroundStyle(CK.tertiary)
                    }
                }
            }
            if let problem = store.syncProblem {
                Label(problem, systemImage: "icloud.slash").font(.system(size: 11)).foregroundStyle(WorkColumn.waiting.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.level = CookieWindowLevel.notchPanel
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        store.update(id, note: "Added \(paths.count == 1 ? URL(fileURLWithPath: paths[0]).lastPathComponent : "\(paths.count) files")") { item in
            item.files.append(contentsOf: paths.filter { !item.files.contains($0) })
        }
    }
}
