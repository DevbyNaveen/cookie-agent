import AppKit
import Combine
import EnkeonVoiceKit

@MainActor
final class MeetingModel: ObservableObject {
    enum Phase: Equatable { case idle, preparing, recording, paused, stopping }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var records: [MeetingRecord] = []
    @Published var selected: UUID?
    @Published var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var busy = false
    @Published private(set) var pending = 0
    @Published private(set) var microphoneAt: Date?
    @Published private(set) var systemAt: Date?
    @Published var showSetup = false
    @Published var showCard = false
    @Published var title = ""
    @Published var branch = ""
    @Published var includeSystem = true
    @Published var cloudConsent = false
    @Published var catchUp: [MeetingInsight] = []
    @Published var search = ""
    private(set) var activeID: UUID?
    private var capture: MeetingCapture?
    private let transcriber = MeetingTranscriber()
    private let repository: MeetingRepository
    private let audioDirectory: URL
    private var queue: [Job] = []
    private var worker: Task<Void, Never>?
    private var pausedAt: Date?
    private var lastCatchUp: Double = 0
    private var sleeping: NSObjectProtocol?
    private var operation: UUID?
    private var saving = Set<UUID>()
    private var healthTimer: Timer?
    private var microphoneGraceStarted = Date()
    private struct Job: Codable {
        var id = UUID()
        var meeting: UUID
        var start: Double
        var end: Double
        var source: String
    }
    var active: MeetingRecord? { records.first { $0.id == activeID } }
    var current: MeetingRecord? { records.first { $0.id == selected } }
    var isActive: Bool { phase != .idle }
    func cancelPreparation() {
        guard phase == .preparing, activeID == nil else { return }
        operation = nil; phase = .idle; showSetup = false
    }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Enkeon/Meetings", isDirectory: true)
        repository = MeetingRepository(directory: base)
        audioDirectory = base.appendingPathComponent("PendingAudio", isDirectory: true)
        do {
            let recovered = try repository.loadRecovering()
            records = recovered.records
            if recovered.unreadable > 0 {
                error = "\(recovered.unreadable) meeting file(s) could not be read. They were preserved; your other meetings are available."
            }
            for index in records.indices where ["recording", "paused", "processing"].contains(records[index].status) {
                records[index].status = "interrupted"
                let end = records[index].segments.map(\.end).max() ?? 0
                records[index].segments.append(.init(start: end, end: end, source: "Capture", text: "The app closed before this meeting finished. The remaining interval was not captured.", isGap: true))
                try repository.save(records[index])
            }
        } catch { self.error = "Some meeting files could not be read. Existing files were preserved. \(error.localizedDescription)" }
        sleeping = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                self.pause(); self.error = "Recording paused because your Mac is sleeping. Resume when you return."
            }
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .recording,
                      MeetingHealth.microphoneExpired(lastAudio: self.microphoneAt,
                          resumedAt: self.microphoneGraceStarted, now: Date()) else { return }
                self.pause(); self.error = "The microphone stopped delivering audio. Recording paused; check your input device."
            }
        }
    }

    func start() async {
        guard phase == .idle else { return }
        phase = .preparing; error = nil; notice = nil; microphoneAt = nil; systemAt = nil
        let token = UUID(); operation = token
        do {
            try await transcriber.prepare()
            guard operation == token else { return }
            let record = MeetingRecord(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Meeting" : String(title.prefix(160)),
                                       branch: branch.trimmingCharacters(in: .whitespacesAndNewlines))
            try repository.save(record)
            records.insert(record, at: 0); activeID = record.id; selected = record.id
            lastCatchUp = 0; catchUp = []
            let capture = MeetingCapture(); self.capture = capture
            capture.onChunk = { [weak self] chunk in Task { @MainActor in self?.enqueue(chunk, meeting: record.id) } }
            capture.onHealth = { [weak self] source, _ in Task { @MainActor in
                guard let self, self.activeID == record.id else { return }
                if source == "Microphone" { self.microphoneAt = Date() } else { self.systemAt = Date() }
            } }
            capture.onFailure = { [weak self] message in Task { @MainActor in
                guard let self, self.activeID == record.id else { return }
                self.pause(); self.error = message
            } }
            try await capture.start(includeSystem: includeSystem)
            guard operation == token else { try? await capture.stop(); return }
            mutate(record.id) { $0.started = Date() }
            microphoneGraceStarted = Date()
            phase = .recording; showSetup = false; showCard = false
        } catch {
            guard operation == token else { return }
            if let id = activeID { mutate(id) { $0.status = "failed"; $0.ended = Date() } }
            capture = nil; activeID = nil; phase = .idle
            self.error = "Meeting could not start: \(error.localizedDescription)"
        }
    }
    func pause() {
        guard phase == .recording else { return }
        capture?.pause(); pausedAt = Date(); phase = .paused
        if let id = activeID { mutate(id) { $0.status = "paused" } }
    }
    func resume() {
        guard phase == .paused, let activeID else { return }
        appendPauseGap(activeID)
        microphoneAt = nil; systemAt = nil
        microphoneGraceStarted = Date()
        capture?.resume(); phase = .recording
        mutate(activeID) { $0.status = "recording" }
    }
    func stop() async {
        guard phase == .recording || phase == .paused, let id = activeID else { return }
        appendPauseGap(id); phase = .stopping
        do { try await capture?.stop() }
        catch { phase = .paused; pausedAt = Date(); self.error = "Capture could not stop. Retry Stop before quitting."; return }
        // Capture callbacks enqueue on the main actor. Drain their already-scheduled tasks first.
        await Task.yield()
        capture = nil; activeID = nil; phase = .idle; selected = id; showCard = false
        mutate(id) {
            $0.ended = Date()
            $0.status = queue.contains { $0.meeting == id } ? "processing" : ($0.segments.contains(where: \.isGap) ? "incomplete" : "transcribed")
        }
        notice = "Meeting stopped. Your transcript is saved locally. Generate notes when ready."
    }
    private func appendPauseGap(_ id: UUID) {
        guard let pausedAt, let record = records.first(where: { $0.id == id }) else { return }
        let gap = MeetingSegment(start: pausedAt.timeIntervalSince(record.started), end: Date().timeIntervalSince(record.started),
                                 source: "Capture", text: "Recording paused. No audio captured in this interval.", isGap: true)
        mutate(id) { $0.segments.append(gap) }; self.pausedAt = nil
    }
    private func enqueue(_ chunk: MeetingCapture.Chunk, meeting: UUID) {
        let job = Job(meeting: meeting, start: chunk.start, end: chunk.end, source: chunk.source)
        do {
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try chunk.audio.write(to: audioURL(job), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audioURL(job).path)
            try JSONEncoder().encode(job).write(to: jobURL(job), options: .atomic)
            queue.append(job); pending = queue.count
            if activeID != meeting { mutate(meeting) { $0.status = "processing" } }
            if queue.count > 20 { pause(); error = "Transcription is falling behind. Recording paused while it catches up." }
            runQueue()
        } catch {
            pause(); self.error = "Could not save meeting audio. Recording paused to avoid losing more."
            mutate(meeting) { $0.segments.append(.init(start: chunk.start, end: chunk.end, source: chunk.source, text: "Audio could not be saved.", isGap: true)) }
        }
    }
    private func audioURL(_ job: Job) -> URL { audioDirectory.appendingPathComponent(job.id.uuidString + ".pcm") }
    private func jobURL(_ job: Job) -> URL { audioDirectory.appendingPathComponent(job.id.uuidString + ".json") }
    private func runQueue() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while let job = self.queue.first {
                do {
                    let audio = try Data(contentsOf: self.audioURL(job))
                    let text = try await self.transcriber.transcribe(audio)
                    guard !text.isEmpty else {
                        throw CloudVoiceEditor.Failure("No speech recognized; keep the audio for retry.")
                    }
                    guard self.records.contains(where: { $0.id == job.meeting }) else { self.queue.removeFirst(); continue }
                    let segment = MeetingSegment(start: job.start, end: job.end, source: job.source,
                                                 text: text.isEmpty ? "Speech could not be recognized in this audio interval." : text,
                                                 isGap: text.isEmpty)
                    guard self.mutate(job.meeting, { record in
                        record.segments.removeAll { $0.id == job.id }
                        var saved = segment; saved.id = job.id; record.segments.append(saved)
                        record.segments.sort { $0.start < $1.start }
                    }) else { self.pause(); break }
                    try? FileManager.default.removeItem(at: self.audioURL(job))
                    try? FileManager.default.removeItem(at: self.jobURL(job))
                } catch {
                    self.pause()
                    self.error = "Some audio could not be transcribed. It remains on this Mac; use Retry audio."
                    self.mutate(job.meeting) { record in
                        record.segments.removeAll { $0.id == job.id }
                        var gap = MeetingSegment(start: job.start, end: job.end, source: job.source, text: "Transcription failed; audio is available for retry.", isGap: true)
                        gap.id = job.id; record.segments.append(gap)
                    }
                }
                self.queue.removeFirst(); self.pending = self.queue.count
                if self.activeID != job.meeting && !self.queue.contains(where: { $0.meeting == job.meeting }) {
                    self.mutate(job.meeting) { $0.status = $0.segments.contains(where: \.isGap) ? "incomplete" : "transcribed" }
                }
            }
            self.worker = nil
        }
    }
    func retryAudio(_ id: UUID) async {
        guard worker == nil else { return }
        do {
            try await transcriber.prepare()
            let files = try FileManager.default.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil)
            queue = try files.filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(Job.self, from: Data(contentsOf: $0)) }
                .filter { $0.meeting == id }.sorted { $0.start < $1.start }
            pending = queue.count; runQueue()
        } catch { self.error = "No recoverable audio could be loaded: \(error.localizedDescription)" }
    }

    func generateNotes(catchUpOnly: Bool = false) async {
        guard !busy, saving.isEmpty, cloudConsent, let record = catchUpOnly ? active : current else { return }
        busy = true; error = nil
        defer { busy = false }
        let segments = catchUpOnly ? record.segments.filter { $0.end >= lastCatchUp } : record.segments
        do {
            let key = try await Task.detached { try VoiceEditorCredentials.read() }.value
            let notes = try await MeetingNotes.extract(segments: segments, apiKey: key ?? "")
            if catchUpOnly { catchUp = notes; lastCatchUp = segments.map(\.end).max() ?? lastCatchUp; showCard = true }
            else {
                mutate(record.id) { updated in
                    // Preserve explicit saves across regeneration.
                    updated.insights = notes.map { note in
                        var note = note
                        note.savedMemoryID = updated.insights.first { $0.text == note.text && $0.segmentIDs == note.segmentIDs }?.savedMemoryID
                        return note
                    }
                }
            }
            notice = notes.isEmpty ? "No supported notes found in the captured transcript." : "Notes ready. Review the source before saving or sharing."
        } catch { self.error = error.localizedDescription }
    }
    func draftFollowUp(_ id: UUID) {
        mutate(id) { record in
            record.draft = "Meeting notes — \(record.title)\n\n" + record.insights.map { note in
                let time = record.segments.first { note.segmentIDs.contains($0.id) }?.timestamp ?? ""
                return "\(note.kind) [\(time)]: \(note.text)"
            }.joined(separator: "\n\n") + (record.segments.contains(where: \.isGap) ? "\n\nThese notes contain recording or transcription gaps; please review the transcript." : "")
        }
    }
    func saveMemory(_ insight: MeetingInsight, record: MeetingRecord, text: String, updates: String?) async {
        guard !busy, !record.branch.isEmpty, insight.savedMemoryID == nil, !saving.contains(insight.id), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard records.first(where: { $0.id == record.id })?.insights.contains(where: { $0.id == insight.id && $0.savedMemoryID == nil }) == true else {
            error = "This note changed or was already saved. Reopen it before saving."; return
        }
        saving.insert(insight.id); defer { saving.remove(insight.id) }
        do {
            let times = record.segments.filter { insight.segmentIDs.contains($0.id) }.map(\.timestamp).joined(separator: ", ")
            let reply = try await EnkeonClient.shared.rememberMeeting(text, branch: record.branch,
                title: record.title, source: "enkeon-voice://meeting/\(record.id.uuidString)#\(times.replacingOccurrences(of: " ", with: ""))", updates: updates)
            guard let memory = EnkeonClient.memoryID(fromReply: reply) else {
                error = "Enkeon replied without a memory ID. Check your memory before retrying to avoid duplicates."; return
            }
            let saved = mutate(record.id) { value in
                if let index = value.insights.firstIndex(where: { $0.id == insight.id }) { value.insights[index].savedMemoryID = memory }
            }
            guard saved else {
                // The remote write succeeded. Prevent another save in this session even if
                // the local receipt could not be persisted; never claim that both succeeded.
                if let index = records.firstIndex(where: { $0.id == record.id }),
                   let note = records[index].insights.firstIndex(where: { $0.id == insight.id }) {
                    records[index].insights[note].savedMemoryID = memory
                }
                error = "Saved to Enkeon, but the local receipt could not be saved. Check free disk space; do not save this note again after restarting."
                return
            }
            notice = "Saved to \(record.branch)."
        } catch { self.error = error.localizedDescription }
    }
    func delete(_ id: UUID) {
        guard activeID != id, !queue.contains(where: { $0.meeting == id }), !busy, saving.isEmpty else { return }
        do {
            let files = (try? FileManager.default.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                if let job = try? JSONDecoder().decode(Job.self, from: Data(contentsOf: file)), job.meeting == id {
                    if FileManager.default.fileExists(atPath: audioURL(job).path) { try FileManager.default.removeItem(at: audioURL(job)) }
                    try FileManager.default.removeItem(at: file)
                }
            }
            try repository.delete(id); records.removeAll { $0.id == id }; if selected == id { selected = nil }
        } catch { self.error = "Could not delete the meeting: \(error.localizedDescription)" }
    }
    @discardableResult private func mutate(_ id: UUID, _ update: (inout MeetingRecord) -> Void) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        var record = records[index]; update(&record)
        do { try repository.save(record); records[index] = record; return true }
        catch { self.error = "Could not save meeting changes. Check free disk space. Existing data was preserved."; return false }
    }
    func updateDraft(_ id: UUID, text: String) { mutate(id) { $0.draft = text } }
    func export(_ record: MeetingRecord) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Meeting-\(record.id.uuidString.prefix(8)).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try (record.title + "\n\n" + record.transcript + "\n\n" + record.draft).write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = "Export failed: \(error.localizedDescription)" }
    }
}
