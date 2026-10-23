import AppKit
import SwiftUI

@MainActor
enum CookiePeekPresentationTests {
    static func run() {
        testMotionIsQuietAndCanBeDisabled()
        testVoiceAndApprovalStatusMatchReality()
        testQuickQuestionSurvivesClosingAndNavigation()
        testEachChatGetsOneSpecialist()
        print("4 peek presentation checks passed.")
    }

    private static func testMotionIsQuietAndCanBeDisabled() {
        var closedEyeFrames = 0
        for index in 0..<680 {
            let time = Double(index) / 100
            let pose = CookieCompanionPose.idle(at: time, engaged: false, enabled: true)
            precondition((0.994...1.006).contains(pose.scaleX))
            precondition((0.991...1.009).contains(pose.scaleY))
            precondition(abs(pose.lift) <= 0.006 && abs(pose.tilt) <= 0.8)
            precondition((0.12...1).contains(pose.eyeOpenness))
            if pose.eyeOpenness < 0.5 { closedEyeFrames += 1 }
            precondition(CookieCompanionPose.idle(at: time, engaged: true, enabled: false) == CookieCompanionPose())
        }
        precondition(closedEyeFrames > 0 && closedEyeFrames < 20)
        precondition(CookieCompanionPose.idle(at: 1, engaged: true, enabled: true).tilt == -4)
    }

    private static func testVoiceAndApprovalStatusMatchReality() {
        let store = WorkStore(connected: false)
        store.add(title: "A tracked task", column: .cookie)
        let idle = PeekLines.now(working: false, step: nil, threadTitle: nil, approval: nil, work: store.items)
        precondition(!idle.busy && idle.characterMood == .idle && idle.detail == "1 with Cookie")
        let listening = PeekLines.now(working: false, step: nil, threadTitle: nil, approval: nil, work: [], voiceState: .listening)
        precondition(listening.characterMood == .listening && listening.action == .none)
        let speaking = PeekLines.now(working: false, step: nil, threadTitle: "Pilot", approval: nil, work: [], voiceState: .responding)
        precondition(speaking.characterMood == .speaking && speaking.action == .stop)
        let review = PeekLines.now(working: true, step: "Thinking", threadTitle: nil, approval: "Send the proposal?", work: [])
        precondition(review.action == .review && !review.busy)
        let working = PeekLines.now(working: true, step: "Reading the research", threadTitle: "Research", approval: nil, work: [])
        precondition(working.busy && working.characterMood == .thinking && working.title == "Reading the research")
    }

    private static func testQuickQuestionSurvivesClosingAndNavigation() {
        let navigation = CookieNavigation()
        navigation.peekDraft = "Compare these two proposals"
        navigation.section = .board
        navigation.showsShortcuts = true
        navigation.settingsPage = .general
        navigation.settingsPage = nil
        navigation.section = .chats
        precondition(navigation.peekDraft == "Compare these two proposals")
    }

