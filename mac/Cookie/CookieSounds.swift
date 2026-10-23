//
//  CookieSounds.swift
//  Cookie
//
//  Cookie's little sounds: open, close, send, done, listen. macOS's own UI
//  sounds where this Mac has them, with a synthesized tone as the fallback.
//  The General setting "Sounds" turns them off.
//

import AVFoundation
import Foundation

enum CookieSound: String, CaseIterable {
    case open, close, send, done, listen
    /// The notch peeking open and closing: a water drop up, a plop down.
    case bloop, plop

    /// A tone: from one pitch to another (a glide when they differ), when it
    /// starts, how long it lasts, and how much second harmonic gives it edge.
    struct Tone {
        let from: Double, to: Double, start: Double, length: Double
        var harmonic: Double = 0
        /// A water drop's pitch rises by ratio, not by step: an exponential glide.
        var exponential = false
    }

    /// Open and close are one clean sine each, sliding up or down. The rest
    /// are short notes on Cookie's chord (C5 E5 G5 C6) with a touch of edge.
    fileprivate var tones: [Tone] {
        let c5 = 523.25, e5 = 659.25, g5 = 783.99, c6 = 1046.50, a5 = 880.0, e6 = 1318.51
        switch self {
        case .open: return [Tone(from: 440, to: 660, start: 0, length: 0.32)]
        case .close: return [Tone(from: 660, to: 440, start: 0, length: 0.30)]
        case .send: return [Tone(from: e6, to: e6, start: 0, length: 0.09, harmonic: 0.2)]
        case .done: return [Tone(from: c5, to: c5, start: 0, length: 0.22, harmonic: 0.15),
                            Tone(from: e5, to: e5, start: 0.09, length: 0.22, harmonic: 0.15),
                            Tone(from: g5, to: g5, start: 0.18, length: 0.22, harmonic: 0.15),
                            Tone(from: c6, to: c6, start: 0.27, length: 0.42, harmonic: 0.15)]
        case .listen: return [Tone(from: a5, to: a5, start: 0, length: 0.14)]
        case .bloop: return [Tone(from: 320, to: 1100, start: 0, length: 0.13, harmonic: 0.08, exponential: true)]
        case .plop: return [Tone(from: 700, to: 260, start: 0, length: 0.16, harmonic: 0.08, exponential: true)]
        }
    }
}

@MainActor
enum CookieSounds {
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: CK.Key.sounds) == nil || UserDefaults.standard.bool(forKey: CK.Key.sounds)
    }

    private static var players: [CookieSound: AVAudioPlayer] = [:]

    /// macOS's own UI sounds, the ones the system plays for screen recording,
    /// a sent message, Apple Pay and the microphone: clean, mastered, familiar.
    /// ponytail: read from the system at runtime; bundle Cookie's own recordings for release.
    private static let systemSoundsDirectory = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
    private static func systemFile(for sound: CookieSound) -> URL? {
        let name: String
        switch sound {
        case .open: name = "begin_record.caf"
        case .close: name = "end_record.caf"
        case .send: name = "SentMessage.caf"
        case .done: name = "payment_success.aif"
        case .listen: name = "mic_unmute.caf"
        case .bloop, .plop: return nil // Cookie's own water drops; no system file sounds like them.
        }
        let url = URL(fileURLWithPath: systemSoundsDirectory + name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func play(_ sound: CookieSound) {
        guard enabled else { return }
        if players[sound] == nil {
            // The system file when this Mac has it; Cookie's own tone otherwise.
            players[sound] = systemFile(for: sound).flatMap { try? AVAudioPlayer(contentsOf: $0) }
                ?? (try? AVAudioPlayer(data: wave(sound), fileTypeHint: AVFileType.wav.rawValue))
            players[sound]?.volume = 0.5
        }
        guard let player = players[sound] else { return }
        player.currentTime = 0
        player.play()
    }

    /// 16-bit mono WAV of the sound's tones: a 20 ms attack, a cosine fade over
    /// the last half so nothing clicks, and the phase integrated so glides stay smooth.
    static func wave(_ sound: CookieSound) -> Data {
        let rate = 44_100.0
        let tones = sound.tones
        let total = tones.map { $0.start + $0.length }.max() ?? 0.1
        let count = Int(total * rate)
        var samples = [Double](repeating: 0, count: count)
        for tone in tones {
            let from = Int(tone.start * rate), to = min(count, Int((tone.start + tone.length) * rate))
            var phase = 0.0
            for index in from..<to {
                let t = Double(index - from) / rate
                let progress = t / tone.length
                let hertz = tone.exponential ? tone.from * pow(tone.to / tone.from, progress)
                                             : tone.from + (tone.to - tone.from) * progress
                phase += 2 * Double.pi * hertz / rate
                let attack = min(1, t / 0.02)
                let fade = progress < 0.5 ? 1 : 0.5 * (1 + cos(Double.pi * (progress - 0.5) / 0.5))
                samples[index] += 0.2 * attack * fade * (sin(phase) + tone.harmonic * sin(2 * phase))
            }
        }
        var pcm = Data(capacity: count * 2)
        for sample in samples {
            let clipped = max(-1, min(1, sample))
            var value = Int16(clipped * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        func chunk(_ tag: String) { data.append(contentsOf: Array(tag.utf8)) }
        func uint32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func uint16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        chunk("RIFF"); uint32(UInt32(36 + pcm.count)); chunk("WAVE")
        chunk("fmt "); uint32(16); uint16(1); uint16(1); uint32(UInt32(rate)); uint32(UInt32(rate) * 2); uint16(2); uint16(16)
        chunk("data"); uint32(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}
