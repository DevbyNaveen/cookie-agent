import Foundation

@MainActor
enum CookieDepthTests {
    static func run() async {
        var checks = 0
        checks += deepAsksAreRecognised()
        checks += everythingElseStaysInstant()
        checks += depthByDefaultWidensOnlyToExplanations()
        checks += normalTurnsDoNotGainTheTeachingArc()
        checks += researchIsRecordedAndOnlyReadSourcesAreKept()
        checks += whereIsThatFromIsAnsweredFromTheShelf()
        checks += runsAskToCloseWithAnAnswer()
        checks += await theResearchStopsAtItsDeadline()
        checks += await theLeadIsSaidAndTheFirstVisualSettlesWhileStreaming()
        print("\(checks) depth checks passed.")
    }

    private static func deepAsksAreRecognised() -> Int {
        let deep = [
            "explain how a jet engine works in depth",
            "Can you explain how photosynthesis works?",
            "teach me about black holes",
            "deep dive into how the stock market works",
            "Why does ice float on water?",
            "why do cats purr",
            "walk me through how vaccines train the immune system",
            "How does a transistor work?",
            "how do noise cancelling headphones work",
            "Hey Cookie, explain why the sky is blue",
            "I want to understand how compound interest works",
            "help me understand recursion",
            "what actually happens when you type a url into a browser",
            "explain the french revolution in detail",
            "could you go deep on how tcp handshakes work",
            "teach me how neural networks learn",
            "I don’t get how mortgages work",
            "explain to me why interest rates affect inflation",
            "explain thoroughly what a hash map is",
            "please walk me through the causes of the first world war",
        ]
        for text in deep { precondition(CookieDepth.isDeep(text), "deep: \(text)") }
        // Follow-ups ask for more only after an answer.
        let followUps = ["tell me more", "say more", "can you elaborate on that?", "why?", "explain that further", "more detail please"]
        for text in followUps {
            precondition(CookieDepth.isDeep(text, recent: ["what is dns"]), "follow-up: \(text)")
            precondition(!CookieDepth.isDeep(text), "no answer to follow: \(text)")
        }
        precondition(CookieDepth.isDeep("and what about a rocket?", recent: ["how does a jet engine work"]))
        precondition(!CookieDepth.isDeep("and what about tomorrow?", recent: ["what's the weather"]))
        return deep.count + followUps.count * 2 + 2
    }

    private static func everythingElseStaysInstant() -> Int {
        let instant = [
            // Short facts.
            "what time is it", "what's the capital of france", "who wrote hamlet", "how tall is mount everest",
            "when did world war two end", "what's seventeen times twenty three", "how many ounces in a pound",
            "is it going to rain tomorrow", "define ephemeral", "thanks", "hello",
            // Doing things.
            "open safari", "send it to anna", "can you open system settings", "write a reply to this email explaining why I'm late",
            "remind me tomorrow to explain how the build works", "search the web for how solar panels work",
            "make a spreadsheet of my expenses", "turn on dark mode", "play some music", "set a timer for ten minutes",
            // How-to tutorials keep Cookie's guided steps.
            "how do i export a pdf", "teach me how to make a pivot table", "walk me through this", "explain how to reset my password",
            // Asked short.
            "quickly, how does a jet engine work?", "short answer: why does ice float", "in a nutshell, explain how vaccines work",
            "explain how dns works in depth but keep it short",
            // About Cookie, the sources, or the screen.
            "why did you do that", "why do you think that", "where's that from?", "what's this button", "point at the share button",
        ]
        for text in instant {
            precondition(!CookieDepth.isDeep(text), "instant: \(text)")
            precondition(!CookieDepth.isDeep(text, recent: ["how does a jet engine work"], byDefault: false) || text.hasPrefix("and"), "instant after a deep turn: \(text)")
        }
        return instant.count * 2
    }

    private static func depthByDefaultWidensOnlyToExplanations() -> Int {
        let deep = ["why is the sky blue", "how do magnets attract each other", "what is photosynthesis", "what are black holes"]
        let instant = ["what's the capital of france", "what is the capital of france", "how many people live in tokyo",
                       "quickly, why is the sky blue", "open safari", "how do i turn on bluetooth", "thanks", "what is this",
                       "give me a short answer: how do magnets work"]
        for text in deep {
            precondition(CookieDepth.isDeep(text, byDefault: true), "by default: \(text)")
            precondition(!CookieDepth.isDeep(text), "off by default: \(text)")
        }
        for text in instant { precondition(!CookieDepth.isDeep(text, byDefault: true), "instant by default: \(text)") }
        precondition(!UserDefaults.standard.bool(forKey: CookieDepth.byDefaultKey) || CookieDepth.byDefault, "the setting reads its key")
        return deep.count * 2 + instant.count + 1
    }