    private static func testEachChatGetsOneSpecialist() {
        precondition(CookieSpecialist.infer(from: "Draft a reply to Anna's email") == .writer)
        precondition(CookieSpecialist.infer(from: "Build an ICP list for logistics firms") == .sales)
        precondition(CookieSpecialist.infer(from: "Research how Northwind prices its pilots") == .research)
        precondition(CookieSpecialist.infer(from: "Fill the spreadsheet with these totals") == .mac)
        precondition(CookieSpecialist.infer(from: "hello") == .general && CookieSpecialist.general.brief.isEmpty)
        // Chats saved before specialists existed still open, as general.
        let old = try! JSONDecoder().decode(CookieThread.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","messages":[],"updatedAt":0}"#.utf8))
        precondition(old.agentID == nil)
        // Only Cookie ships; a made Cookie comes from the JSON in Cookie's reply, prose around it ignored.
        let agents = CookieAgentStore(connected: false)
        precondition(agents.agents.count == 1 && agents.agent(for: .writer).name == "Cookie")
        let id = UUID()
        let made = CookieAgent.draft(from: #"sure! {"name":"Scout","role":"Competitor watcher","detail":"Watches rivals and says what changed.","kind":"Research"} hope that helps"#, id: id)!
        precondition(made.id == id && made.kind == .research && made.brief.hasPrefix("you are Scout, competitor watcher."))
        precondition(CookieAgent.draft(from: "no json here", id: id) == nil && CookieAgent.draft(from: #"{"name":"  "}"#, id: id) == nil)
        agents.add(made)
        precondition(agents.agent(for: .research).name == "Scout" && agents.agents.count == 2)
        agents.remove(agents.agent(for: .general).id)
        precondition(agents.agents.count == 2)
        agents.remove(id)
        precondition(agents.agents.count == 1)
        // Every tune renders to a playable wave; a tick is shorter than the done chord.
        precondition(CookieSound.allCases.allSatisfy { CookieSounds.wave($0).count > 44 })
        precondition(CookieSounds.wave(.send).count < CookieSounds.wave(.done).count)
    }

    static func render() {
        let store = WorkStore(connected: false)
        let item = store.add(title: "Northwind team pilot", nextStep: "Review the proposal", due: Date())
        store.update(item.id, by: "cookie", note: "Your one-page brief is ready") { _ in }
        let latest = PeekLines.latest(threads: [], work: store.items, meetingNotes: nil, chatsLocked: false)
        let idle = PeekLines.now(working: false, step: nil, threadTitle: nil, approval: nil, work: store.items)
        let connect = PeekLines.upNext(access: .notAsked, meeting: nil, recalled: nil, work: [])
        let meeting = UpcomingMeeting(id: "preview", title: "Northwind pilot call", start: Date().addingTimeInterval(720),
                                      end: Date().addingTimeInterval(2520), attendees: ["Anna"])
        let next = PeekLines.upNext(access: .allowed, meeting: meeting, recalled: "Review the proposed timeline with Anna.", work: [])
        snapshot("cookie-peek-idle", lines: [latest, idle, connect])
        snapshot("cookie-peek-meeting", lines: [latest, idle, next])
        snapshot("cookie-peek-empty", lines: [
            PeekLines.latest(threads: [], work: [], meetingNotes: nil, chatsLocked: false),
            PeekLines.now(working: false, step: nil, threadTitle: nil, approval: nil, work: []),
            PeekLines.upNext(access: .allowed, meeting: nil, recalled: nil, work: [])
        ])
        snapshot("cookie-peek-working", lines: [latest,
            PeekLines.now(working: true, step: "Reading their latest research", threadTitle: "A short competitor brief", approval: nil, work: []), next], composerPhase: .thinking)
        let listening = PeekLines.now(working: false, step: nil, threadTitle: nil, approval: nil, work: [], voiceState: .listening)
        snapshot("cookie-peek-listening", lines: [latest, listening, next], composerPhase: .listening)
        snapshot("cookie-peek-listening-compact", lines: [latest, listening, next], width: 340, composerPhase: .listening)
        snapshot("cookie-peek-speaking", lines: [latest,
            PeekLines.now(working: false, step: nil, threadTitle: "Your meeting brief", approval: nil, work: [], voiceState: .responding), next],
                 composerPhase: .speaking)
        snapshot("cookie-peek-draft", lines: [latest, idle, next], draft: "Compare the two proposals")
        snapshot("cookie-peek-review", lines: [latest,
            PeekLines.now(working: true, step: nil, threadTitle: nil, approval: "Send the proposal to Anna at Northwind?", work: []), next])
        snapshot("cookie-peek-locked", lines: [latest, idle, next], locked: true)
        snapshot("cookie-peek-compact", lines: [latest, idle, connect], width: 340)
        snapshot("cookie-peek-short", lines: [latest, idle, connect], width: 340, height: 235)
    }

    private static func snapshot(_ name: String, lines: [PeekLine], width: CGFloat = 488, height: CGFloat = 314,
                                 locked: Bool = false, composerPhase: CookieComposerPhase = .ready, draft: String = "") {
        let content = NotchSurface(size: CGSize(width: width, height: height), topRadius: 14, bottomRadius: 24) {
            CookiePeekContent(lines: lines, isLocked: locked, needsPermissions: false, headerHeight: 32,
                              showsShortcuts: .constant(false), perform: { _ in }, send: { _ in }, openChats: {}, openSettings: {},
                              draft: .constant(draft), composerPhase: composerPhase, audioLevel: 0.72)
        }
        .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: content)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            preconditionFailure("Could not render \(name)")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/\(name).png")
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output)
        window.close()
        print("Rendered build/\(name).png")
    }
}
