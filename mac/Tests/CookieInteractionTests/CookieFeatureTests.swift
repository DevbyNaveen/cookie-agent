import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI

/// Place-bound Cookies, routines and watchers, writing grants, corrections, taught skills, what Cookie saw, and the sleeping face.
@MainActor
enum CookieFeatureTests {
    static func run() {
        testTheHotkeyGoesToTheCookieBoundToTheFrontApp()
        testRoutinesReadWhenAndWhatAndWatchersStayQuiet()
        testTypingNeedsNoCardOnlyInAllowedApps()
        testEditsToADraftBecomeOneLearnableSentence()
        testWhatThePersonDidBecomesASkillFile()
        testWhatCookieSawIsFoundByAFewWords()
        testTheFaceSleepsAndLooksWhereItPoints()
        testMarksAreReadFromTheReplyAndLandOnTheDisplay()
        testWordsOnTheOverlayStayWholeOnTheDisplay()
        testTheNotchSaysWhatCookieIsDoing()
        print("10 feature checks passed.")
    }

    private static func testWordsOnTheOverlayStayWholeOnTheDisplay() {
        let area = CGRect(x: 12, y: 37, width: 1000, height: 700)
        let pill = CGSize(width: 120, height: 20)
        // Room on the right: leading edge at the point.
        var placed = CookieOnScreen<EmptyView>.place(pill, at: CGPoint(x: 100, y: 300), side: .leading, flipX: 80, in: area)
        precondition(placed.centre == CGPoint(x: 160, y: 300) && !placed.flipped)
        // No room on the right: flips, trailing edge at flipX.
        placed = CookieOnScreen<EmptyView>.place(pill, at: CGPoint(x: 950, y: 300), side: .leading, flipX: 930, in: area)
        precondition(placed.centre == CGPoint(x: 870, y: 300) && placed.flipped)
        // A note at the very bottom edge is lifted inside; nothing to flip to is nudged in.
        placed = CookieOnScreen<EmptyView>.place(pill, at: CGPoint(x: 950, y: 745), side: .leading, flipX: nil, in: area)
        precondition(placed.centre == CGPoint(x: area.maxX - 60, y: area.maxY - 10) && !placed.flipped)
        placed = CookieOnScreen<EmptyView>.place(pill, at: CGPoint(x: 20, y: 0), side: .centre, flipX: nil, in: area)
        precondition(placed.centre == CGPoint(x: area.minX + 60, y: area.minY + 10))
    }

    private static func testTheHotkeyGoesToTheCookieBoundToTheFrontApp() {
        let store = CookieAgentStore(connected: false)
        var quill = CookieAgent(name: "Quill", role: "Writer", detail: "", kind: .writer)
        quill.apps = ["Mail", "com.tinyspeck.slackmacgap"]
        store.add(quill)
        precondition(store.agent(forApp: "Mail", bundleID: "com.apple.mail")?.id == quill.id)
        precondition(store.agent(forApp: "Slack", bundleID: "com.tinyspeck.slackmacgap")?.id == quill.id)
        precondition(store.agent(forApp: "Finder", bundleID: "com.apple.finder") == nil)
        // Cookie herself never binds, even to an app named in her list.
        var cookie = store.agent(for: .general)
        cookie.apps = ["Finder"]
        store.update(cookie)
        precondition(store.agent(forApp: "Finder", bundleID: "com.apple.finder") == nil)
    }

