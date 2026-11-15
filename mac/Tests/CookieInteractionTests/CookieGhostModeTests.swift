import Foundation

@MainActor
enum CookieGhostModeTests {
    static func run() {
        precondition(CookieAXActionPolicy.permitsBackgroundAction(targetPID: 8, frontmostPID: 9, approved: true, observedElementCount: 1))
        precondition(!CookieAXActionPolicy.permitsBackgroundAction(targetPID: 9, frontmostPID: 9, approved: true, observedElementCount: 1))
        precondition(!CookieAXActionPolicy.permitsBackgroundAction(targetPID: 8, frontmostPID: 9, approved: false, observedElementCount: 1))
        precondition(!CookieAXActionPolicy.permitsBackgroundAction(targetPID: 8, frontmostPID: 9, approved: true, observedElementCount: 0))
        precondition(CookieAXActionPolicy.screenQuestion(seconds: 8) == "Can I take the screen for ~8 seconds?")
        precondition(!CookieAXActionPolicy.canTakeScreen(isApproved: false))
        precondition(CookieAXActionPolicy.canTakeScreen(isApproved: true))
        precondition(CookieAXActionPolicy.screenDuration(90) == 15)
        precondition(CookieAXActionPolicy.screenDuration(0) == 1)
        print("9 Ghost Mode safety checks passed.")
    }
}
