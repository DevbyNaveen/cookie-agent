import AppKit

/// Memory at your cursor: names, tickets, emails and amounts are found and ordinary words aren't;
/// recall becomes at most three sourced, dated lines about the entity; answers keep 10 minutes;
/// nothing found, signed out or too slow means no card; and the hover really asks.
@MainActor
enum CookieMemoryCursorTests {
    static func run() async {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }

        // Extraction: (text, the word the pointer is on, expected kind and text; nil for none).
        func at(_ text: String, _ word: String) -> CookieEntity? {
            let range = (text as NSString).range(of: word)
            precondition(range.location != NSNotFound, word)
            return CookieEntity.extract(from: text, at: range.location + range.length / 2)
        }
        let table: [(String, String, CookieEntity.Kind?, String?)] = [
            ("Call Anna Berzina tomorrow", "Berzina", .person, "Anna Berzina"),
            ("Call Anna Berzina tomorrow", "Anna", .person, "Anna Berzina"),
            ("Hi Anna, thanks for this", "Anna", .person, "Anna"),
            ("Anna's notes are in", "Anna", .person, "Anna"),
            ("Ask Peter Jan Marie Claire Smith", "Smith", .person, "Jan Marie Claire Smith"),
            ("from anna.berzina@acme.com today", "berzina", .person, "Anna Berzina"),
            ("mail jb@x.io now", "jb", .person, "jb"),
            ("Fixed in ABC-123 last week", "ABC", .id, "ABC-123"),
            ("see #482 for details", "482", .id, "#482"),
            ("Budget is €1,200 for Q1", "200", .number, "€1,200"),
            ("about $3.4k a month", "3.4", .number, "$3.4k"),
            ("it costs 1 200 EUR in total", "200", .number, "1 200 EUR"),
            ("Ship ThinkingRoot today", "Thinking", .project, "ThinkingRoot"),
            ("The Apollo Project ships", "Project", .project, "Apollo Project"),
            ("Meeting moved. The meeting is at 3", "Meeting", nil, nil),
            ("the quick brown fox", "quick", nil, nil),
            ("Press OK to continue", "OK", nil, nil),
            ("FILE EDIT VIEW", "EDIT", nil, nil),
            ("Monday works for me", "Monday", nil, nil),
            ("Hi Anna, thanks for this", "Hi", nil, nil),
            ("we sold 40 units", "40", nil, nil),
        ]
        for (text, word, kind, expected) in table {
            let found = at(text, word)
            check(found?.kind == kind && found?.text == expected, "\(text) @ \(word): \(String(describing: found))")
        }
        check(CookieEntity.extract(from: "Anna", at: 9) == nil && CookieEntity.extract(from: "", at: 0) == nil, "out of range")
        check(CookieEntity(kind: .person, text: "Anna  Berzina").key == CookieEntity(kind: .person, text: "ANNA berzina").key,
              "one cache entry whatever the case")

