import Foundation
import EnkeonVoiceKit

@MainActor
enum CookieMeetingBriefTests {
    static func run() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = UpcomingMeeting(id: "meeting-1", title: "Pricing review", start: now.addingTimeInterval(120),
                                      end: now.addingTimeInterval(1_200), attendees: ["Priya"])
        precondition(CookieMeetingBriefBuilder.shouldPresent(access: .allowed, meeting: meeting, now: now, alreadyPresented: false))
        var pendingBrief: CookieMeetingBrief?
        precondition(CookieMeetingBriefBuilder.presentIfDue(
            access: .allowed, meeting: meeting, now: now, alreadyPresented: false, pendingBrief: &pendingBrief
        ) { CookieMeetingBriefBuilder.make(meeting: meeting, pastMeetings: [], work: [], recall: nil) })
        precondition(pendingBrief?.meeting.id == meeting.id, "T-2 poll must set the pending brief")
        let before = UpcomingMeeting(id: "before", title: "Pricing review", start: now.addingTimeInterval(121),
                                     end: now.addingTimeInterval(1_200), attendees: [])
        precondition(!CookieMeetingBriefBuilder.shouldPresent(access: .allowed, meeting: before, now: now, alreadyPresented: false))
        precondition(!CookieMeetingBriefBuilder.shouldPresent(access: .allowed, meeting: meeting, now: now, alreadyPresented: true))
        precondition(!CookieMeetingBriefBuilder.shouldPresent(access: .notAsked, meeting: meeting, now: now, alreadyPresented: false))

        let noAttendees = UpcomingMeeting(id: "empty", title: "Pricing review", start: meeting.start,
                                          end: meeting.end, attendees: [])
        let empty = CookieMeetingBriefBuilder.make(meeting: noAttendees, pastMeetings: [], work: [], recall: nil)
        precondition(empty.lines.isEmpty && empty.text == "Pricing review · " + meeting.start.formatted(date: .omitted, time: .shortened))

        var systemOnly = MeetingRecord(title: "Pricing review", branch: "local")
        systemOnly.started = now.addingTimeInterval(-86_400)
        systemOnly.attendees = ["Priya"]
        systemOnly.segments = [.init(start: 1, end: 2, source: "Meeting audio", text: "I'll send the final price Friday.")]
        let withoutMicPromise = CookieMeetingBriefBuilder.make(meeting: meeting, pastMeetings: [systemOnly], work: [], recall: nil)
        precondition(!withoutMicPromise.lines.contains { $0.label == "Promise" })

        var past = MeetingRecord(title: "Pricing review", branch: "local")
        past.started = now.addingTimeInterval(-86_400)
        past.attendees = ["Priya"]
        let quote = "I'll send the updated pricing on Friday."
        past.segments = [
            .init(start: 1, end: 2, source: "Microphone", text: quote),
            .init(start: 3, end: 4, source: "Meeting audio", text: "I will send the contract tomorrow.")
        ]
        var boardPromise = WorkItem(title: quote)
        boardPromise.history.append(WorkEvent(text: "Promised in a meeting", by: "cookie"))
        let fromBoard = CookieMeetingBriefBuilder.make(meeting: meeting, pastMeetings: [past], work: [boardPromise], recall: nil)
        let promiseLine = fromBoard.lines.first { $0.label == "Promise" }
        precondition(promiseLine?.text == quote && promiseLine?.source.hasPrefix("Board promise ·") == true)

        let fromTranscript = CookieMeetingBriefBuilder.make(meeting: meeting, pastMeetings: [past], work: [], recall: nil)
        precondition(fromTranscript.lines.first { $0.label == "Promise" }?.source.hasPrefix("Microphone transcript ·") == true)
        let attendeeOnly = CookieMeetingBriefBuilder.make(meeting: meeting, pastMeetings: [], work: [], recall: "  ")
        precondition(attendeeOnly.lines.count == 1 && attendeeOnly.lines[0].text == "Priya")
        precondition(attendeeOnly.lines.allSatisfy { !$0.source.isEmpty })
        precondition(fromBoard.noticeMessage.contains("Pricing review · ") && fromBoard.noticeMessage.contains("Board promise ·"))
        let recalled = CookieMeetingBriefBuilder.make(meeting: meeting, pastMeetings: [], work: [], recall: "Renewal ends Friday.")
        precondition(recalled.lines.contains { $0.label == "Recall" && $0.source == "Enkeon" })
        precondition(recalled.noticeMessage.contains(meeting.start.formatted(date: .omitted, time: .shortened)))
        print("15 meeting brief checks passed.")
    }
}
