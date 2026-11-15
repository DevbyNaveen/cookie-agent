import Foundation
import EnkeonVoiceKit

@MainActor
enum CookieDecisionRecallTests {
    static func run() {
        precondition(CookieDecisionRecall.requested("What would I decide here?"))
        precondition(CookieDecisionRecall.requested("What did I decide about launch timing?"))
        precondition(!CookieDecisionRecall.requested("What should I write to Priya?"))
        precondition(CookieDecisionRecall.formatted(#"{"hits":[]}"#) == "No past decision on this.")
        let hit = #"{"hits":[{"statement":"Keep the API read-only.","valid_from":1794688991,"source_uri":"mcp://agent/abc/01M7DWSG7J795RYAZASQC3ZH32","state":"held"}]}"#
        let result = CookieDecisionRecall.formatted(hit)
        precondition(result.contains("Keep the API read-only.") && result.contains("2026") && result.contains("mcp://agent/abc/"))
        let stale = #"{"hits":[{"statement":"Use the old API.","valid_from":1794688991,"source_uri":"mcp://agent/abc/old","state":"held","may_be_outdated":"newer"}]}"#
        precondition(CookieDecisionRecall.formatted(stale) == "No past decision on this.")
        print("5 decision recall checks passed.")
    }
}