    private static func testRoutinesReadWhenAndWhatAndWatchersStayQuiet() {
        let calendar = Calendar.current
        let monday9 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9, minute: 0))! // a Monday
        let routine = CookieRoutine(parsing: "every morning, check what changed with these five companies", from: monday9)!
        precondition(routine.instruction == "Check what changed with these five companies" && routine.onlyWhen.isEmpty)
        precondition(routine.cadence == .daily(hour: 9, minute: 0))
        precondition(calendar.component(.day, from: routine.nextRun) == 13 && calendar.component(.hour, from: routine.nextRun) == 9)
        let watcher = CookieRoutine(parsing: "every 15 minutes check my inbox, tell me only when anyone from Northwind replied", from: monday9)!
        precondition(watcher.cadence == .every(minutes: 15) && watcher.onlyWhen == "anyone from Northwind replied")
        precondition(watcher.instruction == "Check my inbox" && watcher.nextRun == monday9.addingTimeInterval(900))
        precondition(CookieBackgroundRuns.input(for: watcher).contains("reply with exactly NOTHING_NEW"))
        precondition(CookieBackgroundRuns.input(for: routine) == routine.instruction)
        let friday = CookieRoutine(parsing: "weekdays at 5pm send me the pipeline", from: monday9)!
        precondition(friday.cadence == .weekdays(hour: 17, minute: 0))
        let saturday18 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 18))!
        precondition(calendar.component(.weekday, from: friday.cadence.next(after: saturday18)) == 2) // skips to Monday
        precondition(CookieRoutine(parsing: "every monday, summarise last week", from: monday9)?.cadence == .weekly(weekday: 2, hour: 9, minute: 0))
        precondition(CookieRoutine(parsing: "check the pipeline", from: monday9) == nil) // no "when": nothing to schedule
        precondition(CookieRoutine(parsing: "every morning", from: monday9) == nil) // no "what"
        // Due routines fire once and move on; nothing fires early.
        let store = CookieAgentStore(connected: false)
        var scout = CookieAgent(name: "Scout", role: "Researcher", detail: "", kind: .research)
        scout.routines = [routine]
        store.add(scout)
        let runs = CookieBackgroundRuns() // no manager: rejected admission must leave the routine due
        runs.fireDueRoutines(store: store, now: monday9)
        precondition(store.agent(scout.id)!.routines[0].lastRun == nil)
        let tuesday9 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9, minute: 1))!
        runs.fireDueRoutines(store: store, now: tuesday9)
        precondition(store.agent(scout.id)!.routines[0].lastRun == nil)
        precondition(calendar.component(.day, from: store.agent(scout.id)!.routines[0].nextRun) == 13)
        runs.fireDueRoutines(store: store, now: tuesday9.addingTimeInterval(30))
        precondition(store.agent(scout.id)!.routines[0].lastRun == nil)
        precondition(store.agent(scout.id)!.routines[0].nextRun < tuesday9)
    }

    private static func testTypingNeedsNoCardOnlyInAllowedApps() {
        let typing = HarnessApproval(id: "a", tool: "type_text", effect: "write", preview: "type_text {\"text\":\"hello\"}", reason: "")
        precondition(CookieWriteGrants.covers(typing, frontAppName: "Mail", frontBundleID: "com.apple.mail", apps: ["Mail"]))
        precondition(!CookieWriteGrants.covers(typing, frontAppName: "Safari", frontBundleID: "com.apple.Safari", apps: ["Mail"]))
        precondition(!CookieWriteGrants.covers(typing, frontAppName: "Mail", frontBundleID: "com.apple.mail", apps: []))
        let fromData = HarnessApproval(id: "b", tool: "type_text", effect: "write", preview: "type_text {\"text\":\"x\"}", reason: "", fromData: ["text"])
        precondition(!CookieWriteGrants.covers(fromData, frontAppName: "Mail", frontBundleID: nil, apps: ["Mail"]))
        let sending = HarnessApproval(id: "c", tool: "key", effect: "write", preview: "key {\"keys\":\"cmd+return\"}", reason: "")
        precondition(!CookieWriteGrants.covers(sending, frontAppName: "Mail", frontBundleID: nil, apps: ["Mail"]))
        let task = HarnessApproval(id: "d", tool: "start_task", effect: "outbound", preview: "start_task {\"plan\":\"draft\",\"apps\":\"Mail, Notes\"}", reason: "")
        precondition(CookieWriteGrants.covers(task, frontAppName: "Finder", frontBundleID: nil, apps: ["Mail", "Notes"]))
        precondition(!CookieWriteGrants.covers(task, frontAppName: "Finder", frontBundleID: nil, apps: ["Mail"]))
    }

    private static func testEditsToADraftBecomeOneLearnableSentence() {
        let draft = "Thanks for the call today. I will send the security document tomorrow. Looking forward to the pilot."
        let sent = "Thanks for the call today. The security document is attached. Looking forward to the pilot."
        let summary = CookieCorrections.summary(before: draft, after: sent, app: "Mail")!
        precondition(summary.hasPrefix("In Mail the person edited Cookie's draft: dropped “I will send the security document tomorrow”"))
        precondition(summary.contains("wrote “The security document is attached”"))
        precondition(CookieCorrections.summary(before: draft, after: draft, app: "Mail") == nil)
        precondition(CookieCorrections.summary(before: draft, after: "Completely different text about something else entirely.", app: "Mail") == nil)
        precondition(CookieCorrections.summary(before: "hi", after: "hello there", app: "Mail") == nil)
        precondition(CookieCorrections.summary(before: draft, after: "Thanks for the call today.", app: "Mail")!.hasSuffix("; shorter than Cookie's draft."))
    }

    private static func testWhatThePersonDidBecomesASkillFile() {
        let steps: [CookieTeachStep] = [
            .press(app: "Mail", role: "Button", label: "New Message"),
            .type(app: "Mail", field: "To:", text: "anna@northwind.example"),
            .typedSomethingPrivate(app: "1Password"),
            .key(app: "Mail", combo: "cmd+shift+d"),
        ]
        let markdown = CookieSkillWriter.markdown(name: "Send the weekly report", steps: steps, taughtOn: Date(timeIntervalSince1970: 0))
        precondition(markdown.hasPrefix("---\nname: taught-send-the-weekly-report\ndescription: \"Send the weekly report — taught on"))
        precondition(markdown.contains("4 steps in Mail, 1Password"))
        precondition(markdown.contains("1. In Mail: press the button \"New Message\" (find it with look)."))
        precondition(markdown.contains("2. In Mail: type \"anna@northwind.example\" into \"To:\""))
        precondition(markdown.contains("3. In 1Password: the person typed something private here; ask them to do this step themselves."))
        precondition(markdown.contains("4. In Mail: press cmd+shift+d (key)."))
        precondition(markdown.contains("`start_task` with the plan \"Send the weekly report\" and the apps: Mail, 1Password."))
        precondition(CookieSkillWriter.slug("  Weekly  Report!! ") == "taught-weekly-report" && CookieSkillWriter.slug("???") == "taught-skill")
        precondition(MacKeys.name(for: CGKeyCode(kVK_Return)) == "return" && MacKeys.name(for: CGKeyCode(kVK_ANSI_S)) == "s")
    }

    private static func testWhatCookieSawIsFoundByAFewWords() {
        let memory = CookieScreenMemory(connected: false)
        let now = Date()
        memory.add(ScreenMemoryEntry(date: now.addingTimeInterval(-3600), app: "Safari", text: "Pricing\nTeam plan €59 per seat\nEnterprise: talk to us"))
        memory.add(ScreenMemoryEntry(date: now.addingTimeInterval(-120), app: "Mail", text: "From: Anna\nSubject: pilot timeline\nCan we start in November?"))
        precondition(memory.recall("pricing team plan", now: now).first?.app == "Safari")
        precondition(memory.recall("anna pilot", now: now).first?.app == "Mail")
        precondition(memory.recall("zebra", now: now).isEmpty)
        let answer = memory.answer("team plan", now: now)
        precondition(answer.hasPrefix("1 h ago in Safari:\n") && answer.contains("Team plan €59 per seat") && !answer.contains("Enterprise"))
        precondition(memory.answer("zebra", now: now) == "Nothing like that in what Cookie saw today.")
        // A day later it's gone; the newest 300 stay.
        memory.add(ScreenMemoryEntry(date: now.addingTimeInterval(-25 * 3600), app: "Notes", text: "old words"))
        precondition(memory.recall("old words", now: now).isEmpty)
    }

    private static func testTheNotchSaysWhatCookieIsDoing() {
        func word(_ state: CompanionVoiceState, _ step: String?, _ waited: TimeInterval = 0) -> String {
            LiveStatus(voiceState: state, step: step, waited: waited).word
        }
        precondition(word(.listening, nil) == "Listening" && word(.responding, nil) == "Speaking")
        precondition(word(.processing, "Looking at your screen") == "Looking")
        precondition(word(.processing, "Searching the web") == "Searching" && word(.processing, "Reading a page") == "Reading")
        precondition(word(.processing, "Checking a quote") == "Checking" && word(.processing, "Using calendar") == "Working")
        precondition(word(.processing, "Thinking") == "Thinking" && word(.processing, nil, LiveStatus.harderAfter) == "Thinking harder")
        // Every word fits its side of the notch: the narrowest live width leaves (196 + 12) / 2 pt a side.
        for w in ["Listening", "Speaking", "Looking", "Searching", "Reading", "Checking", "Writing", "Working", "Thinking harder"] {
            let width = (w as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width
            precondition(width + 13 < 104, "\(w) is \(width) pt")
        }
    }

    private static func testTheFaceSleepsAndLooksWhereItPoints() {
        let asleep = CookieCompanionPose.asleep(at: 3)
        precondition(asleep.eyeOpenness == 0.12 && asleep.tilt == 3 && abs(asleep.scaleY - 1) < 0.02)
        precondition(abs(CookieCompanionPose.asleep(at: 0).scaleY - CookieCompanionPose.asleep(at: 11).scaleY) < 0.0001) // one slow breath per 11 s
        let lines = PeekLines.now(working: false, step: nil, threadTitle: nil, approval: nil, work: [], dozing: true)
        precondition(lines.characterMood == .sleeping && lines.title == "Resting")
        precondition(PeekLines.now(working: false, step: nil, threadTitle: nil, approval: nil, work: []).characterMood == .idle)
    }

    private static func testMarksAreReadFromTheReplyAndLandOnTheDisplay() {
        let reply = "the total is in the wrong cell. [DRAW:circle:400,300,30:this cell] [DRAW:arrow:400,300,600,300:should sum these] [DRAW:note:620,280:B2:B40] [DRAW:number:#12:1] [DRAW:bogus:1,2] [DRAW:note:10,10:] [POINT:400,300:total cell]"
        let (text, marks) = CookieDrawing.parse(from: reply)
        precondition(text == "the total is in the wrong cell. [POINT:400,300:total cell]")
        precondition(marks.count == 4 && marks[0].kind == .circle && marks[0].extent == 30 && marks[0].text == "this cell")
        precondition(marks[1].anchor == .pixels([CGPoint(x: 400, y: 300), CGPoint(x: 600, y: 300)]))
        precondition(marks[2].kind == .note && marks[2].text == "B2:B40" && marks[3].anchor == .element(12) && marks[3].text == "1")
        precondition(CookieDrawing.parse(from: "[DRAW:circle:1,1,5:a:screen2]").marks.first?.screenNumber == 2)
        precondition(CookieDrawing.parse(from: String(repeating: "[DRAW:number:1,1:1] ", count: 9)).marks.count == CookieDrawing.maxMarks)
        precondition(CookieDrawing.parse(from: "plain words").marks.isEmpty)

        // A 1000×500-pixel screenshot of a 500×250-point display sitting at (100, 50): pixels halve, y flips.
        let capture = CompanionScreenCapture(imageData: Data(), label: "screen 1", isCursorScreen: true, displayWidthInPoints: 500, displayHeightInPoints: 250,
                                             displayFrame: CGRect(x: 100, y: 50, width: 500, height: 250), screenshotWidthInPixels: 1000, screenshotHeightInPixels: 500, hiddenItems: 0)
        precondition(CookieDrawingResolver.global(CGPoint(x: 0, y: 0), in: capture) == CGPoint(x: 100, y: 300))
        precondition(CookieDrawingResolver.global(CGPoint(x: 1000, y: 500), in: capture) == CGPoint(x: 600, y: 50))
        let placed = CookieDrawingResolver.resolve(marks, captures: [capture],
                                                elementFrame: { id in id == 12 ? CGRect(x: 10, y: 20, width: 100, height: 30) : nil },
                                                snap: { _ in nil })
        precondition(placed.count == 4 && placed.allSatisfy { $0.displayFrame == capture.displayFrame || $0.text == "1" })
        if case .circle(let rect) = placed[0].geometry { precondition(abs(rect.midX - 300) < 0.01 && abs(rect.midY - 150) < 0.01 && abs(rect.width - 44) < 0.01) } else { preconditionFailure() }
        if case .arrow(let from, let to) = placed[1].geometry { precondition(from == CGPoint(x: 300, y: 150) && to == CGPoint(x: 400, y: 150)) } else { preconditionFailure() }
        if case .note(let point) = placed[2].geometry { precondition(point == CGPoint(x: 410, y: 160)) } else { preconditionFailure() }
        // An element mark comes from its look frame, flipped into AppKit, numbered at its top-left.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        if case .number(let point) = placed[3].geometry { precondition(point == CGPoint(x: 10, y: mainHeight - 20)) } else { preconditionFailure() }
        // Snapping: a circle aimed near a control wraps the control instead.
        let snapped = CookieDrawingResolver.resolve([marks[0]], captures: [capture], elementFrame: { _ in nil },
                                                 snap: { _ in CGRect(x: 280, y: mainHeight - 160, width: 40, height: 20) })
        if case .circle(let rect) = snapped[0].geometry { precondition(abs(rect.width - 54) < 0.01 && abs(rect.minX - 273) < 0.01) } else { preconditionFailure() }
    }
}
