import Foundation
@testable import EnkeonVoiceKit

func checkMeetings() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("enkeon-meeting-check-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = MeetingRepository(directory: directory)
    let emptyRecords = try repository.load(); precondition(emptyRecords.isEmpty)
    var meeting = MeetingRecord(title: "Launch review", branch: "fixture")
    let source = MeetingSegment(start: 62, end: 75, source: "Meeting audio", text: "We might ship on Friday, but do not promise that date.")
    let gap = MeetingSegment(start: 75, end: 90, source: "Capture", text: "Paused", isGap: true)
    meeting.segments = [source, gap]
    try repository.save(meeting)
    let loaded = try repository.load()
    precondition(loaded.count == 1 && loaded[0].segments == meeting.segments)
    precondition(loaded[0].transcript.contains("[01:02] Meeting audio") && loaded[0].transcript.contains("GAP"))
    meeting.status = "transcribed"; try repository.save(meeting)
    let updatedRecords = try repository.load(); precondition(updatedRecords.count == 1, "atomic update must not duplicate a meeting")
    let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(meeting.id.uuidString + ".json").path)
    precondition((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    func data(_ quote: String, id: UUID, kind: String = "Highlight") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["items": [["kind": kind, "quote": quote, "source": id.uuidString]]])
    }
    let notes = try MeetingNotes.validate(data(source.text, id: source.id), segments: meeting.segments)
    precondition(notes.count == 1 && notes[0].segmentIDs == [source.id])
    // Follow the actual source-selection -> saved receipt -> reload -> recall parsing ->
    // conservative inline continuation -> meeting attribution path without remote writes.
    let savedID = "01M66Q7HVD5828CXNM6VP9N7P3"
    meeting.insights = notes
    meeting.insights[0].savedMemoryID = EnkeonClient.memoryID(fromReply: "Remembered (id \(savedID))")
    try repository.save(meeting)
    let restored = try repository.load()[0]
    let fact: [String: Any] = ["id": "af:extracted-fact", "claim_type": "atomic-fact",
        "statement": source.text, "state": "held", "confidence_band": "strong",
        "source_uri": "mcp://agent/fixture/branch/fixture/\(savedID)"]
    func recall(_ hits: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["hits": hits, "match_quality": "strong"]), as: UTF8.self)
    }
    let reply = try recall([fact])
    let candidates = EnkeonClient.memoryCandidates(fromRecall: reply)
    precondition(candidates.first?.id == "af:extracted-fact")
    precondition(candidates.first?.revisionID == savedID, "revise the saved memory, never the extracted fact")
    let evidence = EnkeonClient.completionEvidence(fromRecall: reply)
    precondition(evidence[source.text] == savedID)
    precondition(restored.memorySourceLabel(for: evidence[source.text]!) == "Launch review · 01:02")
    let statements = EnkeonClient.completionStatements(fromRecall: reply)
    precondition(MemorySentenceCompletion.continuation(after: "We might ship", memories: statements) == " on Friday, but do not promise that date.")
    precondition(MemorySentenceCompletion.continuation(after: "We might ship", memories: statements + ["We might ship on Monday."]) == nil)
    var stale = fact; stale["may_be_outdated"] = true
    let staleReply = try recall([stale])
    precondition(EnkeonClient.completionStatements(fromRecall: staleReply).isEmpty)
    var unlinked = fact; unlinked.removeValue(forKey: "source_uri")
    let unlinkedReply = try recall([unlinked])
    precondition(EnkeonClient.memoryCandidates(fromRecall: unlinkedReply).first?.revisionID == nil)
    var foreign = fact; foreign["source_uri"] = "https://example.com/\(savedID)"
    precondition(EnkeonClient.sourceMemoryID(foreign) == nil)
    var extractedULID = fact; extractedULID["id"] = "01M66Q7HVD5828CXNM6VP9N7P4"
    precondition(EnkeonClient.sourceMemoryID(extractedULID) == savedID)
    let resume = Date(timeIntervalSince1970: 3600)
    precondition(!MeetingHealth.microphoneExpired(lastAudio: nil, resumedAt: resume, now: resume.addingTimeInterval(2)))
    precondition(!MeetingHealth.microphoneExpired(lastAudio: resume.addingTimeInterval(-60), resumedAt: resume, now: resume.addingTimeInterval(2)))
    precondition(MeetingHealth.microphoneExpired(lastAudio: nil, resumedAt: resume, now: resume.addingTimeInterval(13)))
    precondition(!MeetingHealth.microphoneExpired(lastAudio: resume.addingTimeInterval(12), resumedAt: resume, now: resume.addingTimeInterval(13)))
    for bad in [try data("ship on Friday", id: source.id), try data("We will ship on Friday.", id: source.id),
                try data(source.text, id: UUID()), try data("Paused", id: gap.id), try data(source.text, id: source.id, kind: "Promise")] {
        do { _ = try MeetingNotes.validate(bad, segments: meeting.segments); preconditionFailure("unsupported or truncated evidence accepted") }
        catch { }
    }
    precondition(MeetingCapture.rms(Data(repeating: 0, count: 32000)) == 0)
    var accumulator = MeetingAudioAccumulator()
    let quietSpeech = Data(repeating: 16, count: 32000)
    for second in 1...23 { precondition(!accumulator.append(quietSpeech, at: Double(second))) }
    precondition(accumulator.append(quietSpeech, at: 24), "continuous speech must be bounded at 24 seconds")
    let full = accumulator.flush()
    precondition(full?.audio.count == 24 * 32000 && full?.start == 0 && full?.end == 24)
    precondition(accumulator.flush() == nil, "pause/stop flush must not emit duplicate speech")
    for second in 25...29 { precondition(!accumulator.append(quietSpeech, at: Double(second))) }
    precondition(accumulator.append(Data(repeating: 0, count: 32000), at: 30), "prefer a silence boundary after six seconds")
    precondition(accumulator.flush()?.start == 24)
    _ = accumulator.append(Data(repeating: 0, count: 32000), at: 31)
    precondition(accumulator.flush() == nil, "silence must not be sent to ASR")
    _ = accumulator.append(quietSpeech, at: 101)
    precondition(accumulator.flush()?.start == 100, "a resumed track must not absorb the paused interval")
    precondition(MeetingSegment.time(-1) == "00:00")
    let damaged = directory.appendingPathComponent(UUID().uuidString + ".json")
    try Data("unfinished record".utf8).write(to: damaged)
    let recovered = try repository.loadRecovering()
    precondition(recovered.records.count == 1 && recovered.records[0].id == meeting.id && recovered.unreadable == 1)
    precondition(FileManager.default.fileExists(atPath: damaged.path), "recovery must preserve damaged files")
    try FileManager.default.removeItem(at: damaged)
    try repository.delete(meeting.id)
    let finalRecords = try repository.load(); precondition(finalRecords.isEmpty)
    print("Meeting persistence, permissions, gap and evidence checks passed")
}

