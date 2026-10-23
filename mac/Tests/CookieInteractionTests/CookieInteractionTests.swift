import Foundation
import AppKit
import SwiftUI

@MainActor
final class CookieInteractionTests {
    func testPassingAcrossNotchDoesNotOpenItLater() {
        var hover = NotchHoverIntent()
        expectNil(hover.update(state: .closed, insideTrigger: true, insideIsland: true, enabled: true, now: 0))
        expectNil(hover.update(state: .closed, insideTrigger: false, insideIsland: false, enabled: true, now: 0.1))
        expectNil(hover.update(state: .closed, insideTrigger: false, insideIsland: false, enabled: true, now: 0.5))
        expectNil(hover.deadline)
    }

    func testSmallPointerMovementsDoNotRestartHoverDelay() {
        var hover = NotchHoverIntent()
        expectNil(hover.update(state: .closed, insideTrigger: true, insideIsland: true, enabled: true, now: 0))
        expectNil(hover.update(state: .closed, insideTrigger: true, insideIsland: true, enabled: true, now: 0.15))
        expectEqual(hover.update(state: .closed, insideTrigger: true, insideIsland: true, enabled: true, now: 0.23), .peek)
    }

    func testReenteringPeekCancelsPendingClose() {
        var hover = NotchHoverIntent()
        expectNil(hover.update(state: .peek, insideTrigger: false, insideIsland: false, enabled: true, now: 0))
        expectNil(hover.update(state: .peek, insideTrigger: false, insideIsland: true, enabled: true, now: 0.1))
        expectNil(hover.update(state: .peek, insideTrigger: false, insideIsland: true, enabled: true, now: 0.3))
        expectNil(hover.deadline)
    }

    func testLeavingPeekClosesAfterGracePeriod() {
        var hover = NotchHoverIntent()
        expectNil(hover.update(state: .peek, insideTrigger: false, insideIsland: false, enabled: true, now: 0))
        expectEqual(hover.update(state: .peek, insideTrigger: false, insideIsland: false, enabled: true, now: 0.19), .closed)
    }

    func testClickingHomeOrDisablingHoverCancelsPendingOpen() {
        for destination in [NotchState.closed, .home, .notice] {
            var hover = NotchHoverIntent()
            _ = hover.update(state: .closed, insideTrigger: true, insideIsland: true, enabled: true, now: 0)
            expectNil(hover.update(state: destination, insideTrigger: true, insideIsland: true, enabled: false, now: 0.3))
            expectNil(hover.deadline)
        }
    }

    func testEveryIslandStateFitsTheAvailableDisplay() {
        for availableSize in [CGSize(width: 480, height: 350), CGSize(width: 800, height: 500), CGSize(width: 1600, height: 1000)] {
            let layout = NotchLayout(notchSize: CGSize(width: 190, height: 32), availableSize: availableSize)
            for state in [NotchState.closed, .peek, .home, .notice] {
                let size = layout.size(for: state, voiceActive: true, threadCount: 100)
                expectAtMost(size.width, availableSize.width)
                expectAtMost(size.height, availableSize.height)
                expectGreater(size.width, 0)
                expectGreater(size.height, 0)
            }
        }
    }

    func testStandardDisplayKeepsExistingIslandDimensions() {
        let layout = NotchLayout(notchSize: CGSize(width: 190, height: 32), availableSize: CGSize(width: 1400, height: 850))
        expectEqual(layout.size(for: .home, voiceActive: false, threadCount: 3), CGSize(width: 928, height: 580))
        expectEqual(layout.size(for: .peek, voiceActive: false, threadCount: 3), CGSize(width: 488, height: 314))
    }

    func testPreviewNeverSqueezesTheConversationBelowItsMinimum() {
        for width: CGFloat in [480, 700, 740, 900, 1000, 1200, 1600] {
            let layout = CookieHomeLayout(width: width)
            if layout.showsInlinePreview {
                expectAtLeast(layout.conversationWidth - layout.previewWidth, 372)
                expectAtLeast(layout.previewWidth, 280)
            }
            expectAtMost(layout.drawerWidth, width)
        }
        expectFalse(CookieHomeLayout(width: 700).showsSidebar)
        expectFalse(CookieHomeLayout(width: 900).showsInlinePreview)
        expectTrue(CookieHomeLayout(width: 1200).showsInlinePreview)
    }

    @MainActor
    func testDraftSurvivesViewRecreationAndIsIsolatedByChat() {
        let store = CookieDraftStore()
        let firstThread = UUID()
        let secondThread = UUID()
        let firstDraft = store.draft(for: firstThread)
        firstDraft.text = "An unsent thought"
        firstDraft.attach(CookieAttachment(path: "/tmp/first.pdf"))
        store.draft(for: secondThread).text = "Another thought"
        expectTrue(store.draft(for: firstThread) === firstDraft)
        expectEqual(store.draft(for: firstThread).text, "An unsent thought")
        expectEqual(store.draft(for: firstThread).attachments.count, 1)
        expectTrue(store.draft(for: secondThread).attachments.isEmpty)
        expectTrue(store.draft(for: nil).text.isEmpty)
    }

    @MainActor
    func testNewChatDraftFollowsTheThreadCreatedByVoiceOrSend() {
        let store = CookieDraftStore()
        let originalDraft = store.draft(for: nil)
        originalDraft.text = "Keep this while I dictate"
        let threadID = UUID()
        store.adoptNewChat(for: threadID)
        expectTrue(store.draft(for: threadID) === originalDraft)
        expectTrue(store.draft(for: nil).text.isEmpty)
        originalDraft.clear()
        expectTrue(store.draft(for: threadID).text.isEmpty)
    }

    @MainActor
    func testDeletingChatsClearsDraftsAndDetachesLateFileLoads() {
        let store = CookieDraftStore()
        let threadID = UUID()
        let deletedDraft = store.draft(for: threadID)
        deletedDraft.text = "Remove me"
        store.remove(threadID: threadID)
        expectTrue(deletedDraft.text.isEmpty)
        expectFalse(store.draft(for: threadID) === deletedDraft)
        let oldNewChat = store.draft(for: nil)
        store.removeAll()
        oldNewChat.attach(CookieAttachment(path: "/tmp/late-file.pdf"))
        expectTrue(store.draft(for: nil).attachments.isEmpty)
    }

