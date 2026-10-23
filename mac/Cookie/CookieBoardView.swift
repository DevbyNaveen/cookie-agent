//
//  CookieBoardView.swift
//  Cookie
//
//  The Board: one feed of everything moving forward, in the order it asks
//  for you. Needs you, then Cookie's on it, then Waiting, then Routines, then
//  lists you haven't started on, then Finished folded away; a section with
//  nothing in it isn't shown. No columns to arrange and no table to
//  maintain: rows move by their stage menu or by dragging onto a section,
//  and a list row becomes work the moment you start on it.
//
//  Two kinds of row share each section. Cookie's own (its jobs, drafts,
//  approvals, questions, follow-ups and routines) come from `CookieAPI`, the
//  same list Cookie's web page shows (Enkeon when signed in, this Mac's
//  page when not), and lead their section. Your work items stay in
//  `WorkStore` on this Mac, mirrored to Enkeon as plan memories so your AI
//  tools see them; the web page has no work items of its own.
//

import AppKit
import SwiftUI

struct BoardView: View {
    @ObservedObject var store: WorkStore
    @ObservedObject var lists: ListStore
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var navigation: CookieNavigation
    @ObservedObject private var recorder = CookieRecorder.shared
    @ObservedObject private var cookie = CookieAPI.shared
    @ObservedObject private var agents = CookieAgentStore.shared
    @State private var search = ""
    @State private var job = ""
    @State private var jobProblem: String?
    @State private var showsFinished = false
    @State private var importProblem: String?

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var items: [WorkItem] { CookieWorkSort.matching(store.items, query: query) }
    private var isEmpty: Bool {
        store.items.isEmpty && lists.lists.allSatisfy(\.rows.isEmpty) && (cookie.overview?.runs.isEmpty ?? true) && cookie.routines.isEmpty
            && localRoutines.isEmpty
    }