func checkLiveMeeting(helper: URL, wav: URL) async throws {
    let data = try Data(contentsOf: wav)
    // Fixture supplied by our script is PCM16 mono 16 kHz with a canonical 44-byte header.
    guard data.count > 44, String(decoding: data.prefix(4), as: UTF8.self) == "RIFF" else { preconditionFailure("expected fixture WAV") }
    let transcriber = MeetingTranscriber(helperURL: helper)
    try await transcriber.prepare()
    let start = ContinuousClock.now
    let text = try await transcriber.transcribe(Data(data.dropFirst(44)))
    precondition(!text.isEmpty, "meeting batch returned no speech")
    precondition(text.lowercased().contains("friday"), "fixture's deadline was not transcribed")
    print("Live local meeting transcription passed in \(start.duration(to: .now)); \(text.count) characters")
}

func checkLiveMeetingNotes() async throws {
    guard let key = try VoiceEditorCredentials.read() else { throw CloudVoiceEditor.Failure("No configured Haiku key") }
    let segments = [
        MeetingSegment(start: 0, end: 10, source: "Meeting audio", text: "We agreed to keep the existing checkout for launch. Maya will send the revised design on Friday."),
        MeetingSegment(start: 10, end: 20, source: "Microphone", text: "We might ship next week, but do not promise that date."),
        MeetingSegment(start: 20, end: 30, source: "Capture", text: "Recording paused", isGap: true)
    ]
    let notes = try await MeetingNotes.extract(segments: segments, apiKey: key)
    precondition(!notes.isEmpty)
    for note in notes { precondition(segments.contains { !$0.isGap && $0.text == note.text && note.segmentIDs == [$0.id] }) }
    print("Live Haiku meeting notes passed: \(notes.count) source-validated notes from synthetic transcript")
}
