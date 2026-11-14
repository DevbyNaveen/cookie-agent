import AVFoundation
import Foundation

/// Capture health is independent of recognition: missing buffers are not silence.
struct DictationAudioSnapshot {
    var frames = 0
    var sumSquares: Double = 0
    var samples = 0
    var peak: Float = 0
    var rms: Double { samples == 0 ? 0 : sqrt(sumSquares / Double(samples)) }
    var emptyTranscriptMessage: String {
        if frames == 0 { return "The microphone supplied no audio. Check your input device and try again." }
        if peak == 0 { return "The microphone supplied silent audio. Check whether your input is muted." }
        return "Speech wasn't recognized. Your text is unchanged."
    }
}

protocol DictationAudioInput: AnyObject {
    var snapshot: DictationAudioSnapshot { get }
    func start(receive: @escaping (AVAudioPCMBuffer) -> Void) async throws
    func stop()
}

final class MicrophoneAudioInput: DictationAudioInput {
    private var engine: AVAudioEngine?
    private let captureQueue = DispatchQueue(label: "com.enkeon.microphone", qos: .userInitiated)
    private let lock = NSLock()
    private var stats = DictationAudioSnapshot()
    var snapshot: DictationAudioSnapshot { lock.withLock { stats } }

    func start(receive: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            captureQueue.async { [self] in
                do { try startEngine(receive: receive); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func startEngine(receive: @escaping (AVAudioPCMBuffer) -> Void) throws {
        stopEngine()
        lock.withLock { stats = DictationAudioSnapshot() }
        // Resolve the current input route each time, rather than reuse a stopped engine's route.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AppleSpeechTranscriptionProviderError(message: "No usable microphone input is available. Check your input device.")
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            var energy: Double = 0
            var peak: Float = 0
            let frames = Int(buffer.frameLength)
            if let samples = buffer.floatChannelData?[0] {
                for index in 0..<frames {
                    let sample = samples[index * buffer.stride]
                    energy += Double(sample) * Double(sample)
                    peak = max(peak, abs(sample))
                }
            }
            self?.lock.withLock {
                self?.stats.frames += frames
                self?.stats.samples += frames
                self?.stats.sumSquares += energy
                self?.stats.peak = max(self?.stats.peak ?? 0, peak)
            }
            receive(buffer)
        }
        self.engine = engine
        do {
            engine.prepare()
            try engine.start()
            print("🎙️ Microphone: \(Int(format.sampleRate)) Hz, \(format.channelCount) channel(s)")
        } catch { stopEngine(); throw error }
    }

    func stop() {
        captureQueue.async { [self] in stopEngine() }
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        let value = snapshot
        print("🎙️ Microphone: \(value.frames) frames, RMS \(value.rms), peak \(value.peak)")
    }
}

/// Captures the beginning of an utterance while the recognizer session opens.
/// The lock orders attach/finish against audio callbacks, including a release during startup.
final class PendingDictationAudio {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var duration: Double = 0
    private var session: (any BuddyStreamingTranscriptionSession)?
    private var finished = false
    private var cancelled = false
    private var overflow = false

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !finished, !cancelled else { return }
            if let session { session.appendAudioBuffer(buffer); return }
            guard !overflow else { return }
            duration += Double(buffer.frameLength) / buffer.format.sampleRate
            guard duration <= 6, let copy = buffer.dictationCopy() else {
                overflow = true; buffers.removeAll(); return
            }
            buffers.append(copy)
        }
    }

    func attach(_ session: any BuddyStreamingTranscriptionSession) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            guard !overflow else {
                throw AppleSpeechTranscriptionProviderError(message: "Speech took too long to start. Nothing was pasted. Try again.")
            }
            self.session = session
            buffers.forEach { session.appendAudioBuffer($0) }
            buffers.removeAll()
            if finished { session.requestFinalTranscript() }
        }
    }

    func finish() {
        lock.withLock {
            guard !finished, !cancelled else { return }
            finished = true
            session?.requestFinalTranscript()
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            buffers.removeAll()
            session = nil
        }
    }
}
