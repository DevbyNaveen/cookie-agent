import Foundation

/// Proof marks on recalled memories: Enkeon's `proof.state` read honestly (absent → no mark,
/// unknown → unchecked), a check shown only when every line was checked, and "source changed"
/// carried into the meeting brief and decision lines.
@MainActor
enum CookieRecallProofTests {
    static func run() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        func hit(_ state: String?) -> [String: Any] {
            var hit: [String: Any] = ["id": "01JABCDEFGHJKMNPQRSTVWXYZ", "statement": "Anna owns the Riga launch.", "valid_from": 1_761_350_400]
            if let state { hit["proof"] = ["state": state, "checked_at": "2026-11-17T09:00:00Z"] }
            return hit
        }

        // Parsing.
        check(CookieRecallProof.of(hit("source_matched")) == .sourceMatched, "source_matched")
        check(CookieRecallProof.of(hit("saved_intact")) == .savedIntact, "saved_intact")
        check(CookieRecallProof.of(hit("source_changed")) == .sourceChanged, "source_changed")
        check(CookieRecallProof.of(hit("unchecked")) == .unchecked, "unchecked")
        check(CookieRecallProof.of(hit("verified_by_magic")) == .unchecked, "unknown state counts as unchecked")
        check(CookieRecallProof.of(hit(nil)) == nil, "older engines: no proof, no mark")
        check(CookieRecallProof.of(["proof": ["reason": "x"]]) == .unchecked, "proof without a state is unchecked")

        // Marks: a symbol for each check, none for unchecked.
        check(CookieRecallProof.sourceMatched.symbol == "checkmark.seal", "matched seal")
        check(CookieRecallProof.savedIntact.symbol == "lock.doc", "intact lock")
        check(CookieRecallProof.sourceChanged.symbol == "exclamationmark.triangle", "changed triangle")
        check(CookieRecallProof.unchecked.symbol == nil && CookieRecallProof.unchecked.explanation == nil, "never a check for unchecked")

        // Wording says exactly what was checked.
        check(CookieRecallProof.sourceMatched.explanation?.contains("re-read the source") == true, "matched wording")
        check(CookieRecallProof.savedIntact.explanation?.contains("no source to re-read") == true, "intact wording")
        check(CookieRecallProof.sourceChanged.explanation?.contains("may be out of date") == true, "changed wording")

        // Combining lines: a check never covers a line it didn't check.
        check(CookieRecallProof.combined([.sourceMatched, .sourceMatched]) == .sourceMatched, "all matched")
        check(CookieRecallProof.combined([.sourceMatched, .savedIntact]) == .savedIntact, "weaker check wins")
        check(CookieRecallProof.combined([.sourceMatched, nil]) == nil, "a proof-less line drops the mark")
        check(CookieRecallProof.combined([.sourceMatched, .unchecked]) == nil, "an unchecked line drops the mark")
        check(CookieRecallProof.combined([.unchecked, .sourceChanged]) == .sourceChanged, "a changed source always shows")
        check(CookieRecallProof.combined([]) == nil, "no lines, no mark")

        // Wired into the hover card the real recall answer builds.
        func answer(_ hits: [[String: Any]]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: ["hits": hits, "match_quality": "strong"]), encoding: .utf8)! + "\nnotes"
        }
        let anna = CookieEntity(kind: .person, text: "Anna")
        check(CookieMemoryCard.parse(answer([hit("source_matched")]), about: anna)?.proof == .sourceMatched, "card carries the check")
        check(CookieMemoryCard.parse(answer([hit(nil)]), about: anna)?.proof == nil, "card without proof shows no mark")
        check(CookieMemoryCard.parse(answer([hit("unchecked")]), about: anna)?.proof == nil, "unchecked card shows no mark")

        // Meeting brief prep and decision lines say when the source changed, and only then.
        check(CookieCalendar.firstStatement(in: answer([hit("source_changed")])) == "Anna owns the Riga launch. · source changed", "brief changed")
        check(CookieCalendar.firstStatement(in: answer([hit("source_matched")])) == "Anna owns the Riga launch.", "brief unchanged")
        let decision = CookieDecisionRecall.formatted(answer([hit("source_changed")]))
        check(decision.hasSuffix(" · source changed"), decision)
        check(!CookieDecisionRecall.formatted(answer([hit("unchecked")])).contains("source changed"), "decision unchanged")

        print("\(checks) recall proof checks passed.")
    }
}
