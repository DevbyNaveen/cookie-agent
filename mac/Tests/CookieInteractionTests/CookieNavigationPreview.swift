import AppKit
import SwiftUI

@MainActor
enum CookieNavigationPreview {
    static func render() {
        let threads = sampleThreads()
        snapshot("cookie-settings-preview", content:
            HStack(spacing: 0) {
                sidebar(threads: threads, settingsPage: .general).frame(width: 232)
                    .background(CK.sidebar)
                Rectangle().fill(CK.hairline).frame(width: 0.5)
                VStack(spacing: 0) {
                    Color.clear.frame(height: 38)
                    generalSettings
                }
            }
            .frame(width: 928, height: 580)
            .background(CK.island)
        )
        snapshot("cookie-settings-compact-preview", content:
            generalSettings.frame(width: 372, height: 540).background(CK.island)
        )
        snapshot("cookie-navigation-preview", content:
            HStack(alignment: .top, spacing: 28) {
                sidebar(threads: threads, settingsPage: nil)
                    .frame(width: 232, height: 580)
                    .background(CK.sidebar)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 20) {
                    peek(threads: threads, isLocked: false, meeting: true)
                    peek(threads: threads, isLocked: false, meeting: false)
                    peek(threads: [], isLocked: true, meeting: false)
                }
            }
            .padding(24)
            .background(CK.island)
        )
        snapshot("cookie-sidebar-search-preview", content:
            CookieSidebarContent(search: .constant("unmatched phrase"), settingsPage: .constant(nil), section: .constant(.chats),
                                 threads: threads, selectedThreadID: nil, isWorking: false, isLocked: false,
                                 displayName: "Alex", newChat: {}, selectThread: { _ in }, deleteThread: { _ in })
                .frame(width: 196, height: 360).background(CK.island)
        )
    }

    /// Today, the board, the table and one item, with sample work (never the person's).
    static func renderWork() {
        let store = WorkStore.sample()
        let pilot = store.items.first { $0.title == "Northwind team pilot" }!
        let manager = CompanionManager()
        let navigation = CookieNavigation()
        func page<V: View>(_ content: V) -> some View {
            content.frame(width: 690, height: 550).background(CK.island).foregroundStyle(CK.text)
        }
        let lists = ListStore.sample(linkedTo: store)
        snapshot("cookie-board-preview", content: page(BoardView(store: store, lists: lists, companionManager: manager, navigation: navigation)))
        snapshot("cookie-board-wide-preview", content:
            BoardView(store: store, lists: lists, companionManager: manager, navigation: navigation)
                .frame(width: 1180, height: 720).background(CK.island).foregroundStyle(CK.text))
        renderCreation()
        // Cookie's marks on a 690×550 display at the origin: every kind, labelled.
        let marksFrame = CGRect(x: 0, y: 0, width: 690, height: 550)
        let marks: [CookieResolvedDrawing] = [
            CookieResolvedDrawing(geometry: .circle(CGRect(x: 120, y: 330, width: 110, height: 40)), text: "this cell", displayFrame: marksFrame),
            CookieResolvedDrawing(geometry: .arrow(from: CGPoint(x: 260, y: 350), to: CGPoint(x: 420, y: 300)), text: "should sum these", displayFrame: marksFrame),
            CookieResolvedDrawing(geometry: .underline(from: CGPoint(x: 120, y: 240), to: CGPoint(x: 330, y: 240)), text: "", displayFrame: marksFrame),
            CookieResolvedDrawing(geometry: .bracket(x: 90, top: 200, bottom: 120), text: "move up", displayFrame: marksFrame),
            CookieResolvedDrawing(geometry: .note(CGPoint(x: 440, y: 180)), text: "should be B2:B40", displayFrame: marksFrame),
            CookieResolvedDrawing(geometry: .number(CGPoint(x: 480, y: 470)), text: "1", displayFrame: marksFrame),
            CookieResolvedDrawing(geometry: .number(CGPoint(x: 560, y: 420)), text: "2", displayFrame: marksFrame),
        ]
        snapshot("cookie-marks-preview", content:
            ZStack {
                Color(white: 0.96)
                VStack(alignment: .leading, spacing: 18) {
                    Text("Quarterly totals").font(.system(size: 22, weight: .semibold))
                    ForEach(0..<6) { row in
                        HStack(spacing: 24) { ForEach(0..<4) { col in Text("\(row * 4 + col * 137)").frame(width: 90, alignment: .leading) } }
                    }
                }
                .foregroundStyle(Color.black.opacity(0.75)).padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                CookieMarksLayer(marks: marks, screenFrame: marksFrame, instant: true)
            }
            .frame(width: 690, height: 550))
        snapshot("cookie-menu-preview", content: CookieMenuList(items: WorkColumn.allCases.map { column in
            CookieMenuItem(column.title, symbol: column.symbol, tint: column.tint, checked: column == .needsYou) {}
        } + [CookieMenuItem("Delete list", symbol: "trash", destructive: true, separated: true) {}]) {})
        snapshot("cookie-item-preview", content: page(WorkItemView(store: store, companionManager: manager, navigation: navigation, id: pilot.id)))
        let emptyStore = WorkStore(connected: false)
        snapshot("cookie-board-empty-preview", content: page(BoardView(store: emptyStore, lists: ListStore(connected: false), companionManager: manager, navigation: navigation)))
        snapshot("cookie-board-compact-preview", content:
            BoardView(store: store, lists: lists, companionManager: manager, navigation: navigation)
                .frame(width: 380, height: 620).background(CK.island).foregroundStyle(CK.text))
        let editorNavigation = CookieNavigation()
        editorNavigation.workDraft.title = "Turn a promising conversation into a pilot"
        editorNavigation.workDraft.nextStep = "Prepare a short proposal with the goals, timeline and next decision."
        editorNavigation.workDraft.person = "Northwind team"
        editorNavigation.workDraft.hasDueDate = true
        snapshot("cookie-work-editor-preview", content: page(CookieNewWorkView(store: store, navigation: editorNavigation, draft: editorNavigation.workDraft)))
        snapshot("cookie-work-editor-compact-preview", content:
            CookieNewWorkView(store: store, navigation: editorNavigation, draft: editorNavigation.workDraft)
                .frame(width: 380, height: 600).background(CK.island).foregroundStyle(CK.text))
        snapshot("cookie-item-compact-preview", content:
            WorkItemView(store: store, companionManager: manager, navigation: navigation, id: pilot.id)
                .frame(width: 380, height: 620).background(CK.island).foregroundStyle(CK.text))
    }

    private static func renderCreation() {
        let identity = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        func surface(phase: CookieComposerPhase = .ready, progress: Double = 1, answer: String = "", problem: String? = nil) -> some View {
            CookieCreationSurface(identity: identity, agent: nil, isProfile: false, phase: phase,
                                  preparingSpeech: false, audioLevel: 0.7,
                                  line: answer.isEmpty ? CookieCreationSession.opening : "A thoughtful research companion. What would you like it to keep an eye on?",
                                  speechProgress: progress, lastAnswer: answer, problem: problem,
                                  typed: .constant(problem == nil ? "" : "Research my market"),
                                  back: {}, submit: {}, beginHolding: {}, endHolding: {}, stop: {}, replay: {}) { EmptyView() } actions: { EmptyView() }
        }
        snapshot("cookie-new-cookie-preview", content: surface().frame(width: 690, height: 550).background(CK.island))
        snapshot("cookie-new-cookie-compact-preview", content: surface().frame(width: 380, height: 620).background(CK.island))
        snapshot("cookie-new-cookie-speaking-preview", content:
            surface(phase: .speaking, progress: 0.48, answer: "Help me research my competitors.")
                .frame(width: 690, height: 550).background(CK.island))
        snapshot("cookie-new-cookie-listening-preview", content:
            surface(phase: .listening).frame(width: 380, height: 500).background(CK.island))
        snapshot("cookie-new-cookie-error-preview", content:
            surface(problem: "Couldn't connect. Your idea is still here. Try again when you're ready.")
                .frame(width: 380, height: 460).background(CK.island))
        let store = CookieAgentStore(connected: false)
        let agent = CookieAgent(id: identity, name: "Scout", role: "Research companion",
                                detail: "Keeps an eye on competitors and turns the useful findings into clear, concise briefs.", kind: .research)
        store.add(agent)
        let creationNavigation = CookieNavigation()
        creationNavigation.agentPage = .new
        _ = creationNavigation.agentCreation.prepare(page: .new, profile: nil)
        creationNavigation.agentCreation.answer("Help me research competitors.", conversation: { _, _, _ in
            ("Meet Scout, your thoughtful research companion.", agent)
        }, speech: { _, _, _ in })
        snapshot("cookie-new-cookie-ready-preview", content:
            CookieNewAgentView(store: store, companionManager: CompanionManager(), navigation: creationNavigation)
                .frame(width: 690, height: 620).background(CK.island))
        let navigation = CookieNavigation()
        navigation.agentPage = .profile(identity)
        snapshot("cookie-new-cookie-profile-preview", content:
            CookieNewAgentView(store: store, companionManager: CompanionManager(), navigation: navigation)
                .frame(width: 690, height: 620).background(CK.island))
        snapshot("cookie-new-cookie-profile-compact-preview", content:
            CookieNewAgentView(store: store, companionManager: CompanionManager(), navigation: navigation)
                .frame(width: 380, height: 620).background(CK.island))
    }

    private static var generalSettings: some View {
        CookieSettingsScaffold(page: .general, subtitle: "Make Cookie feel at home on your Mac.") {
            CookieGeneralSettingsContent(showInDock: .constant(false),
                                         peekOnHover: .constant(true), sounds: .constant(true), openAtLogin: .constant(false))
        }
    }

    private static func sidebar(threads: [CookieThread], settingsPage: CookieNavigation.SettingsPage?) -> some View {
        CookieSidebarContent(search: .constant(""), settingsPage: .constant(settingsPage), section: .constant(.chats),
                             threads: threads, selectedThreadID: threads[1].id, isWorking: false, isLocked: false,
                             displayName: "Alex", newChat: {}, selectThread: { _ in }, deleteThread: { _ in })
    }

    private static func peek(threads: [CookieThread], isLocked: Bool, meeting: Bool) -> some View {
        let layout = NotchLayout(notchSize: CGSize(width: 190, height: 32), availableSize: CGSize(width: 1000, height: 800))
        let size = layout.size(for: .peek, voiceActive: false, threadCount: threads.count)
        let work = WorkStore.sample().items
        let upcoming = UpcomingMeeting(id: "m", title: "Northwind pilot call", start: Date().addingTimeInterval(12 * 60),
                                       end: Date().addingTimeInterval(42 * 60), attendees: ["Head of engineering, Northwind"])
        let lines = [
            PeekLines.latest(threads: threads, work: work, meetingNotes: nil, chatsLocked: isLocked),
            PeekLines.now(working: meeting, step: "Researching Initech", threadTitle: "Initech pilot", approval: nil, work: work),
            PeekLines.upNext(access: meeting ? .allowed : .notAsked, meeting: meeting ? upcoming : nil, recalled: nil, work: work),
        ]
        return NotchSurface(size: size, topRadius: 14, bottomRadius: 24) {
            CookiePeekContent(lines: lines, isLocked: isLocked, needsPermissions: false, headerHeight: 32,
                              showsShortcuts: .constant(false), perform: { _ in }, send: { _ in }, openChats: {}, openSettings: {}, draft: .constant(""))
        }
    }

    private static func sampleThreads() -> [CookieThread] {
        let titles = ["A little more room to think", "What’s on my screen?", "A calmer workspace"]
        let replies = ["Let’s make space for the important things.", "I can’t reach my server right now.", "Your next idea starts here."]
        return titles.indices.map { index in
            CookieThread(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)")!,
                         messages: [CompanionChatMessage(role: .user, text: titles[index]),
                                    CompanionChatMessage(role: index == 1 ? .failure : .assistant, text: replies[index])],
                         updatedAt: Date().addingTimeInterval(-Double(index + 1) * 86400))
        }
    }

    private static func snapshot<Content: View>(_ name: String, content: Content) {
        _ = NSApplication.shared
        let hostingView = NSHostingView(rootView: content.environment(\.colorScheme, .dark).symbolEffectsRemoved())
        hostingView.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: hostingView.fittingSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            preconditionFailure("Native preview failed: \(name)")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/\(name).png")
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output)
        window.close()
        print("Rendered build/\(name).png")
    }
}