    private static func normalTurnsDoNotGainTheTeachingArc() -> Int {
        let system = CompanionManager.companionVoiceResponseSystemPrompt
        let normalSpoken = CompanionManager.turnNote(deep: false, spoken: true)
        let normalTyped = CompanionManager.turnNote(deep: false, spoken: false)
        let deepSpoken = CompanionManager.turnNote(deep: true, spoken: true)
        let deepTyped = CompanionManager.turnNote(deep: true, spoken: false)
        for text in [system, normalSpoken, normalTyped] + ["answer", "lesson", "screen", "work"].compactMap({ CookieRequestMode(rawValue: $0)?.guidance }) {
            precondition(!text.contains("misconception") && !text.contains("analogy") && !text.contains("SOURCE"), "a normal turn has no teaching arc")
        }
        precondition(normalSpoken == CompanionManager.spokenTurnNote && normalTyped.isEmpty)
        precondition(!system.contains("no length limit") && system.contains("deep explain"), "the old go-all-out rule became one pointer to the arc")
        precondition(deepTyped == CookieDepth.instruction && deepSpoken == CookieDepth.instruction + CookieDepth.spokenNote)
        precondition(!deepSpoken.contains(CompanionManager.spokenTurnNote), "the deep turn's spoken note replaces the normal one")
        // The arc, in its order, and the early picture.
        let arc = CookieDepth.instruction
        let order = ["answer in one sentence", "first visual tag right after that sentence", "analogy", "structure", "step by step", "misconception", "recap"]
        let places = order.map { arc.range(of: $0)?.lowerBound }
        precondition(places.allSatisfy { $0 != nil } && zip(places, places.dropFirst()).allSatisfy { $0! < $1! }, "the arc in order")
        precondition(arc.contains("twenty seconds") && arc.contains("[SOURCE:") && arc.contains("never one from memory"))
        precondition(CookieDepth.spokenNote.contains(CookieDepth.lead.lowercased()))
        return 9
    }

    private static func researchIsRecordedAndOnlyReadSourcesAreKept() -> Int {
        let proof = CookieProof(file: nil)
        let turn = CookieDepthTurn(proof: proof)
        precondition(turn.toolStarted("web_search") && turn.toolStarted("fetch_page") && !turn.toolStarted("build_visual"))
        precondition(proof.entries.count == 2 && proof.entries.allSatisfy { $0.kind == .acted && $0.feature == "research" })
        precondition(proof.entries.first?.summary == "read a web page for your question" && proof.entries.first?.destination == "the web")
        let reply = """
        a jet engine squeezes air, burns it with fuel and throws it out the back. [CARD {"kind":"flow","title":"inside a jet engine","nodes":[{"id":"f","label":"fan"},{"id":"c","label":"compressor"}],"edges":[{"from":"f","to":"c"}]}] think of a bicycle pump that never stops. [NEXT:where's that from?] [SOURCE:https://www.grc.nasa.gov/www/k-12/airplane/turbine.html How a turbine engine works] [SOURCE:not an address] [SOURCE:https://www.grc.nasa.gov/www/k-12/airplane/turbine.html again] [SOURCE:file:///etc/passwd]
        """
        let tagged = CookieReplyTags.split(reply)
        precondition(!tagged.spoken.contains("SOURCE") && !tagged.spoken.contains("nasa") && tagged.spoken.hasSuffix("never stops."), tagged.spoken)
        let kept = turn.record(from: tagged.tags)
        precondition(kept.record.sources == [CookieDepth.Source(url: URL(string: "https://www.grc.nasa.gov/www/k-12/airplane/turbine.html")!,
                                                                  title: "How a turbine engine works")] && kept.leftOut == 0)
        precondition(kept.record.sources[0].host == "grc.nasa.gov" && !kept.record.usedMemory)
        precondition(proof.entries.first?.summary == "answered from 1 source" && proof.entries.first?.destination == "grc.nasa.gov")
        // An address the model wrote without reading the web this turn is left out, and said.
        let unread = CookieDepthTurn(proof: proof)
        unread.toolStarted("recall")
        let claimed = unread.record(from: CookieReplyTags.split("it is so. [SOURCE:https://example.com/a made up]").tags)
        precondition(claimed.record.sources.isEmpty && claimed.leftOut == 1 && claimed.record.usedMemory)
        precondition(proof.entries.first?.destination == "Enkeon", "recall is recorded, the made-up source is not")
        return 9
    }

    private static func whereIsThatFromIsAnsweredFromTheShelf() -> Int {
        let shelf = CookieSourceShelf()
        let thread = UUID(), other = UUID()
        let source = CookieDepth.Source(url: URL(string: "https://en.wikipedia.org/wiki/Jet_engine")!, title: "Jet engine")
        shelf.keep(.init(sources: [source], usedMemory: false), thread: thread)
        precondition(shelf.record(thread: other) == nil && shelf.record(thread: thread)?.sources == [source])
        let listed = CookieDepth.sourcesNote(shelf.record(thread: thread))
        precondition(listed.contains("https://en.wikipedia.org/wiki/Jet_engine") && listed.contains("never add one that isn't listed"))
        let none = CookieDepth.sourcesNote(shelf.record(thread: other))
        precondition(none.contains("recorded no web sources") && none.contains("never name a source"))
        precondition(CookieDepth.sourcesNote(.init(sources: [], usedMemory: true)).contains("Enkeon notes"))
        for _ in 0..<CookieSourceShelf.capacity { shelf.keep(.init(sources: [], usedMemory: false), thread: UUID()) }
        precondition(shelf.record(thread: thread) == nil, "the shelf is bounded")
        let asks = ["where's that from?", "Where did you get that?", "what are your sources", "sources?", "how do you know that"]
        for text in asks { precondition(CookieDepth.asksForSources(text), text) }
        precondition(!CookieDepth.asksForSources("where is the share button") && !CookieDepth.asksForSources("open the source file"))
        return 6 + asks.count + 1
    }