    func testOutgoingContentAndBlurStayInsideEveryIntermediateSilhouette() {
        let canvasSize = CGSize(width: 960, height: 660)
        for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            let size = CGSize(width: 928 - 726 * progress, height: 580 - 548 * progress)
            let topRadius = 14 - 8 * progress
            let bottomRadius = 30 - 20 * progress
            let surface = NotchSurface(size: size, topRadius: topRadius, bottomRadius: bottomRadius, capturing: true) {
                // Oversized, blurred outgoing content must not survive outside
                // the shrinking shell, even before its opacity reaches zero.
                VStack {
                    HStack {
                        ForEach(0..<8) { _ in
                            Circle().fill(.orange).frame(width: 50, height: 50)
                                .shadow(color: .white, radius: 24)
                        }
                    }
                    Color.purple.opacity(0.5)
                }
                .frame(width: 900, height: 580)
            }
            .frame(width: canvasSize.width, height: canvasSize.height, alignment: .top)
            let renderer = ImageRenderer(content: surface)
            renderer.scale = 1
            guard let image = renderer.cgImage else { preconditionFailure("Native notch render failed") }
            let bitmap = NSBitmapImageRep(cgImage: image)
            let bounds = CGRect(x: (canvasSize.width - size.width) / 2, y: 0, width: size.width, height: size.height)
            let silhouette = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius).path(in: bounds)
            let antialiasingEdge = silhouette.strokedPath(StrokeStyle(lineWidth: 4))
            for verticalPosition in stride(from: 0, to: Int(canvasSize.height), by: 3) {
                for horizontalPosition in stride(from: 0, to: Int(canvasSize.width), by: 3) {
                    let point = CGPoint(x: Double(horizontalPosition) + 0.5, y: Double(verticalPosition) + 0.5)
                    if !silhouette.contains(point) && !antialiasingEdge.contains(point) {
                        let alpha = bitmap.colorAt(x: horizontalPosition, y: verticalPosition)?.alphaComponent ?? 0
                        // The flared top corner can leave 3/255 coverage just beyond
                        // the analytic path on this renderer. Solid content must still fail.
                        precondition(alpha <= 4.0 / 255, "Content escaped the island mask at progress \(progress): x=\(horizontalPosition), y=\(verticalPosition), alpha=\(alpha), pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
                    }
                }
            }
            if CommandLine.arguments.contains("--render") {
                let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("build/notch-mask-\(Int(progress * 100)).png")
                try! bitmap.representation(using: .png, properties: [:])!.write(to: output)
            }
        }
    }

    func testComposerCannotSendOverRecordingOrAnActiveReply() {
        expectTrue(CookieComposerPhase(voiceState: .idle, isWorking: false, holding: false).canSubmit)
        expectFalse(CookieComposerPhase(voiceState: .idle, isWorking: false, holding: true).canSubmit)
        for voiceState in [CompanionVoiceState.listening, .processing, .responding] {
            expectFalse(CookieComposerPhase(voiceState: voiceState, isWorking: false, holding: false).canSubmit)
        }
        expectFalse(CookieComposerPhase(voiceState: .idle, isWorking: true, holding: false).canSubmit)
    }

    func testComposerStopBelongsOnlyToAReply() {
        expectFalse(CookieComposerPhase(voiceState: .idle, isWorking: false, holding: false).canStop)
        expectFalse(CookieComposerPhase(voiceState: .listening, isWorking: true, holding: false).canStop)
        expectTrue(CookieComposerPhase(voiceState: .idle, isWorking: true, holding: false).canStop)
        expectTrue(CookieComposerPhase(voiceState: .responding, isWorking: false, holding: false).canStop)
    }

    func testCookieLooksOnlyWhenThePersonAsks() {
        var guardAsked = false
        let refusal: () -> String? = { guardAsked = true; return nil }
        // Typing without the screen button: no picture, and the guard isn't even consulted.
        expectEqual(ScreenLook.decide(asked: false, screenAllowed: true, refusal: refusal), .notAsked)
        expectFalse(guardAsked)
        expectEqual(ScreenLook.decide(asked: true, screenAllowed: true, refusal: refusal), .look)
        expectEqual(ScreenLook.decide(asked: true, screenAllowed: false, refusal: refusal), .refused("Screen access is off"))
        expectEqual(ScreenLook.decide(asked: true, screenAllowed: true, refusal: { "A password field is selected" }),
                    .refused("A password field is selected"))
        // The screen choice belongs to one message: sending clears it.
        let draft = CookieChatDraft()
        draft.withScreen = true
        draft.clear()
        expectFalse(draft.withScreen)
    }

    func testSpeakerPicksTheBestVoiceItCanActuallyUse() {
        let voices = [
            CookieSpeaker.Candidate(identifier: "com.apple.voice.compact.en-US.Samantha", language: "en-US", quality: 1),
            CookieSpeaker.Candidate(identifier: "com.apple.siri.natural.Simone", language: "en-US", quality: 2),
            CookieSpeaker.Candidate(identifier: "com.apple.voice.enhanced.en-GB.Daniel", language: "en-GB", quality: 2),
            CookieSpeaker.Candidate(identifier: "com.apple.voice.premium.en-US.Zoe", language: "en-US", quality: 3),
            CookieSpeaker.Candidate(identifier: "com.apple.voice.premium.de-DE.Anna", language: "de-DE", quality: 3),
        ]
        expectEqual(CookieSpeaker.best(voices, language: "en-US"), "com.apple.voice.premium.en-US.Zoe")
        // Same language family beats nothing; Siri voices are skipped (they fall back to the compact voice).
        expectEqual(CookieSpeaker.best(Array(voices.prefix(3)), language: "en-US"), "com.apple.voice.enhanced.en-GB.Daniel")
        // Only compact voices: leave the choice to the system.
        expectNil(CookieSpeaker.best(Array(voices.prefix(2)), language: "en-US"))
    }

    func testOpenFindsWhatThePersonNamed() {
        let apps = ["/System/Applications/System Settings.app", "/Applications/Safari.app",
                    "/Applications/Google Chrome.app", "/Applications/Google Docs.app", "/System/Applications/Notes.app"]
            .map { URL(fileURLWithPath: $0) }
        expectEqual(CookieOpen.resolve("settings", apps: apps), .success(.settings))
        expectEqual(CookieOpen.resolve("my System Preferences", apps: apps), .success(.settings))
        expectEqual(CookieOpen.resolve("Safari", apps: apps), .success(.app(apps[1])))
        expectEqual(CookieOpen.resolve("the notes app", apps: apps), .success(.app(apps[4])))
        expectEqual(CookieOpen.resolve("chrome", apps: apps), .success(.app(apps[2])))
        expectEqual(CookieOpen.resolve("https://enkeon.com/docs", apps: apps), .success(.web(URL(string: "https://enkeon.com/docs")!)))
        expectEqual(CookieOpen.resolve("enkeon.com", apps: apps), .success(.web(URL(string: "https://enkeon.com")!)))
        // Only web links: no file:, no custom schemes that run things.
        expectTrue(CookieOpen.resolve("file:///etc/passwd", apps: apps).isFailure)
        expectTrue(CookieOpen.resolve("javascript:alert(1)", apps: apps).isFailure)
        // Two matches: ask which, never guess.
        expectTrue(CookieOpen.resolve("google", apps: apps).isFailure)
        expectTrue(CookieOpen.resolve("photoshop", apps: apps).isFailure)
        // The card says what will open, not JSON.
        expectEqual(CookieOpen.describe(preview: #"open {"name":"settings"}"#, apps: apps), "Open System Settings")
        expectEqual(CookieOpen.describe(preview: #"open {"name":"enkeon.com"}"#, apps: apps), "Open https://enkeon.com in your browser")
        expectNil(CookieOpen.describe(preview: "open nonsense", apps: apps))
        // Declared so the harness always asks, and only the person's own words can name the target.
        let tool = String(decoding: HarnessWire.encode(CookieOpen.tool), as: UTF8.self)
        expectTrue(tool.contains(#""effect":"outbound""#) && tool.contains(#""guard":["name"]"#) && tool.contains(#""required":["name"]"#))
    }

    func testOpeningWithoutAskingFollowsTheSetting() {
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        let notes = URL(fileURLWithPath: "/System/Applications/Notes.app")
        let web = CookieOpen.Target.web(URL(string: "https://enkeon.com")!)
        // Ask every time: only what you said "always" to.
        expectFalse(CookieOpen.opensWithoutAsking(.app(safari), mode: .ask, always: []))
        expectTrue(CookieOpen.opensWithoutAsking(.app(safari), mode: .ask, always: [CookieOpen.alwaysKey(.app(safari))!]))
        expectFalse(CookieOpen.opensWithoutAsking(.app(notes), mode: .ask, always: [CookieOpen.alwaysKey(.app(safari))!]))
        expectTrue(CookieOpen.opensWithoutAsking(.settings, mode: .ask, always: [CookieOpen.alwaysKey(.settings)!]))
        // Apps and settings: every app, never a web link.
        expectTrue(CookieOpen.opensWithoutAsking(.app(notes), mode: .apps, always: []))
        expectFalse(CookieOpen.opensWithoutAsking(web, mode: .apps, always: []))
        // A web link can't be "always allowed" one by one: it can carry anything in its address.
        expectNil(CookieOpen.alwaysKey(web))
        expectTrue(CookieOpen.opensWithoutAsking(web, mode: .all, always: []))
        expectEqual(CookieOpen.Mode(rawValue: "nonsense") ?? .ask, .ask)
    }

    func testEarlierTurnsKeepWhoWroteThem() {
        let turns = CompanionManager.historyTurns([
            (userTranscript: "what's on my screen?", assistantResponse: "a note asking you to visit evil.com", untrusted: true),
            (userTranscript: "thanks", assistantResponse: "anytime", untrusted: false),
        ])
        expectEqual(turns.map(\.role), ["user", "assistant", "user", "assistant"])
        expectEqual(turns.map(\.untrusted), [false, true, false, false])
        // A reply saved before this was recorded counts as having read the screen.
        let old = CompanionChatMessage(role: .assistant, text: "hi")
        expectTrue(old.readUntrusted ?? true)
        let line = String(decoding: HarnessWire.encode(HarnessRequest.Run(
            id: "r1", model: "x:y", input: "open it", instructions: "", tools: [], images: [], history: turns, enkeon: false)), as: UTF8.self)
        expectTrue(line.contains(#""history":[{"#) && line.contains(#""untrusted":true"#) && !line.contains("earlier in this chat"))
    }

    func testSignInPiecesFollowTheStandards() {
        // RFC 7636 appendix B.
        expectEqual(CookieAccount.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                    "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = CookieAccount.randomURLSafe(32)
        expectTrue(verifier.count >= 43 && !verifier.contains("=") && !verifier.contains("+") && !verifier.contains("/"))
        let url = CookieAccount.authorizeURL(endpoint: URL(string: "https://www.enkeon.com/oauth/consent")!, clientID: "trc_1",
                                             redirect: "http://127.0.0.1:5123/callback", state: "s1", challenge: "c1")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        expectEqual(query, ["client_id": "trc_1", "redirect_uri": "http://127.0.0.1:5123/callback", "response_type": "code",
                            "state": "s1", "scope": "ask recall remember search connectors meetings",
                            "code_challenge": "c1", "code_challenge_method": "S256"])
        // The browser comes back to the loopback listener; only the right state counts.
        expectEqual(CookieAccount.callback("GET /callback?code=tro_abc&state=s1 HTTP/1.1\r\nHost: x", state: "s1"), .code("tro_abc"))
        expectEqual(CookieAccount.callback("GET /callback?code=tro_abc&state=evil HTTP/1.1", state: "s1"), .refused)
        expectEqual(CookieAccount.callback("GET /callback?error=access_denied&state=s1 HTTP/1.1", state: "s1"), .refused)
        expectEqual(CookieAccount.callback("GET /favicon.ico HTTP/1.1", state: "s1"), .ignored)
        // Renew a minute and a half before the hour runs out.
        let now = Date()
        expectFalse(CookieAccount.Tokens(clientID: "c", access: "a", refresh: "r", expires: now.addingTimeInterval(600)).needsRefresh(now: now))
        expectTrue(CookieAccount.Tokens(clientID: "c", access: "a", refresh: "r", expires: now.addingTimeInterval(60)).needsRefresh(now: now))
    }

    func testMacNotificationsOnlyWhenYouAreAway() {
        typealias N = CookieNotifications
        // Looking at the Mac: the notch card is enough.
        expectFalse(N.shouldNotify(.reply, level: .all, panelOpen: false, idleSeconds: 5, screenLocked: false))
        // Away (idle or locked): it waits in Notification Center.
        expectTrue(N.shouldNotify(.reply, level: .all, panelOpen: false, idleSeconds: 90, screenLocked: false))
        expectTrue(N.shouldNotify(.approval, level: .all, panelOpen: false, idleSeconds: 0, screenLocked: true))
        // Panel open: never.
        expectFalse(N.shouldNotify(.approval, level: .all, panelOpen: true, idleSeconds: 600, screenLocked: false))
        // "Approvals and failures" drops ordinary replies; "Off" drops everything.
        expectFalse(N.shouldNotify(.reply, level: .important, panelOpen: false, idleSeconds: 600, screenLocked: false))
        expectTrue(N.shouldNotify(.failure, level: .important, panelOpen: false, idleSeconds: 600, screenLocked: false))
        expectFalse(N.shouldNotify(.approval, level: .off, panelOpen: false, idleSeconds: 600, screenLocked: true))
        // Locked chats say nothing about the reply.
        expectEqual(N.text(title: "Maya pilot", body: "She signed.", kind: .reply, chatsLocked: true).body, "Cookie has a reply.")
        expectEqual(N.text(title: "Maya pilot", body: "She signed.", kind: .reply, chatsLocked: false).body, "She signed.")
        expectEqual(N.text(title: "Open System Settings?", body: "", kind: .approval, chatsLocked: false).title, "Cookie needs your OK")
        expectEqual(N.Level(rawValue: "nonsense") ?? .all, .all)
    }

    func testAValueFromDataIsShownAndNeverAnsweredForYou() {
        let line = HarnessWire.decode(Data(#"{"type":"approval","run":"r1","id":"a1","tool":"open","effect":"outbound","preview":"open {\"name\":\"safari\"}","reason":"r","from_data":["name = safari"]}"#.utf8))!
        expectEqual(line.fromData ?? [], ["name = safari"])
        let fromData = HarnessApproval(id: "a1", tool: "open", effect: "outbound", preview: #"open {"name":"settings"}"#, reason: "", fromData: ["name = settings"])
        let yours = HarnessApproval(id: "a2", tool: "open", effect: "outbound", preview: #"open {"name":"settings"}"#, reason: "", fromData: [])
        let apps = [URL(fileURLWithPath: "/System/Applications/System Settings.app")]
        // Even "Everything" never answers a card about a value you didn't write.
        expectFalse(CookieOpen.answersForYou(fromData, mode: .all, always: [], apps: apps))
        expectTrue(CookieOpen.answersForYou(yours, mode: .all, always: [], apps: apps))
        expectFalse(CookieOpen.answersForYou(yours, mode: .ask, always: [], apps: apps))
        // Every run asks the harness to put such values to you instead of refusing them.
        let run = String(decoding: HarnessWire.encode(HarnessRequest.Run(id: "r", model: "x:y", input: "hi", instructions: "", tools: [],
                                                                         images: [], history: [], enkeon: false)), as: UTF8.self)
        expectTrue(run.contains(#""confirm_data":true"#))
    }

    func testOneCardForEveryActionOfATurn() {
        let line = HarnessWire.decode(Data(#"{"type":"approval","run":"r1","id":"a7","items":[{"tool":"send_email","effect":"outbound","preview":"to anna","reason":"r","from_data":[]},{"tool":"send_email","effect":"outbound","preview":"to evil","reason":"r","from_data":["to = evil@x.com"]}]}"#.utf8))!
        let approval = HarnessApproval(line: line)!
        expectEqual(approval.id, "a7")
        expectEqual(approval.actions.map(\.preview), ["to anna", "to evil"])
        // Ticked to start: what you named; unticked: what Cookie found and you didn't write.
        expectEqual(approval.startingAnswers, [true, false])
        // A single action keeps the one-answer shape; a batch answers each.
        let one = String(decoding: HarnessWire.encode(HarnessRequest.approve(id: "a1", answers: [true])), as: UTF8.self)
        let many = String(decoding: HarnessWire.encode(HarnessRequest.approve(id: "a7", answers: [false, true])), as: UTF8.self)
        expectTrue(one.contains(#""allow":true"#) && many.contains(#""allow":[false,true]"#))
        // Privacy & safety answers a batch only when it would answer every action in it.
        let apps = [URL(fileURLWithPath: "/System/Applications/System Settings.app"), URL(fileURLWithPath: "/Applications/Safari.app")]
        let open = { (name: String, data: [String]) in HarnessAction(tool: "open", effect: "outbound", preview: "open {\"name\":\"\(name)\"}", reason: "", fromData: data) }
        expectTrue(CookieOpen.answersForYou(HarnessApproval(id: "b", actions: [open("settings", []), open("safari", [])]), mode: .apps, always: [], apps: apps))
        expectFalse(CookieOpen.answersForYou(HarnessApproval(id: "b", actions: [open("settings", []), open("safari", ["name = safari"])]), mode: .all, always: [], apps: apps))
    }

    func testOperatingTheMacKeepsItsRules() {
        // Keys: shortcuts parse, unknown keys don't; ⌘↩ and ⌘⌫ count as risky.
        expectTrue(MacKeys.parse("cmd+shift+s")?.flags == [.maskCommand, .maskShift])
        expectEqual(MacKeys.parse("tab")?.code, CGKeyCode(48))
        expectNil(MacKeys.parse("cmd+banana"))
        expectNil(MacKeys.parse("hyper+s"))
        expectTrue(MacSafety.isRiskyKey("cmd+return") && MacSafety.isRiskyKey("cmd+delete"))
        expectFalse(MacSafety.isRiskyKey("cmd+s"))
        // A press on anything that sends, pays, deletes or publishes is never covered by the task.
        for label in ["Send", "Pay now", "Delete Message", "Place order", "Publish", "Confirm transfer"] { expectTrue(MacSafety.isRisky(label: label)) }
        for label in ["Save", "Bold", "Insert Chart", "Sender"] { expectFalse(MacSafety.isRisky(label: label)) }
        // Scripts: one allowed app, nothing that reaches the shell, macros or other apps.
        let ok = #"tell application "Microsoft Excel" to set value of range "A1" of active sheet to 5"#
        expectNil(MacSafety.vetScript(app: "Microsoft Excel", script: ok))
        expectTrue(MacSafety.vetScript(app: "Terminal", script: #"tell application "Terminal" to do script "ls""#) != nil)
        expectTrue(MacSafety.vetScript(app: "Microsoft Excel", script: #"tell application "Microsoft Excel" to do shell script "rm -rf ~""#) != nil)
        expectTrue(MacSafety.vetScript(app: "Microsoft Word", script: #"tell application "Microsoft Word" to do Visual Basic "Shell(""x"")""#) != nil)
        expectTrue(MacSafety.vetScript(app: "Numbers", script: #"tell application "Numbers" to activate"# + "\n" + #"tell application "Mail" to send"#) != nil)
        expectTrue(MacSafety.vetScript(app: "Keynote", script: #"tell application "System Events" to keystroke "q""#) != nil)
        // Finance and medical apps (by their App Store category) and password managers are never operated.
        expectTrue(MacSafety.blocked(bundleID: "com.example.bank", category: "public.app-category.finance"))
        expectTrue(MacSafety.blocked(bundleID: "com.example.health", category: "public.app-category.medical"))
        expectTrue(MacSafety.blocked(bundleID: "com.1password.1password", category: nil))
        expectFalse(MacSafety.blocked(bundleID: "com.microsoft.Excel", category: "public.app-category.productivity"))
        // The task covers only the apps it named.
        let grant = MacGrant(plan: "Add a total row", apps: ["Microsoft Excel"], started: Date())
        expectTrue(grant.covers(appName: "Microsoft Excel", bundleID: "com.microsoft.Excel"))
        expectTrue(MacGrant(plan: "x", apps: ["Excel"], started: Date()).covers(appName: "Microsoft Excel", bundleID: "com.microsoft.Excel"))
        expectFalse(grant.covers(appName: "Mail", bundleID: "com.apple.mail"))
        // At most 60 actions a minute.
        var rate = MacRateLimit()
        let start = Date()
        for i in 0..<60 { expectTrue(rate.allow(at: start.addingTimeInterval(Double(i) * 0.1))) }
        expectFalse(rate.allow(at: start.addingTimeInterval(7)))
        expectTrue(rate.allow(at: start.addingTimeInterval(61)))
        // Screenshot pixels → CG global: a 2× screenshot of a 1512×982 main display.
        let p = screenshotPointToGlobal(x: 1512, y: 982, pixelWidth: 3024, pixelHeight: 1964,
                                        displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), mainHeight: 982)
        expectEqual(p, CGPoint(x: 756, y: 491))
        // start_task always asks; reading and teaching don't act.
        let tools = Dictionary(uniqueKeysWithValues: MacOperator.tools.map { ($0.name, $0.effect) })
        expectEqual(tools["start_task"], "outbound")
        expectEqual(tools["look"], "read")
        expectEqual(tools["point_at"], "read")
        expectEqual(tools["press"], "write")
        // No approved task: nothing is covered.
        expectFalse(MacOperator.shared.taskCovers(HarnessApproval(id: "a", tool: "press", effect: "write", preview: #"press {"id":"3"}"#, reason: "")))
        // Tool-call arguments keep their JSON types.
        let call = HarnessWire.decode(Data(#"{"type":"tool_call","run":"r","id":"t1","name":"click_at","args":{"x":120.5,"y":80,"path":["File","Save"]}}"#.utf8))!
        expectEqual(call.args?["x"] as? Double, 120.5)
        expectEqual(call.args?["path"] as? [String], ["File", "Save"])
    }

    func testEveryRunBringsTheBundledServers() {
        let bundle = URL(fileURLWithPath: "/Applications/Cookie.app")
        let home = URL(fileURLWithPath: "/Users/ana")
        let both = CookieServers.all(bundle: bundle, home: home, exists: { _ in true })
        expectEqual(both.map(\.command), ["/Applications/Cookie.app/Contents/Helpers/cookie-tools",
                                           "/Applications/Cookie.app/Contents/Resources/python/bin/python3"])
        expectEqual(Array(both[1].args.prefix(3)), ["-I", "-B", "/Applications/Cookie.app/Contents/Resources/cookie-py/server.py"])
        expectTrue(both[0].args == ["--root", "/Users/ana/Desktop", "--root", "/Users/ana/Documents", "--root", "/Users/ana/Downloads"])
        // An address found in content is put to the person; making files is a write.
        expectEqual(both[1].guards["fetch_page"], ["url"])
        expectEqual(both[1].effects["make_deck"], "write")
        expectEqual(both[0].effects["read_spreadsheet"], "read")
        // A build without the Python bundle leaves cookie-py out entirely.
        expectEqual(CookieServers.all(bundle: bundle, home: home, exists: { !$0.contains("python") }).count, 1)
    }

    func testAppApprovalsParkedOnEnkeonReadAsCards() throws {
        let body = #"[{"id":"cap_1","slug":"gmail","workspace":"main","tool":"GMAIL_SEND_EMAIL","class":"outbound","args_digest":"d","status":"pending","result":null,"decided_by":null,"created_at":"2026-10-13T21:00:00Z","expires_at":"2026-10-14T21:00:00Z","agent":null,"channel_id":"","run_task":"","detail":"recipient_email: maya@acme.com\nsubject: Pilot","requested_by":"u1"},{"id":"cap_2","slug":"hubspot","workspace":"main","tool":"HUBSPOT_DELETE_CONTACT","class":"destroy","args_digest":"d","status":"approved","result":null,"decided_by":"u1","created_at":"2026-10-13T20:00:00Z","expires_at":"2026-10-14T20:00:00Z","agent":null,"channel_id":"","run_task":"","detail":null,"requested_by":"u1"}]"#
        let items = try JSONDecoder().decode([GatewayApproval].self, from: Data(body.utf8))
        let pending = items.filter(\.isPending)
        expectEqual(pending.map(\.id), ["cap_1"])
        expectEqual(pending[0].question, "Send with Gmail?")
        expectEqual(pending[0].verb, "Send")
        expectEqual(pending[0].actionName, "Send email")
        expectEqual(items[1].question, "Delete in HubSpot?")
        expectEqual(items[1].verb, "Delete")
        expectEqual(GatewayApproval.decideBody(approve: true), #"{"approve":true}"#)
    }

    func testTheRecorderHelpersLinesBecomeStates() {
        expectEqual(RecorderLine.parse(#"{"state":"recording","meeting_id":"m1","secs":61,"level":0.4}"#), .recording(meeting: "m1", secs: 61, level: 0.4))
        expectEqual(RecorderLine.parse(#"{"state":"mic_only","message":"Screen Recording is off"}"#), .micOnly("Screen Recording is off"))
        expectEqual(RecorderLine.parse(#"{"state":"stopped","meeting_id":"m1"}"#), .stopped(meeting: "m1"))
        expectEqual(RecorderLine.parse(#"{"state":"error","message":"401"}"#), .error("401"))
        expectNil(RecorderLine.parse("not json"))
        // The gateway's meeting: ready with a summary, or still being transcribed.
        expectEqual(MeetingResult.parse(#"{"id":"m1","state":"ready","summary":"Agreed the pilot.","promises":[{"text":"send pricing"}],"duration_secs":1800}"#),
                    .ready(summary: "Agreed the pilot.", promises: 1, minutes: 30))
        expectEqual(MeetingResult.parse(#"{"id":"m1","state":"transcribing"}"#), .working)
        expectEqual(MeetingResult.parse(#"{"id":"m1","state":"failed","failure":"nothing was recorded"}"#), .failed("nothing was recorded"))
    }

    func testWorkMovesAndMirrorsToEnkeonPlans() {
        // Each column is a plan's state and owner in Enkeon.
        expectTrue(WorkColumn.needsYou.mirror(to: "Northwind", person: "Alex") == ("held", "Alex"))
        expectTrue(WorkColumn.cookie.mirror(to: "Northwind", person: "Alex") == ("held", "tool:cookie"))
        expectTrue(WorkColumn.waiting.mirror(to: "Northwind", person: "Alex") == ("held", "Northwind"))
        expectTrue(WorkColumn.waiting.mirror(to: "", person: "Alex") == ("held", "them"))
        expectTrue(WorkColumn.done.mirror(to: "Northwind", person: "Alex") == ("kept", "Alex"))
        expectEqual(WorkText.memoryID(in: "Remembered — \"Northwind pilot\" (id 01M4VAZWXNSCY9RK814X7ZSRQY, v1)."), "01M4VAZWXNSCY9RK814X7ZSRQY")
        expectNil(WorkText.memoryID(in: "Nothing saved."))
        // Enkeon may answer as JSON or as an SSE stream.
        expectEqual(EnkeonDirect.body(Data(#"{"result":{"ok":1}}"#.utf8))["result"] != nil, true)
        expectEqual(EnkeonDirect.body(Data("event: message\ndata: {\"result\":{\"ok\":1}}\n\n".utf8))["result"] != nil, true)
        // Near dates the way people say them.
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9))!
        expectEqual(WorkText.due(now, now: now), "Today")
        expectEqual(WorkText.due(now.addingTimeInterval(86_400), now: now), "Tomorrow")
        expectEqual(WorkText.due(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 30))!, now: now), "30 Oct")
        // The store: add, move with history, overdue first. Offline here: nothing touches the Mac or Enkeon.
        let store = WorkStore(connected: false)
        let late = store.add(title: "Contoso renewal", to: "Contoso", due: now.addingTimeInterval(-86_400 * 2))
        let soon = store.add(title: "Northwind pilot", nextStep: "Review the draft", to: "Northwind", due: now.addingTimeInterval(86_400 * 3))
        store.move(soon.id, to: .waiting)
        expectEqual(store.items(in: .needsYou).map(\.title), ["Contoso renewal"])
        expectEqual(store.item(soon.id)?.history.map(\.text), ["Started", "Moved to Waiting"])
        store.move(soon.id, to: .needsYou)
        expectEqual(store.items(in: .needsYou).first?.id, late.id)
        expectTrue(store.item(late.id)!.isOverdue())
        store.remove(late.id)
        expectEqual(store.items.count, 1)
        expectEqual(WorkStore.planText(store.item(soon.id)!), "Work: Northwind pilot. It concerns Northwind. Next step: Review the draft.")
    }

    func testListsImportCSVAndStartWork() {
        // Quotes, doubled quotes, a comma and a line break inside a field, a BOM and CRLF.
        let csv = "\u{FEFF}Company,Website,Why they fit,Employees\r\n" +
            "Northwind,northwind.example,\"Fleet software, Riga\",120\r\n" +
            "\"Globex \"\"Pro\"\"\",globex.example,\"Two\nlines\",\r\n" +
            ",nobody.com,no name,\r\n"
        let rows = try! ListCSV.rows(from: csv)
        expectEqual(rows.map(\.company), ["Northwind", "Globex \"Pro\""])
        expectEqual(rows[0].note, "Fleet software, Riga")
        expectEqual(rows[0].extra, ["Employees": "120"])
        expectEqual(rows[1].note, "Two\nlines")
        // Semicolon files from European spreadsheets.
        expectEqual(try! ListCSV.rows(from: "Name;Domain\nInitech;initech.example\n").first?.website, "initech.example")
        expectTrue((try? ListCSV.rows(from: "Website\nnorthwind.example\n")) == nil)
        expectTrue((try? ListCSV.rows(from: "Company\n")) == nil)
        // Starting work: one item per row, linked; a row already in work is left alone.
        let work = WorkStore(connected: false)
        let lists = ListStore(connected: false)
        let list = lists.create(name: "ICP", rows: rows)
        let ids = Set(list.rows.map(\.id))
        let made = lists.startWork(list.id, rows: ids, action: .research, in: work)
        expectEqual(made.count, 2)
        expectEqual(made.first?.to, "Northwind")
        expectEqual(made.first?.title, "Northwind: research")
        expectEqual(made.first?.nextStep, "Research Northwind (northwind.example): who to talk to and why they'd care")
        expectEqual(lists.list(list.id)?.rows.first?.workID, made.first?.id)
        expectEqual(lists.startWork(list.id, rows: ids, action: .intro, in: work).count, 0)
        // Removed work frees the row again.
        work.remove(made[0].id)
        expectEqual(lists.startWork(list.id, rows: ids, action: .intro, in: work).map(\.title), ["Northwind: draft an intro"])
    }

    func testThePeeksThreeRows() {
        let now = Date() // Work notes stamp the real clock, so the chat reply must be newer than that.
        let work = WorkStore(connected: false)
        let pilot = work.add(title: "Northwind team pilot", nextStep: "Send the proposal", to: "Northwind", due: now.addingTimeInterval(-86_400))
        work.update(pilot.id, by: "cookie", note: "Drafted the proposal") { _ in }
        // Latest: the newest of Cookie's work notes and chat replies; never a chat while chats are locked.
        let reply = CookieThread(id: UUID(), messages: [CompanionChatMessage(role: .user, text: "hi", date: now),
                                                        CompanionChatMessage(role: .assistant, text: "Hello there\nmore", date: now.addingTimeInterval(60))],
                                 updatedAt: now)
        expectEqual(PeekLines.latest(threads: [reply], work: work.items, meetingNotes: nil, chatsLocked: false, now: now.addingTimeInterval(120)).title, "Hello there")
        expectEqual(PeekLines.latest(threads: [reply], work: work.items, meetingNotes: nil, chatsLocked: true).title, "Drafted the proposal")
        expectEqual(PeekLines.latest(threads: [], work: [], meetingNotes: .init(minutes: 30, promises: 2), chatsLocked: false).detail, "30 min · 2 promises")
        // Now: an approval beats work in progress; idle shows counts.
        expectEqual(PeekLines.now(working: true, step: "Reading", threadTitle: "x", approval: "Send it?", work: []).action, .review)
        expectEqual(PeekLines.now(working: true, step: "Reading", threadTitle: "x", approval: nil, work: []).action, .stop)
        expectEqual(PeekLines.now(working: false, step: nil, threadTitle: nil, approval: nil, work: work.items).detail, "1 needs you")
        expectEqual(PeekLines.now(working: false, step: nil, threadTitle: nil, approval: nil, work: []).title, "Ready when you are")
        // Up next: the meeting's work wins, then Enkeon's line, then the attendees; with no meeting, urgent work.
        let meeting = UpcomingMeeting(id: "m", title: "Northwind sync", start: now.addingTimeInterval(12 * 60), end: now.addingTimeInterval(3600), attendees: ["Anna"])
        expectEqual(PeekLines.upNext(access: .allowed, meeting: meeting, recalled: nil, work: work.items, now: now).title, "Northwind sync · in 12 min")
        expectEqual(PeekLines.upNext(access: .allowed, meeting: meeting, recalled: nil, work: work.items, now: now).action, .openWork(pilot.id))
        let other = UpcomingMeeting(id: "o", title: "Investor chat", start: now.addingTimeInterval(7200), end: now.addingTimeInterval(9000), attendees: ["Erik"])
        expectEqual(PeekLines.upNext(access: .allowed, meeting: other, recalled: "They asked for MRR.", work: work.items, now: now).detail, "They asked for MRR.")
        expectEqual(PeekLines.upNext(access: .allowed, meeting: other, recalled: nil, work: [], now: now).detail, "With Erik")
        expectEqual(PeekLines.upNext(access: .allowed, meeting: nil, recalled: nil, work: work.items, now: now).action, .openWork(pilot.id))
        expectEqual(PeekLines.upNext(access: .notAsked, meeting: nil, recalled: nil, work: [], now: now).action, .connectCalendar)
        // Which meeting is next: skipped ones and long-running ones are passed over.
        let soon = UpcomingMeeting(id: "a", title: "A", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1800), attendees: [])
        let running = UpcomingMeeting(id: "b", title: "B", start: now.addingTimeInterval(-300), end: now.addingTimeInterval(1500), attendees: [])
        let stale = UpcomingMeeting(id: "c", title: "C", start: now.addingTimeInterval(-3000), end: now.addingTimeInterval(600), attendees: [])
        let declined = UpcomingMeeting(id: "d", title: "D", start: now.addingTimeInterval(60), end: now.addingTimeInterval(900), attendees: [])
        expectEqual(CookieCalendar.pick([(soon, false), (running, false), (stale, false), (declined, true)], now: now)?.id, "b")
        expectEqual(UpNextText.when(now.addingTimeInterval(-30), now: now), "now")
        // Enkeon's answer: a JSON object, then notes; the first statement's first sentence.
        let answer = #"{"hits":[{"id":"x","statement":"Decision: Plus at €59 {draft}. Why: Pro is too small."}],"reading":{}}── Decisions ──"#
        expectEqual(CookieCalendar.firstStatement(in: answer), "Decision: Plus at \u{20AC}59 {draft}.")
        expectNil(CookieCalendar.firstStatement(in: #"{"hits":[]}"#))
    }

    func testScreenCaptureGivesUpAtItsDeadline() async {
        let started = Date()
        let hung: Int? = await withDeadline(seconds: 0.2) {
            try await Task.sleep(for: .seconds(30))
            return 1
        }
        expectNil(hung)
        expectTrue(Date().timeIntervalSince(started) < 2)
        let quick: Int? = await withDeadline(seconds: 5) { 7 }
        expectEqual(quick, 7)
    }

    func renderComposerStates() {
        let content = VStack(alignment: .leading, spacing: 24) {
            composerPreview("READY", width: 640)
            composerPreview("TYPING", width: 640, text: "Can you help me simplify this screen?")
            composerPreview("ATTACHMENT + MULTILINE", width: 640, text: "Use this as a reference.\nKeep the navigation clear and simple.", attachment: true)
            composerPreview("LISTENING", width: 640, voiceState: .listening)
            composerPreview("THINKING", width: 640, voiceState: .processing)
            composerPreview("SPEAKING", width: 640, voiceState: .responding)
            composerPreview("COMPACT", width: 336, text: "A little more space to think.")
            ApprovalCard(action: HarnessApproval(id: "a1", tool: "open", effect: "outbound",
                                                   preview: #"open {"name":"settings"}"#, reason: "").actions[0]) { _ in }
                .frame(width: 640)
            ApprovalCard(action: HarnessApproval(id: "a2", tool: "open", effect: "outbound",
                                                   preview: #"open {"name":"enkeon.com"}"#, reason: "").actions[0]) { _ in }
                .frame(width: 640)
            ApprovalCard(action: HarnessApproval(id: "a3", tool: "send_email", effect: "outbound",
                                                   preview: #"send_email {"to":"ana@acme.com","subject":"Re: pilot"}"#, reason: "").actions[0]) { _ in }
                .frame(width: 640)
            ApprovalCard(action: HarnessApproval(id: "a4", tool: "pay", effect: "destroy",
                                                   preview: #"pay {"to":"US122000000121212121212","amount":19.5}"#, reason: "",
                                                   fromData: ["to = US122000000121212121212"]).actions[0]) { _ in }
                .frame(width: 640)
            BatchApprovalCard(approval: HarnessApproval(id: "b1", actions: [
                HarnessAction(tool: "send_email", effect: "outbound", preview: #"send_email {"to":"maya@acme.com","subject":"Pilot update"}"#, reason: ""),
                HarnessAction(tool: "send_email", effect: "outbound", preview: #"send_email {"to":"jon@acme.com","subject":"Pilot update"}"#, reason: ""),
                HarnessAction(tool: "send_email", effect: "outbound", preview: #"send_email {"to":"billing@acme-pay.co","subject":"Invoice"}"#, reason: "",
                              fromData: ["to = billing@acme-pay.co"]),
            ])) { _ in }
                .frame(width: 640)
        }
        .padding(28)
        .background(CK.island)
        .environment(\.colorScheme, .dark)
        .symbolEffectsRemoved()
        // AppKit-backed text fields and scroll views need a native hosting
        // snapshot; ImageRenderer substitutes placeholders for these controls.
        _ = NSApplication.shared
        let hostingView = NSHostingView(rootView: content)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: hostingView.fittingSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            preconditionFailure("Composer render failed")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/cookie-composer-preview.png")
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output)
        window.close()
        print("Rendered build/cookie-composer-preview.png")
    }

    private func composerPreview(_ title: String, width: CGFloat, text: String = "", attachment: Bool = false,
                                 voiceState: CompanionVoiceState = .idle) -> some View {
        let draft = CookieChatDraft()
        draft.text = text
        if attachment { draft.attach(CookieAttachment(path: "/tmp/Design notes.pdf")) }
        return VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(CK.tertiary)
            CookieComposerControl(draft: draft, availableWidth: width, voiceState: voiceState,
                                  isWorking: voiceState == .processing, audioLevel: 0.85,
                                  startTalking: {}, finishTalking: {}, stopResponse: {}, sendMessage: { _, _, _ in })
                .frame(width: width)
        }
    }
}

@main
@MainActor
struct CookieInteractionCheckRunner {
    static func main() {
        setbuf(stdout, nil)
        let checks = CookieInteractionTests()
        checks.testPassingAcrossNotchDoesNotOpenItLater()
        print("PASS testPassingAcrossNotchDoesNotOpenItLater")
        checks.testSmallPointerMovementsDoNotRestartHoverDelay()
        print("PASS testSmallPointerMovementsDoNotRestartHoverDelay")
        checks.testReenteringPeekCancelsPendingClose()
        print("PASS testReenteringPeekCancelsPendingClose")
        checks.testLeavingPeekClosesAfterGracePeriod()
        print("PASS testLeavingPeekClosesAfterGracePeriod")
        checks.testClickingHomeOrDisablingHoverCancelsPendingOpen()
        print("PASS testClickingHomeOrDisablingHoverCancelsPendingOpen")
        checks.testEveryIslandStateFitsTheAvailableDisplay()
        print("PASS testEveryIslandStateFitsTheAvailableDisplay")
        checks.testStandardDisplayKeepsExistingIslandDimensions()
        print("PASS testStandardDisplayKeepsExistingIslandDimensions")
        checks.testPreviewNeverSqueezesTheConversationBelowItsMinimum()
        print("PASS testPreviewNeverSqueezesTheConversationBelowItsMinimum")
        checks.testDraftSurvivesViewRecreationAndIsIsolatedByChat()
        print("PASS testDraftSurvivesViewRecreationAndIsIsolatedByChat")
        checks.testNewChatDraftFollowsTheThreadCreatedByVoiceOrSend()
        print("PASS testNewChatDraftFollowsTheThreadCreatedByVoiceOrSend")
        checks.testDeletingChatsClearsDraftsAndDetachesLateFileLoads()
        print("PASS testDeletingChatsClearsDraftsAndDetachesLateFileLoads")
        checks.testOutgoingContentAndBlurStayInsideEveryIntermediateSilhouette()
        print("PASS testOutgoingContentAndBlurStayInsideEveryIntermediateSilhouette")
        checks.testComposerCannotSendOverRecordingOrAnActiveReply()
        print("PASS testComposerCannotSendOverRecordingOrAnActiveReply")
        checks.testComposerStopBelongsOnlyToAReply()
        print("PASS testComposerStopBelongsOnlyToAReply")
        checks.testCookieLooksOnlyWhenThePersonAsks()
        print("PASS testCookieLooksOnlyWhenThePersonAsks")
        checks.testSpeakerPicksTheBestVoiceItCanActuallyUse()
        print("PASS testSpeakerPicksTheBestVoiceItCanActuallyUse")
        checks.testOpenFindsWhatThePersonNamed()
        print("PASS testOpenFindsWhatThePersonNamed")
        checks.testOpeningWithoutAskingFollowsTheSetting()
        print("PASS testOpeningWithoutAskingFollowsTheSetting")
        checks.testEarlierTurnsKeepWhoWroteThem()
        print("PASS testEarlierTurnsKeepWhoWroteThem")
        checks.testSignInPiecesFollowTheStandards()
        print("PASS testSignInPiecesFollowTheStandards")
        checks.testMacNotificationsOnlyWhenYouAreAway()
        print("PASS testMacNotificationsOnlyWhenYouAreAway")
        checks.testAValueFromDataIsShownAndNeverAnsweredForYou()
        print("PASS testAValueFromDataIsShownAndNeverAnsweredForYou")
        checks.testOneCardForEveryActionOfATurn()
        print("PASS testOneCardForEveryActionOfATurn")
        checks.testOperatingTheMacKeepsItsRules()
        print("PASS testOperatingTheMacKeepsItsRules")
        checks.testEveryRunBringsTheBundledServers()
        print("PASS testEveryRunBringsTheBundledServers")
        try! checks.testAppApprovalsParkedOnEnkeonReadAsCards()
        print("PASS testAppApprovalsParkedOnEnkeonReadAsCards")
        checks.testTheRecorderHelpersLinesBecomeStates()
        print("PASS testTheRecorderHelpersLinesBecomeStates")
        checks.testWorkMovesAndMirrorsToEnkeonPlans()
        print("PASS testWorkMovesAndMirrorsToEnkeonPlans")
        checks.testListsImportCSVAndStartWork()
        print("PASS testListsImportCSVAndStartWork")
        checks.testThePeeksThreeRows()
        print("PASS testThePeeksThreeRows")
        CookieWorkPresentationTests.run()
        CookiePeekPresentationTests.run()
        CookieFeatureTests.run()
        CookieDockPresentationTests.run()
        CookiePermissionTests.run()
        var setupChecksFinished = false
        Task { @MainActor in
            await checks.testScreenCaptureGivesUpAtItsDeadline()
            print("PASS testScreenCaptureGivesUpAtItsDeadline")
            print("31 interaction checks passed.")
            await CookieSetupTests.run()
            await CookieVoiceFlowTests.run()
            await CookieCreationTests.run()
            setupChecksFinished = true
        }
        let deadline = Date().addingTimeInterval(30)
        while !setupChecksFinished && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(setupChecksFinished, "Setup checks did not finish")
        if CommandLine.arguments.contains("--render") {
            checks.renderComposerStates()
            CookieNavigationPreview.render()
            CookiePeekPresentationTests.render()
            CookieNavigationPreview.renderWork()
            CookieSetupTests.render()
            CookieDockPresentationTests.render()
        }
    }
}

private func expectTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(value, "Expected true", file: file, line: line)
}
private func expectFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(!value, "Expected false", file: file, line: line)
}
private func expectNil<Value>(_ value: Value?, file: StaticString = #file, line: UInt = #line) {
    precondition(value == nil, "Expected nil", file: file, line: line)
}
private func expectEqual<Value: Equatable>(_ actual: Value, _ expected: Value, file: StaticString = #file, line: UInt = #line) {
    precondition(actual == expected, "Expected \(expected), got \(actual)", file: file, line: line)
}
private func expectAtMost<Value: Comparable>(_ actual: Value, _ maximum: Value, file: StaticString = #file, line: UInt = #line) {
    precondition(actual <= maximum, "Exceeded maximum", file: file, line: line)
}
private func expectAtLeast<Value: Comparable>(_ actual: Value, _ minimum: Value, file: StaticString = #file, line: UInt = #line) {
    precondition(actual >= minimum, "Below minimum", file: file, line: line)
}
private func expectGreater<Value: Comparable>(_ actual: Value, _ minimum: Value, file: StaticString = #file, line: UInt = #line) {
    precondition(actual > minimum, "Must exceed minimum", file: file, line: line)
}
