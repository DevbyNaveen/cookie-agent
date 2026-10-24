//
//  CookieSpeechClock.swift
//  Cookie
//
//  Which character of a reply is being heard now, whichever voice speaks it.
//

import Foundation

/// The one clock both voices feed: ElevenLabs from its per-character start
/// times (streamed with each audio chunk) against the audio player's position,
/// the Mac's voice from `AVSpeechSynthesizer`'s `willSpeakRangeOfSpeechString`
/// word callbacks. A streamed reply's text grows while it is spoken (`setText`).
///
/// Offsets are UTF-16 offsets into the text being spoken (`NSString`/`NSRange`
/// units — what the synthesizer reports), so a parser that strips tags from a
/// reply keeps each tag's offset in the spoken text in the same units.
///
/// Use it to do something when speech reaches a place in the text, for example
/// draw a mark as the word naming it is said:
///
///     speaker.beginReply(onTags: { tags in
///         for mark in marks(tags) { clock.schedule(atOffset: mark.offset) { show(mark) } }
///     })
///
/// - `schedule(atOffset:_:)` runs the action on the main actor once
///   `spokenOffset` reaches the offset. An offset already reached runs at once
///   (synchronously, inside `schedule`). Actions for one offset run in the
///   order they were scheduled.
/// - When speech is heard to the end, every action still waiting runs, in
///   offset order (the last word's start is the last offset a voice reports).
/// - When speech is stopped or interrupted (Stop, Escape, the hotkey pressed
///   to talk over Cookie, a new reply), every waiting action is dropped.
/// - Anything scheduled while nothing is speaking waits for the speech to begin;
///   `CookieSpeaker.beginReply` stops the previous speech first, which drops it,
///   so schedule after `beginReply` (a streamed reply's tags arrive before its
///   first sound) or from `onPlaybackStarted`.
///
/// The voice reports about 60 times a second (ElevenLabs) or once a word
/// (the Mac's voice); `spokenOffset` only moves forward.
@MainActor
final class CookieSpeechClock {
    /// A handle for `cancel(_:)`.
    struct Scheduled: Hashable {
        fileprivate let id: Int
    }

    private struct Waiting {
        let id: Int
        let offset: Int
        let action: @MainActor () -> Void
    }

    /// The text being spoken; empty when nothing is.
    private(set) var text = ""
    private(set) var isSpeaking = false
    /// The UTF-16 offset in `text` being spoken now (the start of the current word for the Mac's voice).
    private(set) var spokenOffset = 0
    /// How much of the reply has been heard, 0...1.
    private(set) var progress = 0.0

    private var waiting: [Waiting] = []
    private var nextID = 0

    @discardableResult
    func schedule(atOffset offset: Int, _ action: @escaping @MainActor () -> Void) -> Scheduled {
        nextID += 1
        let scheduled = Scheduled(id: nextID)
        if isSpeaking && offset <= spokenOffset {
            action()
        } else {
            waiting.append(Waiting(id: nextID, offset: offset, action: action))
        }
        return scheduled
    }

    func cancel(_ scheduled: Scheduled) {
        waiting.removeAll { $0.id == scheduled.id }
    }

    // MARK: Fed by CookieSpeaker

    func begin(text: String) {
        self.text = text
        isSpeaking = true
        spokenOffset = 0
        progress = 0
        runWaiting(through: 0)
    }

    /// More of the reply's words arrived while it is being spoken.
    func setText(_ text: String) {
        guard isSpeaking else { return }
        self.text = text
    }

    func advance(toOffset offset: Int, progress: Double) {
        guard isSpeaking else { return }
        self.progress = max(self.progress, min(1, max(0, progress)))
        guard offset > spokenOffset else { return }
        spokenOffset = offset
        runWaiting(through: offset)
    }

    /// Heard to the end.
    func finish() {
        guard isSpeaking else { return }
        progress = 1
        spokenOffset = max(spokenOffset, text.utf16.count)
        runWaiting(through: .max)
        stop()
    }

    /// Stopped, interrupted or done: nothing waiting runs.
    func stop() {
        waiting = []
        isSpeaking = false
        text = ""
        spokenOffset = 0
        progress = 0
    }

    private func runWaiting(through offset: Int) {
        // Stable: same offset keeps scheduling order. An action may schedule or stop; re-check each time.
        while isSpeaking, let index = waiting.indices.filter({ waiting[$0].offset <= offset })
                .min(by: { (waiting[$0].offset, waiting[$0].id) < (waiting[$1].offset, waiting[$1].id) }) {
            let due = waiting.remove(at: index)
            due.action()
        }
    }
}
