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
        CookieCheckList.spin { offerApprentice.offer != nil }
        precondition(offerApprentice.offer?.pattern.title == "Export → PDF → Mail")
        let offerID = offerApprentice.offer!.id
        offerApprentice.dismissOffer(offerID)
        offerApprentice.evaluatePatterns(now: now.addingTimeInterval(10))
        CookieCheckList.spin { !offerApprentice.isMining }
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

        precondition(redactionProof.today.filter { $0.kind == .saw }.count == 1, "one .saw row a day")
        precondition(CookieApprentice.sawSummary(7).contains("7 structural steps") && !CookieApprentice.sawSummary(7).contains("Export"))

        let retention = CookieApprenticeStore(file: nil, now: now)
        try! retention.append(CookieApprenticeStep(date: now.addingTimeInterval(-8 * 24 * 3600),
                                                   appBundleID: "com.example.editor", action: .typed), now: now)
        precondition(retention.steps.isEmpty, "older than seven days is pruned locally")
        let audited = audit(defaults: defaults)
        print("\(10 + audited) shadow apprentice checks passed.")
    }

    /// Checks added for the review of 356fea2: each name says the rule it pins.
    static func audit(defaults: UserDefaults) -> Int {
        let list = CookieCheckList()
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("cookie-apprentice-\(UUID().uuidString)")
        try! fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        defer { try? fm.removeItem(at: folder) }
        let now = Date()
        func press(_ label: String, _ at: TimeInterval, role: String = "AXButton") -> CookieApprenticeStep {
            CookieApprenticeStep(date: now.addingTimeInterval(at), appBundleID: "com.example.editor", action: .press(role: role, label: label))
        }
        func key(_ combo: String, _ at: TimeInterval) -> CookieApprenticeStep {
            CookieApprenticeStep(date: now.addingTimeInterval(at), appBundleID: "com.example.editor", action: .key(combo))
        }
        func typed(_ at: TimeInterval) -> CookieApprenticeStep {
            CookieApprenticeStep(date: now.addingTimeInterval(at), appBundleID: "com.example.editor", action: .typed)
        }
        /// The same steps in three sessions, six minutes apart.
        func threeSessions(_ make: (TimeInterval) -> [CookieApprenticeStep]) -> [CookieApprenticeStep] {
            (0..<3).flatMap { make(Double($0) * 360) }
        }

        // C1: an event doesn't rewrite the archive; saving is debounced and in the background.
        let debouncedFile = folder.appendingPathComponent("debounced.json")
        let debounced = CookieApprenticeStore(file: debouncedFile, now: now)
        try! debounced.append(press("Export", 0), now: now)
        list.expect(!fm.fileExists(atPath: debouncedFile.path), "C1 append does not write the whole archive per event")

        let busyFile = folder.appendingPathComponent("busy.json")
        let busy = CookieApprenticeStore(file: busyFile, now: now)
        let started = Date()
        for index in 0..<2_000 { try! busy.append(press("Step \(index % 40)", Double(index)), now: now) }
        list.expect(Date().timeIntervalSince(started) < 1, "C1 2,000 events are bookkept in under a second")

        // Minor: the file is born 0600 and the shared folder keeps its mode.
        let staleFile = folder.appendingPathComponent("apprentice.json")
        let stale = CookieApprenticeArchive(steps: [typed(-8 * 24 * 3600)], offered: [:], proofDay: nil)
        try! JSONEncoder().encode(stale).write(to: staleFile)
        _ = CookieApprenticeStore(file: staleFile, now: now)
        let folderMode = (try? fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int) ?? 0
        let fileMode = (try? fm.attributesOfItem(atPath: staleFile.path)[.posixPermissions] as? Int) ?? 0
        list.expect(folderMode == 0o755, "Minor saving never changes the shared folder's mode")
        list.expect(fileMode == 0o600, "Minor the archive is owner-only")

        // I3: junk patterns are never offered; covered sub-patterns are suppressed.
        let downs = threeSessions { base in (0..<3).map { key("down", base + Double($0)) } }
        list.expect(CookieApprentice.repeats(in: downs).isEmpty, "I3 Down → Down → Down is not a pattern")
        let askReturn = threeSessions { base in [typed(base), key("return", base + 1), typed(base + 2)] }
        list.expect(CookieApprentice.repeats(in: askReturn).isEmpty, "I3 ask me → Return → ask me is not a pattern")
        let abcd = threeSessions { base in ["Export", "PDF", "Mail", "Send"].enumerated().map { press($1, base + Double($0)) } }
        let abcdPatterns = CookieApprentice.repeats(in: abcd)
        list.expect(abcdPatterns.count == 1 && abcdPatterns.first?.title == "Export → PDF → Mail → Send",
                    "I3 sub-patterns covered by a longer one are suppressed")

        // I3: Later snoozes the pattern and doesn't immediately offer another.
        let laterStore = CookieApprenticeStore(file: nil, now: now)
        let efg = threeSessions { base in ["Archive", "Label", "Move"].enumerated().map { press($1, base + 2_000 + Double($0)) } }
        for step in (abcd + efg).sorted(by: { $0.date < $1.date }) { try! laterStore.append(step, now: now) }
        let later = CookieApprentice(defaults: defaults, store: laterStore, proof: CookieProof(file: nil))
        var laterOffers = 0
        later.onOffer = { _ in laterOffers += 1 }
        later.evaluatePatterns(now: now)
        CookieCheckList.spin { later.offer != nil }
        if let first = later.offer { later.dismissOffer(first.id) }
        CookieCheckList.spin(seconds: 0.5) { false }
        list.expect(laterOffers == 1 && later.offer == nil, "I3 Later does not immediately offer another pattern")

        // I4: mining 20,000 steps stays inside its time bound.
        var big: [CookieApprenticeStep] = []
        var generator = SystemRandomNumberGenerator()
        for index in 0..<20_000 {
            let gap = index % 50 == 0 ? 400.0 : 1.0
            let date = (big.last?.date ?? now).addingTimeInterval(gap)
            big.append(CookieApprenticeStep(date: date, appBundleID: "com.example.editor",
                                            action: .press(role: "AXButton", label: "Control \(Int.random(in: 0..<40, using: &generator))")))
        }
        // I4: mining runs off the main actor: the call returns first, the offer arrives later.
        let minedStore = CookieApprenticeStore(file: nil, now: now)
        for step in abcd { try! minedStore.append(step, now: now) }
        let mined = CookieApprentice(defaults: defaults, store: minedStore, proof: CookieProof(file: nil))
        mined.evaluatePatterns(now: now)
        list.expect(mined.offer == nil && mined.isMining, "I4 evaluatePatterns returns before mining finishes")
        CookieCheckList.spin { mined.offer != nil }
        list.expect(mined.offer?.pattern.title == "Export → PDF → Mail → Send", "I4 the detached miner's offer is applied on main")
        let mineStart = Date()
        _ = CookieApprentice.repeats(in: big)
        list.expect(Date().timeIntervalSince(mineStart) < 1.5, "I4 mining 20,000 steps finishes in bounded time")

        // I5: rows, links, cells and static text never keep their content as a label.
        let contentStore = CookieApprenticeStore(file: nil, now: now)
        let content = CookieApprentice(defaults: defaults, store: contentStore, proof: CookieProof(file: nil))
        for (role, label) in [("AXRow", "Re: Salary review"), ("AXOutlineRow", "Q3 board deck.key"), ("AXLink", "invoice-2291.pdf"),
                              ("AXCell", "Priya: running late"), ("AXStaticText", "Diagnosis notes"), ("AXButton", "Export")] {
            content.handleObserved(CookieApprentice.ObservedEvent(bundleID: "com.example.editor", kind: .press(role: role, label: label),
                                                                  secureInput: false, blocked: false, date: now))
        }
        let labels = content.localSteps.compactMap { step -> String? in
            if case .press(_, let label) = step.action { return label }; return nil
        }
        list.expect(labels.count == 6 && labels.prefix(5).allSatisfy(\.isEmpty) && labels.last == "Export",
                    "I5 content roles record role only; controls keep their label")

        // I6: Option without Cmd/Ctrl types a character, so it's a typing placeholder.
        if case .typed = CookieApprentice.classifyKey(flags: .maskAlternate, keyCode: CGKeyCode(kVK_ANSI_A)) {
            list.expect(true, "I6 Option+letter classifies as typing")
        } else { list.expect(false, "I6 Option+letter classifies as typing") }
        let optionStore = CookieApprenticeStore(file: nil, now: now)
        let option = CookieApprentice(defaults: defaults, store: optionStore, proof: CookieProof(file: nil))
        option.handleObserved(CookieApprentice.ObservedEvent(bundleID: "com.example.editor",
            kind: .key(flags: [.maskAlternate, .maskShift], keyCode: CGKeyCode(kVK_ANSI_S)), secureInput: false, blocked: false, date: now))
        list.expect(option.localSteps.map(\.action) == [.typed], "I6 Option+Shift+S is stored as a placeholder, not a combo")

        // Minor: the daily .saw row carries the real count, correctly pluralised.
        let countProof = CookieProof(file: nil)
        let counting = CookieApprentice(defaults: defaults, store: CookieApprenticeStore(file: nil, now: now), proof: countProof)
        for (index, label) in ["Export", "PDF", "Mail"].enumerated() {
            counting.handleObserved(CookieApprentice.ObservedEvent(bundleID: "com.example.editor", kind: .press(role: "AXButton", label: label),
                                                                   secureInput: false, blocked: false, date: Date().addingTimeInterval(Double(index))))
        }
        counting.stopForTermination()
        let sawRows = countProof.today.filter { $0.kind == .saw && $0.feature == "shadow-apprentice" }
        list.expect(sawRows.count == 1 && sawRows[0].summary.contains("3 structural steps"), "Minor the .saw row is updated with the real count")
        let oneProof = CookieProof(file: nil)
        let single = CookieApprentice(defaults: defaults, store: CookieApprenticeStore(file: nil, now: now), proof: oneProof)
        single.handleObserved(CookieApprentice.ObservedEvent(bundleID: "com.example.editor", kind: .press(role: "AXButton", label: "Export"),
                                                             secureInput: false, blocked: false, date: Date()))
        single.stopForTermination()
        list.expect(oneProof.today.contains { $0.kind == .saw && $0.summary.contains("1 structural step ") }
                    && !oneProof.today.contains { $0.summary.contains("1 structural steps") }, "Minor one step reads as one step")

        // Minor: turning noticing off also prunes anything past the week.
        let pruneStore = CookieApprenticeStore(file: nil, now: now)
        try! pruneStore.append(typed(-8 * 24 * 3600), now: now.addingTimeInterval(-8 * 24 * 3600))
        let pruning = CookieApprentice(defaults: defaults, store: pruneStore, proof: CookieProof(file: nil))
        pruning.setEnabled(false)
        list.expect(pruning.localSteps.isEmpty, "Minor turning noticing off prunes the week-old history")
        defaults.set(true, forKey: CookieApprentice.enabledKey)

        auditNewSurfaces(defaults: defaults, folder: folder, list: list, now: now, press: press, threeSessions: threeSessions)
        list.finish("Shadow apprentice audit")
        return list.passed
    }

    static func auditNewSurfaces(defaults: UserDefaults, folder: URL, list: CookieCheckList, now: Date,
                                 press: @escaping (String, TimeInterval, String) -> CookieApprenticeStep,
                                 threeSessions: ((TimeInterval) -> [CookieApprenticeStep]) -> [CookieApprenticeStep]) {
        let fm = FileManager.default
        func event(_ kind: CookieApprentice.ObservedEvent.Kind, bundle: String = "com.example.editor", category: String? = nil,
                   cookie: Bool = false, at: Date = Date()) -> CookieApprentice.ObservedEvent {
            CookieApprentice.ObservedEvent(bundleID: bundle, kind: kind, secureInput: false, blocked: false, date: at,
                                           category: category, postedByCookie: cookie)
        }

        // C1: flush writes once, owner-only, and the O(1) day counter matches a scan.
        let file = folder.appendingPathComponent("flushed.json")
        let store = CookieApprenticeStore(file: file, now: now)
        for index in 0..<5 { try! store.append(press("Step \(index)", Double(index), "AXButton"), now: now) }
        try! store.flush()
        let mode = (try? fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0
        list.expect(mode == 0o600 && CookieApprenticeStore(file: file, now: now).steps.count == 5, "C1 flush saves an owner-only archive that reloads")
        list.expect(store.stepsToday == store.steps.filter { Calendar.current.isDate($0.date, inSameDayAs: now) }.count,
                    "C1 the day count is kept without scanning")
        let backgroundFile = folder.appendingPathComponent("background.json")
        let background = CookieApprenticeStore(file: backgroundFile, now: now)
        background.saveDelay = 0.05
        try! background.append(press("Export", 0, "AXButton"), now: now)
        CookieCheckList.spin { fm.fileExists(atPath: backgroundFile.path) }
        list.expect(fm.fileExists(atPath: backgroundFile.path), "C1 the debounced save lands in the background")

        // C1 + I7: Accessibility work runs off the main actor and skips Cookie's own events.
        final class Box: @unchecked Sendable { var done = false; var result: CookieApprentice.ObservedEvent? }
        let box = Box()
        let own = CookieApprenticeRawEvent(isClick: false, location: .zero, keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand,
                                           targetPID: getpid(), sourcePID: getpid(), secureInput: false, date: Date())
        Task.detached { let result = CookieApprenticeReader.resolve(own); await MainActor.run { box.result = result; box.done = true } }
        CookieCheckList.spin { box.done }
        list.expect(box.done && box.result == nil, "I7 events Cookie posted are dropped before any lookup, off the main actor")

        // I1: Esc is ignored, never a reason to turn the setting off.
        let escStore = CookieApprenticeStore(file: nil, now: now)
        let esc = CookieApprentice(defaults: defaults, store: escStore, proof: CookieProof(file: nil))
        esc.handleObserved(event(.key(flags: [], keyCode: CGKeyCode(kVK_Escape))))
        list.expect(esc.isEnabled && defaults.bool(forKey: CookieApprentice.enabledKey) && esc.localSteps.isEmpty,
                    "I1 Esc neither records nor disables noticing")

        // I7: finance/medical categories, Cookie's own events and Cookie-driven tasks are not observed.
        let gateStore = CookieApprenticeStore(file: nil, now: now)
        let gate = CookieApprentice(defaults: defaults, store: gateStore, proof: CookieProof(file: nil))
        gate.handleObserved(event(.press(role: "AXButton", label: "Transfer"), bundle: "com.example.bank", category: "public.app-category.finance"))
        gate.handleObserved(event(.press(role: "AXButton", label: "Results"), bundle: "com.example.clinic", category: "public.app-category.medical"))
        gate.handleObserved(event(.press(role: "AXButton", label: "Export"), cookie: true))
        var acting = true
        gate.cookieIsActing = { acting }
        gate.handleObserved(event(.press(role: "AXButton", label: "Export")))
        acting = false
        gate.handleObserved(event(.press(role: "AXButton", label: "Export")))
        list.expect(gate.localSteps.count == 1, "I7 finance, medical, Cookie-posted and Cookie-task events are skipped")

        // I2: however the notice leaves, a pending offer is cleared.
        let model = NotchModel(notchSize: CGSize(width: 200, height: 32), hasNotch: true, availableSize: CGSize(width: 1400, height: 860))
        var left: [String] = []
        model.noticeLeft = { notice in if let id = notice.apprenticePatternID { left.append(id) } }
        let offerNotice = NotchNotice(threadID: UUID(), title: "Cookie noticed a pattern", message: "", failed: false, apprenticePatternID: "p1")
        model.notice = offerNotice
        model.state = .notice
        model.state = .closed
        model.notice = NotchNotice(threadID: UUID(), title: "Cookie noticed a pattern", message: "", failed: false, apprenticePatternID: "p2")
        model.state = .notice
        model.notice = NotchNotice(threadID: UUID(), title: "Cookie", message: "Done", failed: false)
        list.expect(left == ["p1", "p2"], "I2 the notice lifecycle reports closing and replacement")
        let pendingStore = CookieApprenticeStore(file: nil, now: now)
        let efg = threeSessions { base in ["Archive", "Label", "Move"].enumerated().map { press($1, base + Double($0), "AXButton") } }
        for step in efg { try! pendingStore.append(step, now: now) }
        let pending = CookieApprentice(defaults: defaults, store: pendingStore, proof: CookieProof(file: nil))
        pending.evaluatePatterns(now: now)
        CookieCheckList.spin { pending.offer != nil }
        if let id = pending.offer?.id { pending.noticeLeft(id) }
        list.expect(pending.offer == nil, "I2 an offer whose notice left no longer blocks the next one")

        // Minor: Clear history removes every step and the file.
        let clearFile = folder.appendingPathComponent("clear.json")
        let clearStore = CookieApprenticeStore(file: clearFile, now: now)
        try! clearStore.append(press("Export", 0, "AXButton"), now: now)
        try! clearStore.flush()
        let clearing = CookieApprentice(defaults: defaults, store: clearStore, proof: CookieProof(file: nil))
        clearing.clearHistory()
        list.expect(clearing.localSteps.isEmpty && !fm.fileExists(atPath: clearFile.path), "Minor Clear history removes the local archive")
    }
}
