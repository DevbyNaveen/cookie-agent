//
//  CookieSpeechStream.swift
//  Cookie
//
//  The arithmetic of speaking a reply while it is still being written, kept
//  free of audio and sockets so each piece can be checked on its own:
//
//  CookieSpokenStream    — which words of the reply so far may go to the
//                          voice now (whole words, never part of a tag), and
//                          which tags have settled with their place in them.
//  CookieAlignmentMapper — ElevenLabs' per-chunk alignment, back to offsets in
//                          the text Cookie sent.
//  CookieAudioTimeline   — the audio heard so far, in the voice's own time,
//                          across gaps where the next chunk arrived late.
//

import Foundation

/// The reply as it streams, split into what the voice may say now and the tags in it.
///
/// `CookieReplyTags.split(streaming: true)` already stops at a "[" that may still become a
/// tag, so a half-written tag never reaches the voice; this keeps track of how much of
/// its spoken text has been handed on. Only whole words go (up to the last space): the
/// word being written may still grow, and ElevenLabs wants every message to end with a
/// space. A tag's offset is final once words follow it, or the reply is done — until
/// then trimming can still move it (the tag at the very end sits past the trimmed text).
struct CookieSpokenStream {
    /// The spoken text so far (tags out), as `split` gives it.
    private(set) var spoken = ""
    /// UTF-16 units of `spoken` handed to the voice.
    private(set) var released = 0
    /// Every tag settled so far, in order.
    private(set) var settledTags: [CookieReplyTag] = []
    private(set) var isFinished = false

    /// Takes the whole reply so far; returns the words to speak next (may be empty) and the
    /// tags that settled with this update. `final` when the reply is complete.
    mutating func update(_ reply: String, final: Bool = false) -> (words: String, tags: [CookieReplyTag]) {
        guard !isFinished else { return ("", []) }
        let split = CookieReplyTags.split(reply, streaming: !final)
        spoken = split.spoken
        isFinished = final
        let units = Array(spoken.utf16)
        // ponytail: a reply only grows, so the spoken text keeps its prefix; if it ever didn't,
        // what was already said stays said and the voice carries on from the same place.
        var end = released
        if final {
            end = units.count
        } else if let lastSpace = units.lastIndex(where: Self.isSpace), lastSpace + 1 > released {
            end = lastSpace + 1
        }
        var words = ""
        if end > released {
            words = String(utf16CodeUnits: Array(units[released..<end]), count: end - released)
            released = end
        }
        let newTags = split.tags.dropFirst(settledTags.count).prefix { final || $0.offset < units.count }
        settledTags += newTags
        return (words, Array(newTags))
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D
    }

    /// Whether the voice should be made to start now instead of waiting for its buffer to
    /// fill: once the words released so far hold a first clause (a ", ; : . ! ? —" after at
    /// least 24 characters) or 80 characters without one. After that, the voice's own schedule
    /// batches larger pieces, which keeps the intonation natural.
    static func holdsFirstClause(_ releasedText: String) -> Bool {
        var count = 0
        var previous: Character?
        for character in releasedText {
            if let previous, character.isWhitespace, ",;:.!?—".contains(previous), count >= 24 { return true }
            previous = character
            count += 1
        }
        return count >= 80
    }
}

/// ElevenLabs' stream-input alignment gives each audio chunk its characters, with start times
/// relative to that chunk. This walks them against the text Cookie sent, in order, so each
/// character gets its offset (UTF-16, as the speech clock counts) in that text.
///
/// The characters are mostly exactly what was sent, but not always: whitespace can differ
/// (a newline heard as a space, a space added at the end) and the voice may skip or add a
/// character. So whitespace matches whitespace loosely, and a character that doesn't match
/// is looked for a few characters ahead before it is given up on (it then has no offset;
/// the clock simply moves at the next one that matches).
struct CookieAlignmentMapper {
    private var characters: [(text: String, offset: Int, isSpace: Bool)] = []
    private var cursor = 0
    private var nextOffset = 0
    /// How far ahead an unmatched character is looked for.
    static let lookahead = 8

