import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// One ordered stream per recording. Model loading is outside the microphone path.
final class ParakeetWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var models: AsrModels?
    private var loading: Task<AsrModels, Error>?
    private var sessions: [String: Session] = [:]

    var ready: Bool { lock.withLock { models != nil } }

    func prepare(id: String, gpu: Bool = false) async {
        let task = lock.withLock { () -> Task<AsrModels, Error> in
            if let loading { return loading }
            let task = Task { () -> AsrModels in
                if gpu {
                    let configuration = MLModelConfiguration()
                    configuration.computeUnits = .cpuAndGPU
                    return try await AsrModels.downloadAndLoad(configuration: configuration, version: .v2, encoderComputeUnits: .cpuAndGPU)
                }
                return try await AsrModels.downloadAndLoad(version: .v2)
            }
            loading = task
            return task
        }
        do {
            let loaded = try await task.value
            lock.withLock { models = loaded }
            Wire.reply(id, ["ok": true, "model": "parakeet-v2"])
        } catch {
            lock.withLock { loading = nil }
            Wire.fail(id, "Parakeet could not load. Check the connection and available disk space.")
            log("Parakeet load failed: \(error)")
        }
    }

    func start(id: String) async {
        guard let models = lock.withLock({ models }) else { return Wire.fail(id, "Parakeet is not ready yet.") }
        let session = Session(id: id)
        guard lock.withLock({ () -> Bool in
            guard sessions.isEmpty else { return false }
            sessions[id] = session
            return true
        }) else { return Wire.fail(id, "Speech is already in use.") }
        do {
            try await session.start(models: models)
            Wire.reply(id, ["ok": true])
        } catch {
            _ = lock.withLock { sessions.removeValue(forKey: id) }
            await session.cancel()
            Wire.fail(id, "Parakeet could not start.")
        }
    }

    func audio(id: String, data: Data) { lock.withLock { sessions[id] }?.append(data) }
    func finish(id: String) async {
        guard let session = lock.withLock({ sessions[id] }) else { return Wire.fail(id, "No such speech session.") }
        await session.finish()
        _ = lock.withLock { sessions.removeValue(forKey: id) }
    }
    func cancel(id: String) async {
        let session = lock.withLock { sessions.removeValue(forKey: id) }
        await session?.cancel()
    }

    /// Evaluation of full-utterance latency, independent of the sliding-window scheduler.
    func transcribe(id: String, data: Data, reply: Bool = false) async {
        guard let models = lock.withLock({ models }), data.count % 2 == 0, data.count <= 8 * 1024 * 1024 else {
            return Wire.fail(id, "Model unavailable or invalid audio.")
        }
        do {
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            let samples: [Float] = data.withUnsafeBytes { raw in
                (0..<(data.count / 2)).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
            }
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(samples, decoderState: &state)
            if reply { Wire.reply(id, ["text": result.text]) }
            else { Wire.send(["id": id, "event": "final", "text": result.text]) }
        } catch { Wire.fail(id, "Parakeet batch evaluation failed: \(error)") }
    }

    private final class Session: @unchecked Sendable {
        let id: String
        // Short dictation needs partial work done before key-up; the SDK's ten-second chunks
        // are intended for long recordings. Keep its validated context window sizes.
        let manager = SlidingWindowAsrManager(config: .init(chunkSeconds: 3, hypothesisChunkSeconds: 1,
            leftContextSeconds: 2, rightContextSeconds: 2, minContextForConfirmation: 3))
        let input: AsyncStream<Data>
        let continuation: AsyncStream<Data>.Continuation
        let lock = NSLock()
        var cancelled = false
        var ended = false
        var bytes = 0
        var failed = false
        var feeder: Task<Void, Never>?
        var updates: Task<Void, Never>?
        var integrity: Task<Void, Never>?

        init(id: String) {
            self.id = id
            (input, continuation) = AsyncStream<Data>.makeStream()
        }

        func start(models: AsrModels) async throws {
            try await manager.loadModels(models)
            // No FluidAudio vocabulary boosting: measured 2026-10-31 it turned "four at 7.30 and" into a
            // Dictionary name. Dictionary words are applied after recognition (NameCorrection) instead.
            guard !lock.withLock({ cancelled }) else { throw CancellationError() }
            // The strict stream fails on missing windows; never paste a partial success.
            let tokens = await manager.tokenUpdates
            let integrity = Task { [weak self] in
                do { for try await _ in tokens { try Task.checkCancellation() } }
                catch { self?.lock.withLock { self?.failed = true } }
            }
            lock.withLock { self.integrity = integrity; if cancelled { integrity.cancel() } }
            let stream = await manager.transcriptionUpdates
            let updates = Task { [weak self] in
                for await _ in stream {
                    guard let self, !Task.isCancelled, !self.lock.withLock({ self.cancelled }) else { return }
                    let confirmed = await self.manager.confirmedTranscript
                    let volatile = await self.manager.volatileTranscript
                    self.lock.withLock {
                        guard !self.cancelled, !self.ended else { return }
                        Wire.send(["id": self.id, "event": "volatile", "text": [confirmed, volatile].filter { !$0.isEmpty }.joined(separator: " ")])
                    }
                }
            }
            lock.withLock { self.updates = updates; if cancelled { updates.cancel() } }
            try await manager.startStreaming()
            guard !lock.withLock({ cancelled }) else { await manager.cancel(); throw CancellationError() }
            let feeder = Task { [input, manager] in
                for await data in input {
                    guard !Task.isCancelled else { return }
                    let count = data.count / 2
                    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
                          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                          let samples = buffer.floatChannelData?[0] else { continue }
                    buffer.frameLength = AVAudioFrameCount(count)
                    data.withUnsafeBytes { raw in
                        for i in 0..<count { samples[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768 }
                    }
                    await manager.streamAudio(buffer)
                }
            }
            lock.withLock { self.feeder = feeder; if cancelled { feeder.cancel() } }
        }

        func append(_ data: Data) {
            lock.withLock {
                guard !ended, !cancelled else { return }
                bytes += data.count
                guard data.count % 2 == 0, bytes <= 16_000 * 2 * 300 else {
                    failed = true; ended = true; continuation.finish(); return
                }
                continuation.yield(data)
            }
        }

        func finish() async {
            lock.withLock { ended = true; continuation.finish() }
            log("parakeet \(id): finishing after \(lock.withLock { bytes } / 32_000) s of audio")
            await lock.withLock({ feeder })?.value
            do {
                let text = try await manager.finish()
                log("parakeet \(id): decoded \(text.count) characters")
                await lock.withLock({ integrity })?.value
                log("parakeet \(id): final sent, failed=\(lock.withLock { failed })")
                guard !lock.withLock({ cancelled }) else { return }
                if lock.withLock({ failed }) {
                    Wire.send(["id": id, "event": "error", "message": "Speech processing failed or exceeded five minutes. Nothing was pasted."])
                } else {
                    Wire.send(["id": id, "event": "final", "text": text])
                }
            } catch {
                if !lock.withLock({ cancelled }) { Wire.send(["id": id, "event": "error", "message": "Parakeet could not finish. Nothing was pasted."]) }
            }
            lock.withLock { updates?.cancel(); integrity?.cancel() }
        }

        func cancel() async {
            lock.withLock {
                cancelled = true; ended = true; continuation.finish()
                feeder?.cancel(); updates?.cancel(); integrity?.cancel()
            }
            await manager.cancel()
        }
    }
}
