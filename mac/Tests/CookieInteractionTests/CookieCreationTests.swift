import Foundation

@MainActor
enum CookieCreationTests {
    static func run() async {
        await speakingFollowsPlaybackAndIgnoresLateCallbacks()
        await cancelledCreationCannotReplaceANewerIdea()
        await failuresKeepTheAnswerForRetry()
        draftsSurviveFoldingAndClearAfterCreation()
        spokenWordsKeepUnicodeIntact()
        print("5 Cookie creation checks passed.")
    }

    private static func speakingFollowsPlaybackAndIgnoresLateCallbacks() async {
        let session = CookieCreationSession()
        var started: (() -> Void)?
        var progress: ((Double) -> Void)?
        var completion: CheckedContinuation<Void, Never>?
        session.greet { _, onStarted, onProgress in
            started = onStarted
            progress = onProgress
            await withCheckedContinuation { completion = $0 }
        }
        await waitUntil { completion != nil }
        precondition(session.preparingSpeech && session.phase == .ready && session.speechProgress == 1)
        started?()
        precondition(!session.preparingSpeech && session.phase == .speaking && session.speechProgress == 0)
        progress?(0.4)
        progress?(0.2)
        precondition(session.speechProgress == 0.4)
        session.typed = "Keep this typed idea"
        session.stop()
        progress?(0.9)
        started?()
        completion?.resume()
        await Task.yield()
        precondition(session.phase == .ready && session.speechProgress == 1 && session.typed == "Keep this typed idea")
    }

    private static func cancelledCreationCannotReplaceANewerIdea() async {
        let session = CookieCreationSession()
        var first: CheckedContinuation<(say: String, agent: CookieAgent?), Never>?
        var second: CheckedContinuation<(say: String, agent: CookieAgent?), Never>?
        var speechCount = 0
        let speech: CookieCreationSession.Speech = { _, _, _ in speechCount += 1 }
        session.answer("Old idea", conversation: { _, _, _ in await withCheckedContinuation { first = $0 } }, speech: speech)
        await waitUntil { first != nil }
        session.stop()
        session.answer("New idea", conversation: { _, _, _ in await withCheckedContinuation { second = $0 } }, speech: speech)
        await waitUntil { second != nil }
        first?.resume(returning: ("Old response", CookieAgent(name: "Old", role: "", detail: "", kind: .general)))
        await Task.yield()
        precondition(session.draft == nil && session.phase == .thinking && speechCount == 0)
        second?.resume(returning: ("New response", CookieAgent(name: "New", role: "", detail: "", kind: .research)))
        await waitUntil { session.draft != nil }
        precondition(session.draft?.name == "New" && session.lastAnswer == "New idea" && speechCount == 1)
    }

    private static func failuresKeepTheAnswerForRetry() async {
        let session = CookieCreationSession()
        session.answer("  Research my market  ", conversation: { _, _, _ in throw URLError(.notConnectedToInternet) },
                       speech: { _, _, _ in preconditionFailure("Failed requests must not speak") })
        await waitUntil { session.problem != nil }
        precondition(session.typed == "Research my market" && session.phase == .ready)
        precondition(!session.answer("   ", conversation: { _, _, _ in preconditionFailure() }, speech: { _, _, _ in }))
    }

    private static func draftsSurviveFoldingAndClearAfterCreation() {
        let navigation = CookieNavigation()
        let session = navigation.agentCreation
        precondition(session.prepare(page: .new, profile: nil))
        let identity = session.identity
        session.typed = "An idea I haven't sent"
        session.stop()
        precondition(!session.prepare(page: .new, profile: nil))
        precondition(session.identity == identity && session.typed == "An idea I haven't sent")
        session.finish()
        precondition(session.prepare(page: .new, profile: nil))
        precondition(session.typed.isEmpty && session.identity != identity)
    }

    private static func spokenWordsKeepUnicodeIntact() {
        let line = "Hello 👩🏽‍💻 café — let’s make it yours."
        for fraction in stride(from: 0.0, through: 1.0, by: 0.01) {
            let parts = CookieSpokenText.parts(line, progress: fraction)
            precondition(parts.spoken + parts.upcoming == line)
            if !parts.spoken.isEmpty && !parts.upcoming.isEmpty { precondition(parts.upcoming.first!.isWhitespace) }
        }
        precondition(CookieSpokenText.parts(line, progress: .nan).spoken.isEmpty)
        precondition(CookieSpokenText.parts(line, progress: 1).spoken == line)
        precondition(CookieSpokenText.parts("", progress: 0.5).spoken.isEmpty)
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Creation did not reach its expected state")
    }
}