    /// Text as it was sent to the voice, appended in order.
    mutating func sent(_ text: String) {
        for character in text {
            characters.append((String(character), nextOffset, character.isWhitespace))
            nextOffset += character.utf16.count
        }
    }

    /// UTF-16 length of everything sent.
    var sentLength: Int { nextOffset }
    /// Offset just past the last character the voice has accounted for.
    var alignedThrough: Int { cursor == 0 ? 0 : characters[cursor - 1].offset + characters[cursor - 1].text.utf16.count }

    /// The offset in the sent text of each character the voice reports, nil where none matches.
    mutating func map(_ reported: [String]) -> [Int?] {
        reported.map { character in
            let reportedSpace = character.allSatisfy(\.isWhitespace)
            if reportedSpace {
                // Matches the sent whitespace here, if there is any; never skips words to find one.
                guard cursor < characters.count, characters[cursor].isSpace else { return nil }
                defer { cursor += 1 }
                return characters[cursor].offset
            }
            // Sent whitespace the voice didn't report is passed over.
            while cursor < characters.count, characters[cursor].isSpace { cursor += 1 }
            let limit = min(characters.count, cursor + Self.lookahead)
            guard let found = (cursor..<limit).first(where: { characters[$0].text == character }) else { return nil }
            cursor = found + 1
            return characters[found].offset
        }
    }
}

/// The voice's audio as it is heard. Chunks are played back to back; when the next chunk
/// arrives after the player ran dry, the player's clock has kept going, so the chunk starts
/// later in player time than in audio time. `heard` is in the audio's own time, which is what
/// the alignment's times are in. All counts are in samples.
struct CookieAudioTimeline {
    /// Samples of audio received and scheduled.
    private(set) var scheduled: Int64 = 0
    /// Where audio resumed after the player ran dry: (player sample, audio sample), first at 0.
    private var anchors: [(player: Int64, audio: Int64)] = [(0, 0)]

    /// Player samples that passed with nothing to play, so far.
    var gaps: Int64 { anchors[anchors.count - 1].player - anchors[anchors.count - 1].audio }

    /// A chunk of `frames` samples is scheduled when the player is at `playerSample`
    /// (nil before it starts). Returns where the chunk starts in audio time.
    mutating func schedule(frames: Int64, playerSample: Int64?) -> Int64 {
        let last = anchors[anchors.count - 1]
        let runsOutAt = last.player + (scheduled - last.audio)
        if let playerSample, playerSample > runsOutAt {
            anchors.append((playerSample, scheduled))
        }
        let start = scheduled
        scheduled += frames
        return start
    }

    /// Audio time heard at `playerSample`: never past what was scheduled, and still during a gap.
    func heard(playerSample: Int64) -> Int64 {
        guard let index = anchors.lastIndex(where: { $0.player <= playerSample }) else { return 0 }
        let anchor = anchors[index]
        let limit = index + 1 < anchors.count ? anchors[index + 1].audio : scheduled
        return max(anchor.audio, min(limit, anchor.audio + (playerSample - anchor.player)))
    }
}

/// Character start times (offset in the reply's spoken text, seconds of audio), as they are
/// learnt chunk by chunk; `offset(at:)` is the character being heard at a time.
struct CookieCharacterTimes {
    private(set) var starts: [(offset: Int, seconds: Double)] = []

    mutating func add(offset: Int, seconds: Double) {
        // Ascending in both: a late or repeated character never moves the clock back.
        if let last = starts.last, offset <= last.offset || seconds < last.seconds { return }
        starts.append((offset, seconds))
    }

    /// The offset of the last character that has started by `seconds`, nil before the first.
    func offset(at seconds: Double) -> Int? {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle].seconds <= seconds { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : starts[low - 1].offset
    }
}
