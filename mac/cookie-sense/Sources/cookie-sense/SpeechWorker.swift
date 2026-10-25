//
//  SpeechWorker.swift
//  cookie-sense
//
//  Push-to-talk transcription with SpeechAnalyzer and SpeechTranscriber
//  (macOS 26+), on this Mac: volatile results while the person talks, then
//  `finalizeAndFinishThroughEndOfInput` when the key comes up, which
//  finalizes what is still volatile. Audio arrives from Cookie as 16 kHz mono
//  16-bit samples (Cookie holds the microphone) and is converted to the
//  analyzer's own best format here. On macOS 15, or a language without an
//  installed model, it says it isn't available and Cookie uses its own
//  recognizer.
//

import AVFoundation
import Foundation
import Speech

final class SpeechWorker: @unchecked Sendable {
    /// What Cookie sends: 16 kHz mono 16-bit little-endian PCM.
    static let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    private let lock = NSLock()
    /// Sessions by the id Cookie gave `speech.start`; `Any` keeps the macOS 26 type out of the signature.
    private var sessions: [String: Any] = [:]

    func isAvailable() async -> Bool {
        guard #available(macOS 26, *) else { return false }
        return await SpeechSession.modelInstalled(for: Locale.current) != nil
    }

    func start(id: String, locale: String) async {
        guard #available(macOS 26, *) else { return Wire.fail(id, "SpeechAnalyzer needs macOS 26") }
        do {
            let session = try await SpeechSession(id: id, locale: Locale(identifier: locale))
            lock.withLock { sessions[id] = session }
            Wire.reply(id, ["ok": true])
        } catch {
            Wire.fail(id, "\(error)")
        }
    }

    /// Called on the reader thread, in the order the audio arrived.
    func audio(id: String, pcm16: Data) {
        guard #available(macOS 26, *) else { return }
        let session = lock.withLock { sessions[id] } as? SpeechSession
        session?.append(pcm16)
    }

    func finish(id: String) async {
        guard #available(macOS 26, *) else { return }
        guard let session = lock.withLock({ sessions.removeValue(forKey: id) }) as? SpeechSession else {
            return Wire.fail(id, "no such session")
        }
        await session.finish()
    }

    func cancel(id: String) async {
        guard #available(macOS 26, *) else { return }
        let session = lock.withLock { sessions.removeValue(forKey: id) } as? SpeechSession
        await session?.cancel()
    }
}

@available(macOS 26, *)
final class SpeechSession: @unchecked Sendable {
    private let id: String
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let converter: AVAudioConverter
    private let analyzerFormat: AVAudioFormat
    private var results: Task<Void, Never>?
    private let lock = NSLock()
    /// Finalized text so far, and the volatile guess after it.
    private var finalized = ""
    private var volatile = ""

    /// The locale's transcriber when its model is installed; nil otherwise (installing it is asked
    /// for, so a later session can use it).
    static func modelInstalled(for locale: Locale) async -> Locale? {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return supported
        case .supported, .downloading:
            Task.detached {
                guard let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
                do { try await request.downloadAndInstall(); log("speech model for \(supported.identifier) installed") }
                catch { log("speech model for \(supported.identifier) didn't install: \(error)") }
            }
            return nil
        default:
            return nil
        }
    }

    init(id: String, locale: Locale) async throws {
        guard let supported = await Self.modelInstalled(for: locale) else {
            throw NSError(domain: "cookie-sense", code: 1, userInfo: [NSLocalizedDescriptionKey: "no installed speech model for \(locale.identifier)"])
        }
        self.id = id
        transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let converter = AVAudioConverter(from: SpeechWorker.inputFormat, to: format) else {
            throw NSError(domain: "cookie-sense", code: 2, userInfo: [NSLocalizedDescriptionKey: "no audio format for the analyzer"])
        }
        analyzerFormat = format
        self.converter = converter
        analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        input = continuation
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
        let transcriber = self.transcriber
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.take(String(result.text.characters), final: result.isFinal)
                }
            } catch {
                log("speech results ended: \(error)")
            }
        }
    }

    private func take(_ text: String, final: Bool) {
        let whole: String = lock.withLock {
            if final {
                finalized += text
                volatile = ""
            } else {
                volatile = text
            }
            return finalized + volatile
        }
        Wire.send(["id": id, "event": "volatile", "text": whole])
    }

    func append(_ pcm16: Data) {
        let frames = AVAudioFrameCount(pcm16.count / 2)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: SpeechWorker.inputFormat, frameCapacity: frames),
              let samples = buffer.int16ChannelData?[0] else { return }
        buffer.frameLength = frames
        pcm16.withUnsafeBytes { raw in
            for index in 0..<Int(frames) {
                samples[index] = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
            }
        }
        let ratio = analyzerFormat.sampleRate / SpeechWorker.inputFormat.sampleRate
        guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: AVAudioFrameCount(Double(frames) * ratio) + 32) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0 else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    /// The key came up: what is volatile is finalized, then the whole text goes back.
    func finish() async {
        input.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            log("speech finish: \(error)")
        }
        await results?.value
        let text = lock.withLock { finalized + volatile }
        Wire.send(["id": id, "event": "final", "text": text])
    }

    func cancel() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
        results?.cancel()
    }
}
