import AVFoundation
import ScreenCaptureKit
import Foundation

/// Audio-only capture. Screen frames are never registered or retained. Both tracks share one
/// serial queue, including pause/flush, so callbacks cannot cross a pause boundary.
public final class MeetingCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public struct Chunk: Sendable {
        public let audio: Data
        public let start: Double
        public let end: Double
        public let source: String
    }
    public var onChunk: ((Chunk) -> Void)?
    public var onHealth: ((String, Double) -> Void)?
    public var onFailure: ((String) -> Void)?
    private let queue = DispatchQueue(label: "com.enkeon.meeting.audio", qos: .userInitiated)
    private var stream: SCStream?
    private var accepting = false
    private var origin = ProcessInfo.processInfo.systemUptime
    private var tracks: [String: Track] = [:]
    private struct Track {
        var converter = BuddyPCM16AudioConverter(targetSampleRate: 16000)
        var accumulator = MeetingAudioAccumulator()
        var healthAt: Double = -10
    }

    public func start(includeSystem: Bool) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw CloudVoiceEditor.Failure("Allow microphone access in System Settings → Privacy & Security.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CloudVoiceEditor.Failure("No display is available for meeting audio capture.") }
        let config = SCStreamConfiguration()
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = includeSystem
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000; config.channelCount = 1
        config.captureMicrophone = true
        let capture = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        if includeSystem { try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        try capture.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        stream = capture
        queue.sync { origin = ProcessInfo.processInfo.systemUptime; accepting = true; tracks = [:] }
        do { try await capture.startCapture() }
        catch { queue.sync { accepting = false; tracks = [:] }; stream = nil; throw error }
    }

    public func pause() { queue.sync { accepting = false; flushAll() } }
    public func resume() { queue.sync { tracks = [:]; accepting = true } }
    public func stop() async throws {
        queue.sync { accepting = false; flushAll() }
        guard let stream else { return }
        // Keep the stream reference on failure so stop can be retried.
        try await stream.stopCapture()
        self.stream = nil
    }
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [self] in accepting = false; flushAll(); onFailure?("Meeting audio stopped. Check permissions and your audio device.") }
    }
    public func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, sample.isValid, type == .audio || type == .microphone,
              let description = sample.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else {
            accepting = false; flushAll(); onFailure?("Meeting audio could not be read. Recording has paused."); return
        }
        let source = type == .microphone ? "Microphone" : "Meeting audio"
        var track = tracks[source] ?? Track()
        guard let data = track.converter.convertToPCM16Data(from: buffer) else {
            accepting = false; flushAll(); onFailure?("Meeting audio format changed. Stop and start a new recording."); return
        }
        let now = ProcessInfo.processInfo.systemUptime - origin
        if now - track.healthAt >= 1 { track.healthAt = now; onHealth?(source, now) }
        guard !data.isEmpty else { tracks[source] = track; return }
        let ready = track.accumulator.append(data, at: now)
        tracks[source] = track
        if ready { flush(source) }
    }
    private func flushAll() { for key in Array(tracks.keys) { flush(key) } }
    private func flush(_ source: String) {
        guard var track = tracks[source] else { return }
        if let value = track.accumulator.flush() {
            onChunk?(Chunk(audio: value.audio, start: value.start, end: value.end, source: source))
        }
        tracks[source] = track
    }
    static func rms(_ data: Data) -> Double {
        guard data.count >= 2 else { return 0 }
        return data.withUnsafeBytes { raw in
            var sum = 0.0
            for i in stride(from: 0, to: data.count - 1, by: 2) {
                let value = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: Int16.self))) / 32768
                sum += value * value
            }
            return sqrt(sum / Double(data.count / 2))
        }
    }
}

/// Bounded PCM accumulator shared by actual capture and deterministic pause/chunk checks.
struct MeetingAudioAccumulator {
    private var data = Data()
    private var start = 0.0
    private var quiet = 0.0
    private var voiced = false
    mutating func append(_ input: Data, at time: Double) -> Bool {
        guard !input.isEmpty else { return false }
        let duration = Double(input.count) / 32000
        if data.isEmpty { start = max(0, time - duration) }
        if MeetingCapture.rms(input) > 0.0003 { voiced = true; quiet = 0 } else { quiet += duration }
        data.append(input)
        return data.count >= 24 * 32000 || (data.count >= 6 * 32000 && quiet >= 0.7)
    }
    mutating func flush() -> (audio: Data, start: Double, end: Double)? {
        defer { data = Data(); quiet = 0; voiced = false }
        guard voiced, !data.isEmpty else { return nil }
        return (data, start, start + Double(data.count) / 32000)
    }
}

/// A dedicated helper prevents a stalled meeting batch from killing an active dictation session.
public actor MeetingTranscriber {
    private let helper: SpeechHelper
    public init(helperURL: URL = SpeechHelper.defaultHelperURL) {
        helper = SpeechHelper(helperURL: helperURL)
    }
    public func prepare() async throws { _ = try await helper.request(["op": "parakeet.prepare"], timeout: 600) }
    public func transcribe(_ audio: Data) async throws -> String {
        guard !audio.isEmpty, audio.count <= 32 * 32000, audio.count % 2 == 0 else {
            throw CloudVoiceEditor.Failure("Invalid meeting audio chunk.")
        }
        let reply = try await helper.request(["op": "meeting.transcribe"], payload: audio, timeout: 45)
        guard let text = reply["text"] as? String else { throw CloudVoiceEditor.Failure("No meeting transcript returned.") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