    private func matches(_ text: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedStandardContains($0) }
    }
    private var needs: [CookieAPI.Need] { cookie.needs.filter { matches($0.title + " " + $0.detail) } }
    private var working: [CookieAPI.Run] { cookie.working.filter { matches($0.subject) } }
    private var chases: [CookieAPI.Chase] { cookie.openChases.filter { matches($0.about + " " + $0.to.joined(separator: " ")) } }
    private var routines: [CookieAPI.Routine] { cookie.routines.filter { matches($0.job) } }
    /// Named Cookies' own routines, which run on this Mac only (see `CookieRoutineWords.perform`).
    private var localRoutines: [(agent: CookieAgent, routine: CookieRoutine)] {
        agents.agents.filter { !$0.builtIn }.flatMap { agent in agent.routines.map { (agent, $0) } }.filter { matches($0.routine.instruction) }
    }
    private var finishedRuns: [CookieAPI.Run] { cookie.finished.filter { matches($0.subject + " " + ($0.answer ?? "")) } }

    var body: some View {
        if let id = navigation.openWork, store.item(id) != nil {
            WorkItemView(store: store, companionManager: companionManager, navigation: navigation, id: id)
                .transition(.opacity)
        } else {
            GeometryReader { geometry in
                let layout = CookieWorkLayout(width: geometry.size.width)
                let compact = layout.contentWidth < 520
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        header
                        jobField
                        if isEmpty {
                            emptyBoard
                        } else if items.isEmpty && !query.isEmpty && matchingLists.isEmpty && needs.isEmpty && working.isEmpty
                                    && chases.isEmpty && routines.isEmpty && localRoutines.isEmpty && finishedRuns.isEmpty {
                            WorkEmptyState(symbol: "magnifyingglass", title: "Nothing matches", detail: "Try a title, a person or a next step.")
                        } else {
                            ForEach([WorkColumn.needsYou, .cookie, .waiting]) { column in
                                stage(column, compact: compact)
                            }
                            routineSection
                            ForEach(matchingLists) { list in
                                notStarted(list)
                            }
                            finished(compact: compact)
                        }
                        if let problem = importProblem ?? jobProblem ?? cookie.problem ?? store.syncProblem ?? lists.problem {
                            HStack(spacing: 10) {
                                Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(CK.secondary)
                                if cookie.needsSignIn {
                                    Button("Sign in again") { CookieAccount.shared.signIn() }
                                        .buttonStyle(WorkButtonStyle(quiet: true)).fixedSize()
                                }
                            }
                        }
                    }
                    .padding(layout.padding)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
            // Read when shown, then every half minute while it stays open.
            .task {
                while !Task.isCancelled {
                    await cookie.refresh()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }

    // MARK: Cookie

    /// Give Cookie a job: the same as giving one on its web page.
    private var jobField: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle").font(.system(size: 12)).foregroundStyle(CK.accent).accessibilityHidden(true)
            TextField("Give Cookie a job…", text: $job).textFieldStyle(.plain).font(.system(size: 12.5))
                .onSubmit(giveJob).accessibilityLabel("Give Cookie a job")
            if !job.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: giveJob) { Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(CK.accent, in: Circle()) }
                    .buttonStyle(.plain).cookiePointingCursor().accessibilityLabel("Give the job")
            }
        }
        .padding(.leading, 12).padding(.trailing, 6).frame(height: 38)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func giveJob() {
        let text = job.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        job = ""
        Task {
            do {
                try await cookie.give(text)
                jobProblem = nil
            } catch {
                job = text
                jobProblem = error.localizedDescription
            }
        }
    }

    /// Cookie's rows for a stage: they lead it.
    @ViewBuilder private func cookieRows(_ column: WorkColumn) -> some View {
        switch column {
        case .needsYou: ForEach(needs) { NeedRow(need: $0, api: cookie) }
        case .cookie: ForEach(working) { RunRow(run: $0, api: cookie) }
        case .waiting: ForEach(chases) { ChaseRow(chase: $0, api: cookie) }
        case .done: ForEach(finishedRuns) { RunRow(run: $0, api: cookie) }
        }
    }

    private func cookieCount(_ column: WorkColumn) -> Int {
        switch column {
        case .needsYou: return needs.count
        case .cookie: return working.count
        case .waiting: return chases.count
        case .done: return finishedRuns.count
        }
    }

    @ViewBuilder private var routineSection: some View {
        if !routines.isEmpty || !localRoutines.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "repeat").font(.system(size: 12, weight: .medium)).foregroundStyle(CK.tertiary)
                    WorkSectionHeading(title: "Routines", count: routines.count + localRoutines.count)
                }
                .padding(.horizontal, 4).frame(height: 26)
                VStack(spacing: 4) {
                    ForEach(routines) { routine in
                        CookieRow(tint: CK.tertiary, title: routine.job,
                                  detail: routine.state == "paused" ? "Paused · \(routine.when)" : routine.when,
                                  actions: [routine.state == "paused"
                                            ? .init(title: "Resume") { await cookie.routine(routine.id, "resume") }
                                            : .init(title: "Pause") { await cookie.routine(routine.id, "pause") }])
                    }
                    ForEach(localRoutines, id: \.routine.id) { agent, routine in
                        CookieRow(tint: CK.tertiary, title: routine.instruction,
                                  detail: "\(routine.cadence.title) · \(agent.name), on this Mac only",
                                  actions: [.init(title: "Remove") { removeLocal(routine.id, from: agent.id) }])
                    }
                }
            }
            .padding(6)
        }
    }

    private func removeLocal(_ routineID: UUID, from agentID: UUID) {
        guard var agent = agents.agent(agentID) else { return }
        agent.routines.removeAll { $0.id == routineID }
        agents.update(agent)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 12)).foregroundStyle(CK.secondary)
                Text("Board").font(.system(size: 27, weight: .semibold)).tracking(-0.7)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(CK.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions; Spacer(minLength: 8); searchField }
                VStack(alignment: .leading, spacing: 8) { HStack(spacing: 8) { actions }; searchField }
                VStack(alignment: .leading, spacing: 8) { actions; searchField }
            }
        }
    }

    private var subtitle: String {
        let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        let hour = Calendar.current.component(.hour, from: Date())
        let part = (5..<12).contains(hour) ? "Good morning" : (12..<18).contains(hour) ? "Good afternoon" : "Good evening"
        let greeting = name.isEmpty ? part : "\(part), \(name)"
        let needsYou = store.items(in: .needsYou).count + self.cookie.needs.count
        let cookie = store.items(in: .cookie).count + self.cookie.working.count
        let waiting = store.items(in: .waiting).count + self.cookie.openChases.count
        if needsYou + cookie + waiting == 0 { return "\(greeting). A little space for what’s next." }
        var parts: [String] = []
        if needsYou > 0 { parts.append("\(needsYou) need\(needsYou == 1 ? "s" : "") you") }
        if cookie > 0 { parts.append("\(cookie) with Cookie") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return "\(greeting). " + parts.joined(separator: ", ") + "."
    }

    @ViewBuilder private var actions: some View {
        Button { navigation.showsWorkComposer = true } label: { Label("New work", systemImage: "plus") }
            .buttonStyle(WorkButtonStyle(primary: true)).fixedSize()
        Button { recorder.start() } label: { Label("Record a meeting", systemImage: "record.circle") }
            .buttonStyle(WorkButtonStyle(quiet: true)).fixedSize().disabled(recorder.isBusy)
        Button(action: importCSV) { Label("Import a list", systemImage: "square.and.arrow.down") }
            .buttonStyle(WorkButtonStyle(quiet: true)).fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(CK.tertiary)
            TextField("Find on the board", text: $search).textFieldStyle(.plain).font(.system(size: 12))
                .accessibilityLabel("Find work or a company by title, person or next step")
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(CK.secondary) }
                    .buttonStyle(.plain).cookiePointingCursor().accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 11)).padding(.horizontal, 10).frame(maxWidth: 220).frame(height: 32)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: Stages

    @ViewBuilder private func stage(_ column: WorkColumn, compact: Bool) -> some View {
        let rows = items.filter { $0.column == column }.sorted(by: WorkStore.order)
        if !rows.isEmpty || cookieCount(column) > 0 {
            BoardSection(store: store, column: column, title: column.title, count: rows.count + cookieCount(column),
                         empty: column.emptyTitle + ". " + column.emptyDetail) {
                cookieRows(column)
                ForEach(rows) { item in
                    BoardRow(item: item, store: store, compact: compact) { open(item.id) }.draggable(item.id.uuidString)
                }
            }
        }
    }

    private func finished(compact: Bool) -> some View {
        let rows = items.filter { $0.column == .done }.sorted { $0.updated > $1.updated }
        return Group {
            if !rows.isEmpty || cookieCount(.done) > 0 {
                BoardSection(store: store, column: .done, title: "Finished", count: rows.count + cookieCount(.done),
                             empty: "Finished work stays here, out of your way.", collapsed: !showsFinished,
                             toggle: { withAnimation(CK.quick) { showsFinished.toggle() } }) {
                    cookieRows(.done)
                    ForEach(rows) { item in
                        BoardRow(item: item, store: store, compact: compact) { open(item.id) }.draggable(item.id.uuidString)
                    }
                }
            }
        }
    }

    // MARK: Lists

    private var matchingLists: [CookieList] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return lists.lists.compactMap { list in
            guard !words.isEmpty else { return list }
            var filtered = list
            filtered.rows = list.rows.filter { row in
                let text = ([list.name, row.company, row.website, row.contact, row.note] + row.extra.values).joined(separator: " ")
                return words.allSatisfy { text.localizedStandardContains($0) }
            }
            return filtered.rows.isEmpty ? nil : filtered
        }
    }

    private func notStarted(_ list: CookieList) -> some View {
        let started = list.rows.filter { row in row.workID.flatMap(store.item) != nil }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 12, weight: .medium)).foregroundStyle(CK.tertiary)
                WorkSectionHeading(title: list.name, count: list.rows.count)
                if started > 0 {
                    Text("· \(started) started").font(.system(size: 11)).foregroundStyle(CK.tertiary)
                }
                Spacer(minLength: 0)
                CookieMenu("Options for \(list.name)", items: [
                    CookieMenuItem("Start research on all", symbol: ListAction.research.symbol) { start(.research, rows: Set(list.rows.map(\.id)), in: list) },
                    CookieMenuItem("Remove list", symbol: "trash", destructive: true, separated: true) { lists.delete(list.id) },
                ]) {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(CK.secondary)
                        .frame(width: 26, height: 26).background(CK.fill, in: Circle())
                }
                .help("List options")
            }
            .padding(.horizontal, 4)
            VStack(spacing: 4) {
                ForEach(list.rows) { row in
                    ListRowView(row: row, work: row.workID.flatMap(store.item),
                                start: { action in start(action, rows: [row.id], in: list) },
                                open: { id in open(id) })
                }
            }
        }
    }

    private func start(_ action: ListAction, rows: Set<UUID>, in list: CookieList) {
        let created = lists.startWork(list.id, rows: rows, action: action, in: store)
        if created.count == 1, let item = created.first { open(item.id) }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            lists.create(name: url.deletingPathExtension().lastPathComponent, rows: try ListCSV.rows(from: text))
            importProblem = nil
        } catch {
            importProblem = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Empty

    private var emptyBoard: some View {
        VStack(alignment: .leading, spacing: 18) {
            CookieAvatar(size: 62).padding(.bottom, 3).accessibilityHidden(true)
            Text("Big plans. Small next steps.")
                .font(.system(size: 21, weight: .semibold)).tracking(-0.4)
            Text("A question to research, a proposal to finish, a person to follow up with, a list of companies to work through. Give it a place here, then take the next step with Cookie.")
                .font(.system(size: 13)).foregroundStyle(CK.secondary)
                .lineSpacing(4).frame(maxWidth: 440, alignment: .leading)
            Text("A CSV needs a Company or Name column. Website, Contact and Notes are picked up too; other columns are kept.")
                .font(.system(size: 11)).foregroundStyle(CK.tertiary)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func open(_ id: UUID) { withAnimation(CK.quick) { navigation.openWork = id } }
}

// MARK: - Section

/// One stage of the feed: a heading, its rows, and a drop target that moves work here.
private struct BoardSection<Rows: View>: View {
    @ObservedObject var store: WorkStore
    let column: WorkColumn
    let title: String
    let count: Int
    let empty: String
    var collapsed = false
    var toggle: (() -> Void)?
    @ViewBuilder let rows: Rows
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { toggle?() } label: {
                HStack(spacing: 8) {
                    Image(systemName: column.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(column.tint)
                    WorkSectionHeading(title: title, count: count)
                    Spacer(minLength: 0)
                    if targeted {
                        Text("Drop to move here").font(.system(size: 11)).foregroundStyle(column.tint)
                    } else if toggle != nil {
                        Image(systemName: collapsed ? "chevron.down" : "chevron.up").font(.system(size: 9, weight: .semibold)).foregroundStyle(CK.tertiary)
                    }
                }
                .padding(.horizontal, 4).frame(height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(toggle == nil)
            .cookiePointingCursor()
            .accessibilityValue(toggle == nil ? "" : collapsed ? "Collapsed" : "Expanded")
            if !collapsed {
                if count == 0 {
                    Text(empty).font(.system(size: 11.5)).foregroundStyle(CK.tertiary).lineSpacing(3)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 4) { rows }
                }
            }
        }
        .padding(6)
        .background(targeted ? column.tint.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { values, _ in
            moveDroppedWork(values, store: store, column: column)
        } isTargeted: { targeted = $0 }
        .animation(CK.quick, value: targeted)
        .accessibilityElement(children: .contain).accessibilityLabel("\(title), \(count) items")
    }
}

@MainActor
func moveDroppedWork(_ values: [String], store: WorkStore, column: WorkColumn) -> Bool {
    let items = Set(values.compactMap(UUID.init(uuidString:))).compactMap { store.item($0) }.filter { $0.column != column }
    items.forEach { store.move($0.id, to: column) }
    return !items.isEmpty
}

// MARK: - Rows

/// One piece of work: who it's with, the next step, when, and its stage.
private struct BoardRow: View {
    let item: WorkItem
    let store: WorkStore
    /// Narrow screens drop the stage menu; the dot, the context menu and the item page still move it.
    var compact = false
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        // Not a Button: a button keeps the mouse press, so the row could never be dragged.
        HStack(alignment: .center, spacing: 12) {
            Circle().fill(item.column.tint).frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(CK.text).lineLimit(1)
                Text(item.nextStep.isEmpty ? "Add a next step…" : item.nextStep)
                    .font(.system(size: 11.5)).foregroundStyle(item.nextStep.isEmpty ? CK.tertiary : CK.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(item.to.isEmpty ? "Personal" : item.to).lineLimit(1)
                if let due = item.due {
                    Text(WorkText.due(due)).foregroundStyle(item.isOverdue() ? WorkColumn.waiting.tint : CK.tertiary)
                } else if item.column == .waiting {
                    Text(WorkText.age(item.age()))
                }
            }
            .font(.system(size: 10.5)).foregroundStyle(CK.tertiary).fixedSize()
            if !compact {
                WorkStageMenu(item: item, store: store)
            }
        }
        .padding(.horizontal, 12).frame(minHeight: 54)
        .background(RoundedRectangle(cornerRadius: 11).fill(hovering ? CK.fillHover : Color.white.opacity(0.03)))
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onTapGesture(perform: open)
        .cookiePointingCursor()
        .onHover { hovering = $0 }.animation(CK.quick, value: hovering)
        .contextMenu {
            ForEach(WorkColumn.allCases.filter { $0 != item.column }) { column in
                Button("Move to \(column.title)", systemImage: column.symbol) { store.move(item.id, to: column) }
            }
            Divider()
            Button("Remove", role: .destructive) { store.remove(item.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityLabel("\(item.title). \(item.nextStep)")
        .accessibilityHint("Open to edit. Drag onto a stage to move it.")
    }
}

/// A company on a list: start work on it, or open the work already started.
private struct ListRowView: View {
    let row: ListRow
    let work: WorkItem?
    let start: (ListAction) -> Void
    let open: (UUID) -> Void
    @State private var hovering = false

    private var detail: String {
        [row.contact, row.website, row.note].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "building.2").font(.system(size: 11)).foregroundStyle(CK.tertiary).frame(width: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.company.isEmpty ? "Unnamed" : row.company).font(.system(size: 12.5, weight: .medium)).foregroundStyle(CK.text).lineLimit(1)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(CK.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let work {
                Button { open(work.id) } label: { WorkStageLabel(column: work.column) }
                    .buttonStyle(WorkButtonStyle(quiet: true)).fixedSize()
                    .help("Open \(work.title)")
            } else {
                CookieMenu("Start on \(row.company)", items: ListAction.allCases.map { action in
                    CookieMenuItem(action.title, symbol: action.symbol) { start(action) }
                }) {
                    CookieMenuLabel(title: "Start", symbol: "sparkles", tint: CK.accent)
                        .padding(.horizontal, 9).frame(height: 28)
                        .background(CK.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .help("Research, draft an intro or follow up")
            }
        }
        .padding(.horizontal, 12).frame(minHeight: 46)
        .background(RoundedRectangle(cornerRadius: 11).fill(hovering ? CK.fillHover : Color.white.opacity(0.02)))
        .onHover { hovering = $0 }.animation(CK.quick, value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.company). \(work.map { "Work \($0.column.title)" } ?? "Not started")")
    }
}

// MARK: - Cookie's rows

/// One of Cookie's rows: a dot, what it is, a line under it, its buttons,
/// and (for a draft or an answer) the words, shown on a click.
private struct CookieRow: View {
    struct Action {
        let title: String
        var primary = false
        let run: () async -> Void
    }
    let tint: Color
    let title: String
    let detail: String
    var body_: String? = nil
    var actions: [Action] = []
    /// Words typed here answer it (Cookie's questions).
    var answer: ((String) async -> Void)? = nil
    @State private var expanded = false
    @State private var reply = ""
    @State private var busy = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Circle().fill(tint).frame(width: 7, height: 7).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(CK.text).lineLimit(1)
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(CK.secondary).lineLimit(expanded ? 4 : 1)
                }
                Spacer(minLength: 8)
                ForEach(actions.indices, id: \.self) { i in
                    Button(actions[i].title) { perform(actions[i].run) }
                        .buttonStyle(WorkButtonStyle(primary: actions[i].primary, quiet: !actions[i].primary)).fixedSize()
                        .disabled(busy)
                }
            }
            if expanded, let text = body_, !text.isEmpty {
                Text(text).font(.system(size: 12)).foregroundStyle(CK.text).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 19)
            }
            if expanded, let answer {
                HStack(spacing: 8) {
                    TextField("Your answer…", text: $reply).textFieldStyle(.plain).font(.system(size: 12))
                        .onSubmit { send(answer) }.accessibilityLabel("Answer Cookie")
                    Button("Send") { send(answer) }.buttonStyle(WorkButtonStyle(primary: true)).fixedSize()
                        .disabled(busy || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.leading, 19)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9).frame(minHeight: 54)
        .background(RoundedRectangle(cornerRadius: 11).fill(hovering ? CK.fillHover : Color.white.opacity(0.03)))
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onTapGesture { if body_ != nil || answer != nil { withAnimation(CK.quick) { expanded.toggle() } } }
        .cookiePointingCursor()
        .onHover { hovering = $0 }.animation(CK.quick, value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(detail)")
    }

    private func perform(_ run: @escaping () async -> Void) {
        busy = true
        Task { await run(); busy = false }
    }

    private func send(_ answer: @escaping (String) async -> Void) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reply = ""
        perform { await answer(text) }
    }
}

private struct NeedRow: View {
    let need: CookieAPI.Need
    let api: CookieAPI

    var body: some View {
        switch need.kind {
        case .draft(let d):
            CookieRow(tint: WorkColumn.needsYou.tint, title: need.title, detail: need.detail, body_: d.body, actions: [
                .init(title: "Send", primary: true) { await api.draft(d.id, "send") },
                .init(title: "Skip") { await api.draft(d.id, "skip") },
            ])
        case .approval(let a):
            CookieRow(tint: WorkColumn.needsYou.tint, title: need.title, detail: need.detail, body_: a.detail, actions: [
                .init(title: "Allow", primary: true) { await api.approve(a.id, true) },
                .init(title: "Deny") { await api.approve(a.id, false) },
            ])
        case .asked(let r):
            CookieRow(tint: WorkColumn.needsYou.tint, title: need.title, detail: need.detail, body_: r.questions,
                      answer: { text in _ = try? await api.give(text, answers: r.id) })
        case .offer(let r):
            CookieRow(tint: WorkColumn.needsYou.tint, title: need.title, detail: need.detail, actions: [
                .init(title: "Accept", primary: true) { await api.routine(r.id, "accept") },
                .init(title: "Decline") { await api.routine(r.id, "decline") },
            ])
        }
    }
}

private struct RunRow: View {
    let run: CookieAPI.Run
    @ObservedObject var api: CookieAPI

    var body: some View {
        if run.isWorking {
            let said = api.live[run.id].flatMap { $0.split(whereSeparator: \.isNewline).last.map(String.init) }
            CookieRow(tint: WorkColumn.cookie.tint, title: run.subject.isEmpty ? "A job" : run.subject,
                      detail: run.queued == true ? "Waiting for its turn" : said ?? "Working…",
                      body_: api.live[run.id], actions: [.init(title: "Stop") { await api.stop(run.id) }])
        } else {
            CookieRow(tint: WorkColumn.done.tint, title: run.subject.isEmpty ? "A job" : run.subject,
                      detail: run.answer.flatMap { $0.split(whereSeparator: \.isNewline).first.map(String.init) } ?? (run.delivery ?? run.status).capitalized,
                      body_: run.answer)
        }
    }
}

private struct ChaseRow: View {
    let chase: CookieAPI.Chase
    let api: CookieAPI

    var body: some View {
        CookieRow(tint: WorkColumn.waiting.tint, title: chase.about,
                  detail: chase.to.isEmpty ? "Cookie follows up" : "Cookie follows up with \(chase.to.joined(separator: ", "))",
                  actions: [.init(title: "Stop") { await api.stopChase(chase.id) }])
    }
}