        // Recall → at most three lines that mention the entity, with day and source when there are.
        let anna = CookieEntity(kind: .person, text: "Anna Berzina")
        let answer = #"""
        {"hits":[
          {"id":"m1","statement":"Anna is on Business at $25 per seat. She renews in March.","source_uri":"/workspace/sources/synced/gmail/re--a1b2.md","valid_from":1792886400},
          {"id":"m2","statement":"Halvorsen moved to Pro."},
          {"id":"m3","statement":"  "},
          {"id":"m4","statement":"Berzina asked for the onboarding deck."},
          {"id":"m5","statement":"Anna prefers calls before 10."},
          {"id":"m6","statement":"Anna owns the Riga pilot."}
        ],"reading":{}}
        ── Since you last looked ──
        """#
        let card = CookieMemoryCard.parse(answer, about: anna)
        check(card?.title == "Anna Berzina" && card?.lines.count == 3, "three lines at most: \(String(describing: card))")
        check(card?.lines.map(\.text) == ["Anna is on Business at $25 per seat.", "Berzina asked for the onboarding deck.",
                                          "Anna prefers calls before 10."], "only lines about her, first sentence each")
        check(card?.lines[0].date == Date(timeIntervalSince1970: 1792886400) && card?.lines[0].source == "gmail"
              && card?.lines[1].source == "m4" && card?.lines[1].date == nil, "dated and sourced when the hit says")
        check(card?.footer.hasPrefix("from Enkeon · gmail · ") == true, card?.footer ?? "")
        check(CookieMemoryCard.parse(#"{"hits":[{"statement":"Halvorsen moved to Pro."}]}"#, about: anna) == nil
              && CookieMemoryCard.parse(#"{"hits":[]}"#, about: anna) == nil && CookieMemoryCard.parse("not json", about: anna) == nil,
              "nothing about her: no card")
        check(CookieMemoryCard.mentions("The budget was set at 1200 EUR.", CookieEntity(kind: .number, text: "€1,200")),
              "an amount matches however it's written")

        // Lookup: cached 10 minutes per entity (a "nothing" too), a proof row per real send with the kind only.
        let defaults = UserDefaults(suiteName: "cookie-memory-cursor-\(UUID().uuidString)")!
        let proof = CookieProof(file: nil)
        let cursor = CookieMemoryCursor()
        var asked: [String] = []
        var reply = answer
        var clock = Date()
        cursor.lookup = { query in asked.append(query); return reply }
        cursor.signedIn = { true }
        cursor.now = { clock }
        cursor.proof = proof
        cursor.defaults = defaults
        let first = await cursor.card(for: anna)
        let again = await cursor.card(for: CookieEntity(kind: .person, text: "anna berzina"))
        check(first == card && again == card && asked == ["Anna Berzina"], "a second hover is answered from the cache: \(asked)")
        clock = clock.addingTimeInterval(11 * 60)
        _ = await cursor.card(for: anna)
        check(asked.count == 2, "after 10 minutes Enkeon is asked again")
        check(proof.entries.count == 2 && proof.entries.allSatisfy { $0.kind == .sent && $0.destination == "Enkeon"
            && $0.summary == "a person to look up" }, "proof: kind only, never the name: \(proof.entries.map(\.summary))")
        reply = #"{"hits":[]}"#
        let halvorsen = CookieEntity(kind: .project, text: "Halvorsen")
        let none = await cursor.card(for: halvorsen)
        _ = await cursor.card(for: halvorsen)
        check(none == nil && asked.count == 3, "nothing found is remembered too")

        // Signed out, or switched off: Enkeon isn't asked at all.
        cursor.signedIn = { false }
        let signedOut = await cursor.card(for: CookieEntity(kind: .id, text: "ABC-123"))
        cursor.signedIn = { true }
        defaults.set(false, forKey: CookieMemoryCursor.enabledKey)
        let off = await cursor.card(for: CookieEntity(kind: .id, text: "ABC-123"))
        defaults.removeObject(forKey: CookieMemoryCursor.enabledKey)
        check(signedOut == nil && off == nil && asked.count == 3, "signed out or off: no lookup")

        // Too slow: no card in about 1.5 s, and not cached, so the next hover asks again.
        cursor.lookup = { query in asked.append(query); try await Task.sleep(for: .seconds(10)); return answer }
        let started = Date()
        let slow = await cursor.card(for: CookieEntity(kind: .id, text: "XYZ-9"))
        check(slow == nil && Date().timeIntervalSince(started) < 2.5, "gives up at its deadline")
        cursor.lookup = { query in asked.append(query); return #"{"hits":[{"statement":"XYZ-9 shipped on Friday."}]}"# }
        let retried = await cursor.card(for: CookieEntity(kind: .id, text: "XYZ-9"))
        check(retried?.lines.first?.text == "XYZ-9 shipped on Friday.", "a timeout isn't cached")

        // The hover path: an entity under the pointer asks Enkeon, and the card takes the pill's place;
        // no entity, or a refusal, never asks.
        precondition(UserDefaults.standard.string(forKey: CookieModelSettings.modelKey) == nil, "the checks run without a model")
        cursor.lookup = { query in asked.append(query); return answer }
        let explainer = CookieHoverExplainer()
        explainer.memory = cursor
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        func reading(_ entity: CookieEntity?, refused: Bool = false) -> CookieHoverReading {
            CookieHoverReading(element: AXUIElementCreateSystemWide(), refused: refused,
                               frame: CGRect(x: 100, y: 100, width: 120, height: 20), context: "App: Mail", entity: entity)
        }
        func settle() async {
            for _ in 0..<100 where explainer.explanation?.memory == nil { try? await Task.sleep(for: .milliseconds(10)) }
        }
        let maria = CookieEntity(kind: .person, text: "Maria")
        let beforeHover = asked.count
        explainer.present(reading(maria), pointer: CGPoint(x: 110, y: 110), display: display)
        check(explainer.explanation?.memory == nil && explainer.explanation?.text.hasPrefix("Choose a model") == true,
              "the usual explanation starts at once")
        await settle()
        check(asked.count == beforeHover + 1 && asked.last == "Maria" && explainer.explanation?.memory == nil,
              "the hover asked Enkeon; nothing about Maria, so no card and the explanation stays")
        explainer.present(reading(anna), pointer: CGPoint(x: 300, y: 300), display: display)
        await settle()
        check(explainer.explanation?.memory?.title == "Anna Berzina", "a card replaces the pill")
        let count = asked.count
        explainer.present(reading(nil), pointer: CGPoint(x: 500, y: 500), display: display)
        explainer.present(reading(CookieEntity(kind: .id, text: "ZZZ-1"), refused: true), pointer: CGPoint(x: 600, y: 600), display: display)
        try? await Task.sleep(for: .milliseconds(50))
        check(asked.count == count && explainer.explanation?.refused == true && explainer.explanation?.memory == nil,
              "no entity, or a refused place: Enkeon isn't asked")

        print("\(checks) memory cursor checks passed.")
    }
}
