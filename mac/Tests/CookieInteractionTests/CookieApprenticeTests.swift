import Foundation
import Carbon.HIToolbox

@MainActor
enum CookieApprenticeTests {
    static func run() {
        let suite = "cookie-apprentice-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let off = CookieApprentice(defaults: defaults, store: CookieApprenticeStore(file: nil), proof: CookieProof(file: nil))
        precondition(!off.isEnabled, "noticing is off by default")

        defaults.set(true, forKey: CookieApprentice.enabledKey)
        let now = Date()
        let store = CookieApprenticeStore(file: nil, now: now)
        let proof = CookieProof(file: nil)
        let apprentice = CookieApprentice(defaults: defaults, store: store, proof: proof)
        if case .typed = CookieApprentice.classifyKey(flags: .maskShift, keyCode: CGKeyCode(kVK_ANSI_A)) {} else {
            preconditionFailure("shifted letters remain typed placeholders, not captured key combinations")
        }
        if case .key = CookieApprentice.classifyKey(flags: .maskCommand, keyCode: CGKeyCode(kVK_ANSI_V)) {} else {
            preconditionFailure("command shortcuts are captured structurally")
        }
        let press = CookieApprentice.ObservedEvent(bundleID: "com.example.editor", kind: .press(role: "AXButton", label: "Export"),
                                                   secureInput: false, blocked: false, date: now)
        apprentice.handleObserved(press)
        let typing = CookieApprentice.ObservedEvent(bundleID: "com.example.editor", kind: .typed,
                                                    secureInput: false, blocked: false, date: now.addingTimeInterval(1))
        apprentice.handleObserved(typing)
        precondition(apprentice.localSteps.count == 2)
        if case .press(let role, let label) = apprentice.localSteps[0].action {
            precondition(role == "AXButton" && label == "Export")
        } else { preconditionFailure("the event handler stores the pressed control structure") }
        precondition(apprentice.localSteps[1].action == .typed, "ordinary typing is one placeholder, never text")
        let encoded = try! JSONEncoder().encode(apprentice.localSteps)
        precondition(String(decoding: encoded, as: UTF8.self).contains("typed"))
        precondition(!String(decoding: encoded, as: UTF8.self).contains("password contents"))

        let beforeBlockedInput = apprentice.localSteps.count
        apprentice.handleObserved(CookieApprentice.ObservedEvent(bundleID: "com.example.editor", kind: .typed,
            secureInput: true, blocked: false, date: now.addingTimeInterval(2)))
        apprentice.handleObserved(CookieApprentice.ObservedEvent(bundleID: "com.1password.1password", kind: .typed,
            secureInput: false, blocked: true, date: now.addingTimeInterval(3)))
        precondition(apprentice.localSteps.count == beforeBlockedInput, "secure input and blocked apps are skipped")

        let threeSteps = ["Export", "PDF", "Mail"].map { CookieApprenticeStep(date: now, appBundleID: "com.example.editor", action: .press(role: "AXButton", label: $0)) }
        var sessions: [CookieApprenticeStep] = []
        for index in 0..<3 {
            sessions += threeSteps.enumerated().map { offset, step in
                CookieApprenticeStep(date: now.addingTimeInterval(Double(index) * 304 + Double(offset)),
                                     appBundleID: step.appBundleID, action: step.action)
            }
        }
        let repeated = CookieApprentice.repeats(in: sessions, minLength: 3, minCount: 3)
        precondition(repeated.first?.title == "Export → PDF → Mail" && repeated.first?.sessions == 3)
        let sameSession = (0..<3).flatMap { index in
            threeSteps.enumerated().map { offset, step in
                CookieApprenticeStep(date: now.addingTimeInterval(Double(index * 3 + offset)),
                                     appBundleID: step.appBundleID, action: step.action)
            }
        }
        precondition(CookieApprentice.repeats(in: sameSession, minLength: 3, minCount: 3).isEmpty,
                     "repetitions in one session do not masquerade as three sessions")

        let offerStore = CookieApprenticeStore(file: nil, now: now)
        let offerApprentice = CookieApprentice(defaults: defaults, store: offerStore, proof: CookieProof(file: nil))
        var offers = 0
        offerApprentice.onOffer = { _ in offers += 1 }
        for step in sessions { try! offerStore.append(step, now: step.date) }
        offerApprentice.evaluatePatterns(now: now)
        precondition(offerApprentice.offer?.pattern.title == "Export → PDF → Mail")
        let offerID = offerApprentice.offer!.id
        offerApprentice.dismissOffer(offerID)
        offerApprentice.evaluatePatterns(now: now.addingTimeInterval(10))
        precondition(offers == 1 && offerApprentice.offer == nil, "the same pattern is offered at most once that day")

        let redactionProof = CookieProof(file: nil)
        let redactionApprentice = CookieApprentice(defaults: defaults, store: CookieApprenticeStore(file: nil), proof: redactionProof)
        redactionApprentice.handleObserved(CookieApprentice.ObservedEvent(bundleID: "com.example.editor",
            kind: .press(role: "AXButton", label: "Paste ghp_abcdefghijklmnopqrstuvwxyz0123456789AB"),
            secureInput: false, blocked: false, date: Date()))
        if case .press(_, let safeLabel) = redactionApprentice.localSteps.first?.action {
            precondition(!safeLabel.contains("ghp_abcdefghijklmnopqrstuvwxyz"))
        } else { preconditionFailure("the pressed-control label is saved only after masking") }
        precondition(redactionProof.today.contains { $0.kind == .redacted && $0.feature == "shadow-apprentice" })
        precondition(redactionProof.today.contains { $0.kind == .saw && $0.feature == "shadow-apprentice" },
                     "the actual observed-event path records its daily .saw proof")

        let summaryProof = CookieProof(file: nil)
        let summaryStore = CookieApprenticeStore(file: nil, now: now)
        let summaryApprentice = CookieApprentice(defaults: defaults, store: summaryStore, proof: summaryProof)
        summaryApprentice.recordDailyProofIfNeeded(stepCount: 7)
        summaryApprentice.recordDailyProofIfNeeded(stepCount: 2)
        precondition(summaryProof.today.count == 1 && summaryProof.today[0].kind == .saw)
        precondition(summaryProof.today[0].summary.contains("7 structural steps") && !summaryProof.today[0].summary.contains("Export"))

        let retention = CookieApprenticeStore(file: nil, now: now)
        try! retention.append(CookieApprenticeStep(date: now.addingTimeInterval(-8 * 24 * 3600),
                                                   appBundleID: "com.example.editor", action: .typed), now: now)
        precondition(retention.steps.isEmpty, "older than seven days is pruned locally")
        print("10 shadow apprentice checks passed.")
    }
}
