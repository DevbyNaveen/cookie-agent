import EnkeonVoiceKit
import AppKit

/// One meeting recorder: on this Mac by default, cloud only when chosen; a kept meeting's promises
/// become work on the Board either way.
@MainActor
enum CookieMeetingTests {
    static func run() {
        let suite = "cookie.checks.meetings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(MeetingTranscription.current(defaults: defaults) == .onDevice, "meetings stay on this Mac unless you choose otherwise")
        defaults.set(true, forKey: MeetingTranscription.cloudKey)
        precondition(MeetingTranscription.current(defaults: defaults) == .cloud)

        let transcript = "Thanks all. I'll send the deck Thursday. The budget is fine. We will book the room! Did you see it?"
        let promises = MeetingPromises.extract(transcript)
        precondition(promises == ["I'll send the deck Thursday.", "We will book the room!"], "\(promises)")
        precondition(MeetingPromises.extract("").isEmpty)

        let work = WorkStore(connected: false)
        CookieRecorder.rememberMeeting(summary: "", promises: promises, work: work)
        precondition(work.items.contains { $0.title.contains("send the deck") }, "a kept promise is work on the Board")

        precondition(SpeechHelper.defaultHelperURL.lastPathComponent == "cookie-sense", "one speech helper for dictation and meetings")
        print("3 meeting checks passed.")
    }
}
