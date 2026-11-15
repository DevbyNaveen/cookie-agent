import AppKit

/// Live screen layers: phrases pick the lens; the model's JSON is taken strictly; lines are followed
/// across a scroll (shifts, duplicates, lines gone and new); new lines go at most every 4 s, each text
/// once, within the caps; translations fit their boxes; Esc, an app switch, a closed window and ten
/// minutes stop it; what goes up is words with secrets hidden, never a picture; and a lens started with
/// fake capture, reading and model really draws.
@MainActor
enum CookieLayersTests {
    /// Everything the layer touches, faked. Not main-actor bound: the reader calls in from anywhere.
    final class Fake {
        var frame: CGRect? = CGRect(x: 100, y: 100, width: 800, height: 600)
        var front: pid_t = 42
        var lines: [CookieTextLine] = []
        var refusal: String?
        var screenAllowed = true
        var missing: String?
        var signedIn = true
        var clock = Date(timeIntervalSince1970: 10_000)
        var asked: [(input: String, instructions: String)] = []
        var reply: (String) -> String = { _ in #"{"items":[]}"# }
        var recalled: [String] = []
        var recall: (String) -> String = { _ in #"{"hits":[]}"# }
        var board: [WorkItem] = []
        var image: CGImage = CookieLayersTests.picture(white: true)
        var idled = 0

        var environment: CookieLayerEnvironment {
            CookieLayerEnvironment(
                frontApp: { [unowned self] in CookieLayerTarget(pid: self.front, app: "Safari", bundleID: "com.apple.Safari", category: nil) },
                windowFrame: { [unowned self] _ in self.frame },
                displayFrame: { _ in CGRect(x: 0, y: 0, width: 1440, height: 900) },
                refusal: { [unowned self] _ in self.refusal },
                accessibility: { true },
                screenAllowed: { [unowned self] in self.screenAllowed },
                capture: { [unowned self] _ in self.image },
                read: { [unowned self] _ in self.lines },
                model: { [unowned self] in ("test:model", self.missing) },
                ask: { [unowned self] _, input, instructions in
                    self.asked.append((input, instructions))
                    return self.reply(input)
                },
                signedIn: { [unowned self] in self.signedIn },
                recall: { [unowned self] query in
                    self.recalled.append(query)
                    return self.recall(query)
                },
                board: { [unowned self] in self.board },
                now: { [unowned self] in self.clock },
                hideSecrets: { true },
                language: { "English" },
                idle: { [unowned self] in self.idled += 1 })
        }
    }

    nonisolated static func picture(white: Bool) -> CGImage {
        let context = CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(white ? CGColor(red: 1, green: 1, blue: 1, alpha: 1) : CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        return context.makeImage()!
    }

    /// A line of text whose words share its box evenly; normalised, bottom-left.
    static func line(_ text: String, y: CGFloat, x: CGFloat = 0.1, width: CGFloat = 0.5) -> CookieTextLine {
        let length = CGFloat((text as NSString).length)
        let words = CookieTextLine.wordRanges(in: text).map { range in
            CookieTextWord(start: range.lowerBound, end: range.upperBound,
                           box: CGRect(x: x + width * CGFloat(range.lowerBound) / length, y: y,
                                       width: width * CGFloat(range.count) / length, height: 0.04))
        }
        return CookieTextLine(text: text, box: CGRect(x: x, y: y, width: width, height: 0.04), words: words)
    }

    /// The model, faked: each numbered line it knows gets its answer.
    static func answering(_ answers: [String: String], kind: String = "translate", note: String? = nil) -> (String) -> String {
        { input in
            var items: [String] = []
            for row in input.split(separator: "\n") {
                guard let colon = row.firstIndex(of: ":"), let number = Int(row[..<colon]) else { continue }
                let text = row[row.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard let answer = answers[text] else { continue }
                let noted = note.map { #","note":"\#($0)""# } ?? ""
                items.append(#"{"line":\#(number),"text":"\#(answer)","kind":"\#(kind)"\#(noted)}"#)
            }
            return #"{"items":["# + items.joined(separator: ",") + "]}"
        }
    }

    static func drain() async { for _ in 0..<40 { await Task.yield() } }

    static func run() async {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }

        // Lens routing: commands only; a question that mentions translating stays a question.
        let phrases: [(String, CookieLayerCommand?)] = [
            ("Translate this page", .start(.translate, language: nil)),
            ("translate this page to German", .start(.translate, language: "German")),
            ("Hey Cookie, could you please translate the window into japanese?", .start(.translate, language: "Japanese")),
            ("translate what's on my screen", .start(.translate, language: nil)),
            ("Translate the whole document into Latvian for me", .start(.translate, language: "Latvian")),
            ("Check this contract", .start(.review, language: nil)),
            ("Is there anything risky here?", .start(.review, language: nil)),
            ("anything risky on this page", .start(.review, language: nil)),
            ("Who do I owe a reply?", .start(.owed, language: nil)),
            ("who do i owe a reply to", .start(.owed, language: nil)),
            ("Who's waiting on me?", .start(.owed, language: nil)),
            ("Stop the layer.", .stop),
            ("turn off the layer", .stop),
            ("stop translating", .stop),
            ("How do I translate this page in Safari?", nil),
            ("translate this", nil),
            ("what's risky about skydiving", nil),
            ("check the weather", nil),
            ("who do I owe money to in this spreadsheet and why", nil),
            // Reading and scanning are ordinary requests ("read this page" to me), never a review layer.
            ("read this page", nil),
            ("Read the document", nil),
            ("scan this contract", nil),
            ("review the contract", .start(.review, language: nil)),
        ]
        for (phrase, expected) in phrases {
            check(CookieLayerCommand.parse(phrase) == expected, "\(phrase) → \(String(describing: CookieLayerCommand.parse(phrase)))")
        }
        check(CookieLayerCommand.parse("translate this email", selection: true) == nil
              && CookieLayerCommand.parse("translate this email") == .start(.translate, language: nil)
              && CookieLayerCommand.parse("stop the layer", selection: true) == .stop, "with text selected, no layer starts (the edit does)")
        check(CookieLayerLanguage.preferred(["lv-LV"]) == "Latvian" && CookieLayerLanguage.preferred(["de"]) == "German"
              && CookieLayerLanguage.preferred([]) == "English", "the Mac's first language when none is named")
        check(CookieLayerLanguage.named("klingon") == "Klingon", "a language it doesn't know is kept as said")

        // The model's JSON, strictly.
        let reply = #"""
        Here you go: {"items":[
          {"line":1,"text":"Hello world","kind":"translate"},
          {"line":1,"text":"a second answer for line one","kind":"translate"},
          {"line":9,"text":"no such line","kind":"translate"},
          {"line":0,"text":"zero","kind":"translate"},
          {"line":2,"text":"   ","kind":"translate"},
          {"line":2,"text":"wrong kind","kind":"flag","note":"x"},
          {"line":true,"text":"a boolean line","kind":"translate"},
          {"line":2.5,"text":"half a line","kind":"translate"},
          {"line":"2","text":"a string line","kind":"translate"},
          {"line":3,"text":"Thanks\nso much","kind":"translate","note":"dropped"}
        ]} and that's all
        """#
        check(CookieLayerResponse.parse(reply, lens: .translate, lines: 3)
              == [CookieLayerItem(line: 1, text: "Hello world", kind: .translate, note: nil),
                  CookieLayerItem(line: 3, text: "Thanks so much", kind: .translate, note: nil)],
              "unknown lines and kinds dropped: \(CookieLayerResponse.parse(reply, lens: .translate, lines: 3))")
        let flags = CookieLayerResponse.parse(#"{"items":[{"line":1,"text":"renews","kind":"flag"},{"line":2,"text":"fee","kind":"flag","note":"one two three four five six seven eight nine ten eleven twelve thirteen"}]}"#,
                                              lens: .review, lines: 2)
        check(flags.count == 1 && flags[0].line == 2 && flags[0].note?.split(separator: " ").count == 12
              && flags[0].note?.hasSuffix("\u{2026}") == true, "a flag needs a reason of at most twelve words")
        check(CookieLayerResponse.parse(#"{"items":[{"line":1,"text":"You promised","kind":"badge"}]}"#, lens: .owed, lines: 1).isEmpty
              && CookieLayerResponse.parse("no json at all", lens: .translate, lines: 3).isEmpty
              && CookieLayerResponse.parse(#"{"answer":"hi"}"#, lens: .translate, lines: 3).isEmpty
              && CookieLayerResponse.parse(#"{"items":[{"line":1,"text":"x","kind":"translate"}]}"#, lens: .translate, lines: 0).isEmpty,
              "a badge without a source, prose, or no items: nothing")

        // Following lines across a scroll: the page moved up 150 pt; one "Total" left, one stayed.
        func rect(_ y: CGFloat) -> CGRect { CGRect(x: 120, y: y, width: 300, height: 18) }
        let before: [(key: String, rect: CGRect)] = [("intro", rect(700)), ("total", rect(600)), ("line one", rect(500)),
                                                     ("total", rect(400)), ("end", rect(300))]
        let scrolled: [(key: String, rect: CGRect)] = [("total", rect(750)), ("line one", rect(650)), ("total", rect(550)),
                                                       ("end", rect(450)), ("fresh", rect(300))]
        check(CookieLayerMatcher.match(previous: before, current: scrolled) == [1, 2, 3, 4, nil], "shifted, duplicates in order, a new line")
        let further: [(key: String, rect: CGRect)] = [("line one", rect(650)), ("total", rect(550)), ("end", rect(450))]
        check(CookieLayerMatcher.match(previous: before, current: further) == [2, 3, 4],
              "the Total still on screen is the one that was below, not the one that scrolled off")
        check(CookieLayerMatcher.normalise("Hello, world.") == CookieLayerMatcher.normalise("hello world")
              && CookieLayerMatcher.normalise("Café  Résumé!") == "cafe resume", "OCR punctuation and accents don't make a new line")

        // Batching, on a clock: dedupe, one batch out at a time, every 4 s at most, retries, caps.
        let t0 = Date(timeIntervalSince1970: 1_000)
        var batcher = CookieLayerBatcher()
        check(batcher.take([("a", "A"), ("b", "B"), ("a", "A")], now: t0)?.map(\.key) == ["a", "b"], "each text once")
        check(batcher.take([("c", "C")], now: t0.addingTimeInterval(5)) == nil, "nothing while a batch is out")
        batcher.finish(["a": .item(text: "Ah", note: nil)])
        check(batcher.outcome("a") == .item(text: "Ah", note: nil) && batcher.outcome("b") == .nothing, "a line passed over is never asked again")
        check(batcher.take([("a", "A"), ("b", "B"), ("c", "C")], now: t0.addingTimeInterval(3.9)) == nil, "not within 4 s")
        check(batcher.take([("a", "A"), ("b", "B"), ("c", "C")], now: t0.addingTimeInterval(4))?.map(\.key) == ["c"], "only the new line, at 4 s")
        batcher.fail()
        check(batcher.take([("c", "C")], now: t0.addingTimeInterval(6)) == nil
              && batcher.take([("c", "C")], now: t0.addingTimeInterval(8))?.map(\.key) == ["c"], "a failed batch is retried at the next turn")
        batcher.finish([:])
        check(batcher.take([("a", "A"), ("b", "B"), ("c", "C")], now: t0.addingTimeInterval(20)) == nil, "everything answered: nothing to send")
        var capped = CookieLayerBatcher()
        let many = (0..<720).map { ("k\($0)", "line \($0)") }
        for turn in 0..<6 {
            let batch = capped.take(many, now: t0.addingTimeInterval(Double(turn) * 4))
            check(batch?.count == CookieLayerBatcher.maxLines, "at most 120 lines per upload")
            capped.finish([:])
        }
        check(capped.cache.count == CookieLayerBatcher.maxCached && capped.outcome("k0") == nil && capped.outcome("k719") == .nothing,
              "at most 600 kept, the oldest dropped first")

        // Text fit: as big as the line allows, smaller to fit, then cut.
        let roomy = CookieLayerFit.fontSize(for: "Hi", in: CGSize(width: 200, height: 20))
        check(roomy == (14, false), "roomy: the line's own size \(roomy)")
        let long = "Thank you very much for the quick reply"
        let squeezed = CookieLayerFit.fontSize(for: long, in: CGSize(width: 220, height: 20))
        check(squeezed.size < 14 && squeezed.size >= CookieLayerFit.minSize && !squeezed.truncates
              && CookieLayerFit.width(long, squeezed.size) <= 220 - CookieLayerFit.padding
              && CookieLayerFit.width(long, squeezed.size + 0.5) > 220 - CookieLayerFit.padding, "the biggest size that fits: \(squeezed)")
        check(CookieLayerFit.fontSize(for: String(repeating: long + " ", count: 4), in: CGSize(width: 180, height: 20)) == (CookieLayerFit.minSize, true),
              "past the smallest size it is cut with an ellipsis")
        check(CookieLayerFit.fontSize(for: "x", in: CGSize(width: 100, height: 6)).size == CookieLayerFit.minSize, "never below the minimum")
        check(!CookieLayerTone.isDark(picture(white: true), box: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.2))
              && CookieLayerTone.isDark(picture(white: false), box: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.2)), "the card matches the page")
        check(CookieLayerNotes.stack([10, 20, 100], height: 30) == [10, 40, 100], "margin notes never overlap")

        // Stop conditions.
        let start = Date(timeIntervalSince1970: 0), own: pid_t = 7
        check(CookieLayerStop.check(startedAt: start, now: start.addingTimeInterval(600), targetPID: 42, frontPID: 42, ownPID: own, windowFound: true) == .timeLimit
              && CookieLayerStop.check(startedAt: start, now: start.addingTimeInterval(60), targetPID: 42, frontPID: 43, ownPID: own, windowFound: true) == .appSwitched
              && CookieLayerStop.check(startedAt: start, now: start.addingTimeInterval(60), targetPID: 42, frontPID: own, ownPID: own, windowFound: true) == nil
              && CookieLayerStop.check(startedAt: start, now: start.addingTimeInterval(60), targetPID: 42, frontPID: 42, ownPID: own, windowFound: false) == .windowClosed
              && CookieLayerStop.check(startedAt: start, now: start.addingTimeInterval(599), targetPID: 42, frontPID: 42, ownPID: own, windowFound: true) == nil,
              "ten minutes, another app (not Cookie's own window), a closed window")
        check(CookieLayerStop.isStopKey(keyCode: 53, modifiers: []) && !CookieLayerStop.isStopKey(keyCode: 53, modifiers: [.command])
              && !CookieLayerStop.isStopKey(keyCode: 36, modifiers: []), "Esc on its own stops it")
        check(CookieLayerStop.asked.notice == nil && CookieLayerStop.replaced.notice == nil
              && CookieLayerStop.appSwitched.notice == "Layer off · you switched apps", "the notch says why when it wasn't asked")

        // Privacy: numbered words, secrets hidden; with the setting off they are as read.
        let payload = CookieLayerPayload.input(lens: .translate, language: "English",
                                               lines: ["Carte 4242 4242 4242 4242 enregistrée", "Bonjour"], hideSecrets: true)
        check(payload.hidden == 1 && payload.text.contains("1: Carte [hidden] enregistrée") && payload.text.contains("2: Bonjour")
              && !payload.text.contains("4242") && payload.text.contains("translate into English"), payload.text)
        check(CookieLayerPayload.input(lens: .review, language: "", lines: ["Card 4242 4242 4242 4242"], hideSecrets: false).hidden == 0,
              "the Privacy setting is respected")

        // Errors before anything is read.
        let refused = Fake()
        let refusing = CookieLayers(environment: refused.environment, proof: CookieProof(file: nil))
        refused.screenAllowed = false
        check(refusing.start(.translate) == .noScreenPermission && refusing.phase == .idle && refusing.indicator?.failed == true,
              "no screen permission")
        refused.screenAllowed = true
        refused.refusal = "Cookie doesn't look at 1Password."
        check(refusing.start(.review) == .refused("Cookie doesn't look at 1Password."), "a refused app")
        refused.refusal = nil
        refused.missing = "Choose a model first."
        check(refusing.start(.translate) == .modelUnavailable("Choose a model first."), "no model")
        refused.missing = nil
        refused.signedIn = false
        check(refusing.start(.owed) == .notSignedIn && refusing.start(.translate) == nil, "Owed needs Enkeon; the others don't")
        refused.frame = nil
        check(refusing.start(.translate) == nil, "the earlier lens is replaced")
        await refusing.refresh()
        await drain()
        check(refusing.problem == .noWindow && refusing.phase == .idle && refusing.lastStop == .failed(.noWindow), "no window: its first read says so")
        refused.frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        refused.lines = []
        check(refusing.start(.translate) == nil, "starts")
        await refusing.refresh()
        check(refusing.problem == .nothingReadable && refusing.phase != .active, "nothing readable")

        // Wiring: a lens with fake capture, reading and model draws translations over their lines.
        let fake = Fake()
        let proof = CookieProof(file: nil)
        let layers = CookieLayers(environment: fake.environment, proof: proof)
        fake.lines = [line("Bonjour le monde", y: 0.5), line("Merci beaucoup", y: 0.4), line("42", y: 0.3)]
        fake.reply = answering(["Bonjour le monde": "Hello world", "Merci beaucoup": "Thank you very much",
                                "Au revoir": "Goodbye", "Carte [hidden] enregistrée": "Card [hidden] saved"])
        check(layers.start(.translate) == nil && layers.phase == .starting && layers.indicator?.text.contains("reading") == true, "starting")
        await layers.refresh()
        await layers.finishUpload()
        check(layers.phase == .active && layers.marks.map(\.text) == ["Hello world", "Thank you very much"], "drawn: \(layers.marks.map(\.text))")
        let hello = layers.marks[0]
        check(hello.kind == .translate && hello.rect == CGRect(x: 180, y: 400, width: 400, height: 24) && !hello.dark,
              "exactly over the original line: \(hello.rect)")
        check(fake.asked.count == 1 && fake.asked[0].input.contains("1: Bonjour le monde") && !fake.asked[0].input.contains("42")
              && fake.asked[0].instructions.contains("into English"), "one upload, lines with words only")
        check(layers.indicator?.text == "Layer · Translate · English · Esc to stop", layers.indicator?.text ?? "no indicator")
        let sent = proof.entries.filter { $0.kind == .sent }
        check(sent.count == 1 && sent[0].destination == "test:model" && sent[0].summary == "2 lines of the window as text, no picture"
              && proof.entries.filter { $0.kind == .saw }.count == 1 && !proof.entries.contains { $0.summary.contains("Bonjour") },
              "proof: one send with the line count and model, one look, no screen text")

        // Scroll 1.5 s later: lines move up 60 pt, one is gone, two are new; marks follow without an upload.
        fake.clock.addTimeInterval(1.5)
        fake.lines = [line("Bonjour le monde", y: 0.6), line("Au revoir", y: 0.4), line("Carte 4242 4242 4242 4242 enregistrée", y: 0.3)]
        await layers.refresh()
        await layers.finishUpload()
        check(layers.marks.count == 1 && layers.marks[0].id == hello.id && layers.marks[0].rect.minY == 460,
              "followed the scroll as the same mark; the line that left hides")
        check(fake.asked.count == 1, "new lines wait for the 4 s turn")
        fake.clock.addTimeInterval(2.5)
        await layers.refresh()
        await layers.finishUpload()
        check(fake.asked.count == 2 && fake.asked[1].input.contains("Au revoir") && !fake.asked[1].input.contains("Bonjour")
              && fake.asked[1].input.contains("[hidden]") && !fake.asked[1].input.contains("4242"),
              "only unseen lines go, secrets hidden: \(fake.asked[1].input)")
        check(layers.marks.map(\.text) == ["Hello world", "Goodbye", "Card [hidden] saved"], "\(layers.marks.map(\.text))")
        check(proof.entries.contains { $0.kind == .redacted && $0.hidden == 1 }, "the hidden card is in Proof")
        fake.clock.addTimeInterval(5)
        fake.lines = [line("Merci beaucoup", y: 0.5)]
        await layers.refresh()
        await layers.finishUpload()
        check(fake.asked.count == 2 && layers.marks.map(\.text) == ["Thank you very much"], "a line seen before isn't translated again")

        // The window moves: the layer moves with it, no read. Resized: it fades until the next read.
        let placed = layers.marks[0].rect
        fake.frame = fake.frame?.offsetBy(dx: 50, dy: -20)
        layers.tick()
        await drain()
        check(layers.marks[0].rect == placed.offsetBy(dx: 50, dy: -20) && !layers.settling, "moved with the window")
        fake.frame = CGRect(x: 150, y: 80, width: 700, height: 600)
        layers.tick()
        await drain()
        check(layers.settling, "fades while resizing")
        fake.clock.addTimeInterval(1)
        await layers.refresh()
        check(!layers.settling && layers.marks.count == 1, "placed again after the resize")

        // A password being typed: nothing is read and the layer hides, then comes back.
        fake.refusal = "Cookie doesn't look while a password is being typed."
        await layers.refresh()
        check(layers.marks.isEmpty && layers.paused != nil && layers.indicator?.text.contains("paused") == true, "paused")
        fake.refusal = nil
        await layers.refresh()
        check(layers.paused == nil && layers.marks.count == 1, "back once it's over")

        // A new lens replaces the old one cleanly.
        fake.lines = [line("This agreement renews automatically each year", y: 0.5), line("Fees are listed below", y: 0.4)]
        fake.reply = answering(["This agreement renews automatically each year": "renews automatically"], kind: "flag",
                               note: "Auto-renews yearly unless you cancel in time")
        let toolStart = layers.perform(.start(.review, language: nil))
        check(layers.isOn && layers.lens == .review && layers.phase == .starting && layers.marks.isEmpty, "replaced: \(toolStart)")
        fake.clock.addTimeInterval(10)
        await layers.refresh()
        await layers.finishUpload()
        check(layers.marks.count == 1 && layers.marks[0].kind == .flag && layers.marks[0].note == "Auto-renews yearly unless you cancel in time"
              && layers.marks[0].rect.width < layers.marks[0].line.width && layers.marks[0].rect.minX > layers.marks[0].line.minX,
              "the flagged words underlined, the reason beside them")
        check(fake.asked.last?.instructions.contains("auto") == true || fake.asked.last?.instructions.contains("renewals") == true, "the review brief")

        // Stops: another app, then (on a fresh start) the window closing, then ten minutes.
        layers.appActivated(pid: ProcessInfo.processInfo.processIdentifier)
        check(layers.isOn, "Cookie's own window coming forward doesn't stop it")
        layers.appActivated(pid: 99)
        check(layers.lastStop == .appSwitched && layers.marks.isEmpty && layers.indicator?.text == "Layer off · you switched apps", "app switch")
        await drain()
        check(layers.phase == .idle && layers.lens == nil, "stopped")
        _ = layers.start(.translate)
        await layers.refresh()
        fake.clock.addTimeInterval(5)
        fake.frame = nil
        await layers.refresh()
        check(layers.lastStop == .windowClosed, "window closed")
        await drain()
        fake.frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        _ = layers.start(.translate)
        fake.clock.addTimeInterval(CookieLayerStop.maxDuration)
        layers.tick()
        check(layers.lastStop == .timeLimit, "ten minutes")
        check(fake.idled > 0, "a layer that stops lets its model helper go")
        await drain()
        _ = layers.perform(.start(.translate, language: "German"))
        check(layers.indicator?.text.contains("German") == true && layers.perform(.stop) == "Layer off." && layers.lastStop == .asked
              && layers.indicator == nil, "voice start in a named language, voice stop")
        await drain()

        // Owed: a badge beside a name only with a real source; names nobody knows never reach the model.
        let owedFake = Fake()
        let owedProof = CookieProof(file: nil)
        let owed = CookieLayers(environment: owedFake.environment, proof: owedProof)
        owedFake.board = [WorkItem(title: "Send the pilot deck", to: "Anna Berzina", due: owedFake.clock.addingTimeInterval(2 * 86_400))]
        owedFake.recall = { query in
            query.contains("Anna") ? #"{"hits":[{"id":"m1","statement":"I promised Anna the onboarding deck by Tuesday.","source_uri":"/w/sources/synced/gmail/a.md"},{"id":"m2","statement":"Anna likes tea."}]}"#
                : #"{"hits":[]}"#
        }
        owedFake.lines = [line("Anna Berzina wrote: any news on the deck?", y: 0.5), line("Peter Smith joined the call", y: 0.4)]
        owedFake.reply = { input in
            input.contains("[B1] Board · Needs you: Send the pilot deck") && input.contains("[E1] Enkeon · gmail: I promised Anna")
                && !input.contains("likes tea")
                ? #"{"items":[{"line":1,"text":"You promised: deck · Tue","kind":"badge","note":"B1"},{"line":2,"text":"Invented","kind":"badge","note":"B1"}]}"#
                : #"{"items":[]}"#
        }
        check(owed.start(.owed) == nil, "owed starts when signed in")
        await owed.refresh()
        await owed.finishUpload()
        check(owed.marks.count == 1 && owed.marks[0].kind == .badge && owed.marks[0].text == "You promised: deck · Tue"
              && owed.marks[0].note == "Board · Needs you", "a badge with its source: \(owed.marks.map(\.text))")
        check(owed.marks[0].rect.minX == owed.marks[0].line.minX && owed.marks[0].rect.width < owed.marks[0].line.width / 2,
              "beside the name, not the line")
        check(owedFake.recalled.count == 2 && owedFake.asked.count == 1 && !owedFake.asked[0].input.contains("Peter"),
              "both names looked up; only the one with facts goes to the model")
        check(owedProof.entries.filter { $0.kind == .sent && $0.destination == "Enkeon" }.count == 2
              && owedProof.entries.contains { $0.kind == .sent && $0.destination == "test:model" && $0.summary.hasPrefix("1 name") },
              "proof: each name to Enkeon, one to the model")
        owed.stop()
        let made = Fake()
        let invented = CookieLayers(environment: made.environment, proof: CookieProof(file: nil))
        made.board = owedFake.board
        made.lines = [line("Anna Berzina wrote: any news?", y: 0.5)]
        made.reply = { _ in #"{"items":[{"line":1,"text":"You promised: a pony","kind":"badge","note":"Z9"}]}"# }
        _ = invented.start(.owed)
        await invented.refresh()
        await invented.finishUpload()
        check(invented.marks.isEmpty, "a badge citing no real source isn't drawn")
        invented.stop()

        // Wired into the app: overlay, voice, the model's tools, the notch.
        func source(_ name: String) -> String { (try? String(contentsOfFile: "Cookie/\(name)", encoding: .utf8)) ?? "" }
        check(source("OverlayWindow.swift").contains("CookieLayerView(marks: layers.marks"), "drawn in every display's overlay")
        let manager = source("CompanionManager.swift")
        check(manager.contains("CookieLayerCommand.parse(transcript, selection: selectionAtPress != nil)") && manager.contains("CookieLayers.shared.perform(command)")
              && manager.contains("CookieLayers.shared.showOverlay ="), "voice starts it, never with text selected")
        // Only the person's words start a layer: the model can't (a fetched page could ask it to read the screen for ten minutes).
        let harness = source("HarnessClient.swift")
        check(!harness.contains("CookieLayerTool") && !harness.contains("screen_layer") && !manager.contains("screen_layer")
              && !source("CookieLayers.swift").contains("screen_layer"), "the model has no layer tool")
        check(source("CookieBackgroundRuns.swift").contains("unattended: true"), "a routine's run says it's unattended")
        check(source("NotchIsland.swift").contains("CookieLayerIndicator()"), "the notch pill")
        // The window's frame is read off the main actor, with a back-off when the app is slow to answer.
        check(source("CookieLayers.swift").contains("windowFrame: { pid in await CookieWindowFrames.shared.frame(pid) }"), "AX off the main actor")
        // The three pills under the notch share one stack.
        check(["CookieLayers.swift", "CookieCanvas.swift", "CookieProof.swift"].allSatisfy { source($0).contains("CookieNotchStack.shared.place(") },
              "one stack for the notch pills")
        var backoff = CookieAXBackoff()
        let slowAt = Date(timeIntervalSince1970: 0)
        backoff.timedOut(slowAt)
        check(backoff.waiting(slowAt.addingTimeInterval(0.4)) && !backoff.waiting(slowAt.addingTimeInterval(0.6)), "a slow app waits half a second")
        backoff.timedOut(slowAt)
        backoff.timedOut(slowAt)
        check(backoff.step == 2, "then longer each time")
        for _ in 0..<10 { backoff.timedOut(slowAt) }
        check(backoff.step == CookieAXBackoff.longest, "never longer than 8 s")
        backoff.answered()
        check(!backoff.waiting(slowAt) && backoff.step == 0, "an answer clears it")
        // Esc: only the newest surface, once per press, and not while another app's sheet or full screen wants it.
        let escape = CookieEscape()
        escape.push(.layer)
        escape.push(.canvas)
        check(!escape.claims(.layer, at: 1, local: false, frontUsesEscape: { false }), "the older layer isn't Esc's")
        check(escape.claims(.canvas, at: 1, local: false, frontUsesEscape: { false }), "the newest, the canvas, is")
        escape.pop(.canvas)
        check(!escape.claims(.layer, at: 1, local: false, frontUsesEscape: { false }), "the same press doesn't stop the next one too")
        check(!escape.claims(.layer, at: 2, local: false, frontUsesEscape: { true }), "a dialog or full screen in front keeps its Esc")
        check(escape.claims(.layer, at: 3, local: true, frontUsesEscape: { true }), "Esc in Cookie's own window is Cookie's")
        escape.push(.scene)
        escape.push(.layer)
        check(escape.stack == [.scene, .layer], "pushed again, a surface becomes the newest")
        check(["CookieLayers.swift", "CookieCanvas.swift", "CookieLessonFromScreen.swift", "CookieSceneView.swift", "CookieCardView.swift"]
            .allSatisfy { source($0).contains("CookieEscape.shared.claims(") }, "every Esc-able surface asks the stack")
        check(source("CookieLayers.swift").contains("idle: { harness.shutdown() }") && source("CookieCanvas.swift").contains("idle: { harness.shutdown() }"),
              "the layer's and canvas's helpers shut down when they're done")
        let all: Set<CookieNotchStack.Slot> = [.layer, .canvas, .proof]
        check(CookieNotchStack.offset(.layer, showing: all) == 0 && CookieNotchStack.offset(.canvas, showing: all) == 26
              && CookieNotchStack.offset(.proof, showing: all) == 52 && CookieNotchStack.offset(.proof, showing: [.proof]) == 0
              && CookieNotchStack.offset(.proof, showing: [.layer, .proof]) == 26, "each pill a row lower than the ones above it")

        print("\(checks) layer checks passed.")
    }
}
