import AppKit

enum CookieWeeklyCardTests {
    static func run() {
        precondition(CookieWeeklyCardPresentation.isCompact(availableHeight: 580), "the 928×580 console uses the compact row")
        precondition(CookieWeeklyCardPresentation.compactHeight < CookieWeeklyCardPresentation.expandedHeight)
        precondition(!CookieWeeklyCardPresentation.isCompact(availableHeight: 700))
        print("3 weekly card layout checks passed.")
    }
}
