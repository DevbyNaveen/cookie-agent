import AppKit

/// The pure parts of a fast, correct turn: timing, streaming speech, pictures, the pointer.
@MainActor
enum CookieSpeedTests {
    static func run() {
        var passed = 0
        func check(_ name: String, _ body: () -> Void) {
            body()
            passed += 1
            print("PASS \(name)")
        }
        check("aTurnLogsEveryStageItReachedAndNothingElse", aTurnLogsEveryStageItReachedAndNothingElse)
        print("\(passed) speed checks passed.")
    }

    static func aTurnLogsEveryStageItReachedAndNothingElse() {
        var timing = CookieTurnTiming()
        timing.mark(.keyDown, at: 10)
        timing.mark(.release, at: 12.4)
        timing.mark(.release, at: 99) // marked once: the first time wins
        timing.mark(.transcript, at: 12.58)
        timing.notes = ["voice", "1 screen"]
        timing.redactionSeconds = 0.09
        timing.mark(.capture, at: 12.71)
        timing.mark(.requestSent, at: 12.75)
        timing.toolStarted(at: 13.0)
        timing.closeToolRound(at: 14.5)
        timing.mark(.firstToken, at: 13.9)
        timing.mark(.done, at: 20.4)
        let line = timing.line()
        precondition(line == "⏱ turn voice 1 screen · held 2.40 s · transcript +0.18 · capture +0.31 (redaction 0.09) · sent +0.35 · first token +1.50 · done +8.00 · tools 1 (1.50 s)", line)
        precondition(CookieTurnTiming().line() == "⏱ turn: no start")
    }
}