    private static func runsAskToCloseWithAnAnswer() -> Int {
        func line<T: Encodable>(_ value: T) -> String { String(decoding: HarnessWire.encode(value), as: UTF8.self) }
        let normal = line(HarnessRequest.Run(id: "r", model: "x:y", input: "hi", instructions: "", tools: [], images: [], history: [], enkeon: false))
        let deep = line(HarnessRequest.Run(id: "r", model: "x:y", input: "hi", instructions: "", tools: [], images: [], history: [], enkeon: false,
                                           close_with_answer: true))
        precondition(!normal.contains("close_with_answer"), "a normal run is byte-for-byte what it was")
        precondition(deep.contains("\"close_with_answer\":true"))
        precondition(line(HarnessRequest.FinishTurn()) == "{\"type\":\"finish_turn\"}\n")
        return 3
    }

    private static func theResearchStopsAtItsDeadline() async -> Int {
        let proof = CookieProof(file: nil)
        let slow = CookieDepthTurn(proof: proof)
        var finished = 0
        _ = slow.watch(seconds: 0.05) { finished += 1 }
        slow.toolStarted("web_search")
        await waitUntil { finished == 1 }
        precondition(slow.cutShort)
        // Words have started: the answer is under way and is left alone.
        let talking = CookieDepthTurn(proof: proof)
        var stopped = 0
        _ = talking.watch(seconds: 0.05) { stopped += 1 }
        talking.wordsArrived()
        // Esc or the person speaking cancels the turn, and its deadline with it.
        let cancelled = CookieDepthTurn(proof: proof)
        let watch = cancelled.watch(seconds: 0.05) { stopped += 1 }
        watch.cancel()
        try? await Task.sleep(for: .milliseconds(150))
        precondition(stopped == 0 && !talking.cutShort && !cancelled.cutShort)
        precondition(CookieDepth.researchSeconds == 20)
        return 3
    }

    private static func theLeadIsSaidAndTheFirstVisualSettlesWhileStreaming() async -> Int {
        let output = DepthPlayback()
        let speaker = CookieSpeaker(makeLocal: { _ in output }, sourceProvider: { nil })
        var settled: [CookieReplyTag] = []
        speaker.beginReply(onTags: { settled += $0 })
        speaker.acknowledge(CookieDepth.lead)
        await waitUntil { output.asides == [CookieDepth.lead + " "] }
        // The research's tool rounds don't add "One moment." on top.
        speaker.toolStarted()
        speaker.toolStarted()
        precondition(output.asides.count == 1 && output.words.isEmpty, "the lead is said once, aside from the reply")
        // The answer's first sentence and its card: the card settles (and is prepared on the clock)
        // while the rest is still being written, not when the reply ends.
        let first = "a jet engine squeezes air, burns it and throws it out the back."
        speaker.update(first + " [CARD {\"kind\":\"flow\",\"title\":\"inside\",\"nodes\":[{\"id\":\"a\",\"label\":\"fan\"},{\"id\":\"b\",\"label\":\"turbine\"}],\"edges\":[{\"from\":\"a\",\"to\":\"b\"}]}] think of a bicycle pu")
        precondition(settled.map(\.kind) == ["CARD"] && settled[0].offset == first.utf16.count + 1, "the first visual is placed at the end of the first sentence")
        precondition(CookieCard(tag: settled[0]) != nil, "and it is a card Cookie can show")
        precondition(output.words.hasPrefix(first) && output.finishes == 0, "spoken before the reply finished")
        // A lead after the reply's words began would talk over them: never.
        speaker.acknowledge("again")
        precondition(output.asides.count == 1)
        speaker.stopPlayback()
        return 5
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        precondition(condition(), "timed out")
    }
}

private final class DepthPlayback: CookieSpeechPlayback {
    var onStarted: (() -> Void)?
    var onProgress: ((_ spokenOffset: Int) -> Void)?
    var onFinished: (() -> Void)?
    var onFailed: ((_ resumeFrom: Int) -> Void)?
    var words = ""
    var asides: [String] = []
    var finishes = 0
    func open() {}
    func speakAside(_ words: String) { asides.append(words) }
    func speak(_ words: String, flush: Bool) { self.words += words }
    func finish() { finishes += 1 }
    func stop() {}
}
