import AppKit
import EnkeonVoiceKit

@MainActor
enum CookieReplyForMeTests {
    static func run() {
        precondition(CookieReplyForMe.instruction(in: "say yes but Friday") == nil,
                     "bare say must not start reply drafting")
        precondition(CookieReplyForMe.instruction(in: "say yes but Friday", hasSelectedMessage: true) == "say yes but Friday")
        precondition(CookieReplyForMe.instruction(in: "reply for me: yes, Friday works") == "yes, Friday works")
        precondition(CookieReplyForMe.instruction(in: "reply to this: thanks, Friday works") == "thanks, Friday works")
        precondition(CookieReplyForMe.instruction(in: "respond to this: Friday works") == "Friday works")
        precondition(CookieReplyForMe.instruction(in: "answer this message: yes") == "yes")
        precondition(CookieReplyForMe.instruction(in: "reply to the message: yes") == nil)
        precondition(CookieReplyForMe.instruction(in: "tell me about Friday") == nil)
        precondition(!CookieReplyForMe.shouldCaptureScreen(selectedMessage: nil, screenLookRequested: false))
        precondition(CookieReplyForMe.shouldCaptureScreen(selectedMessage: nil, screenLookRequested: true))
        precondition(!CookieReplyForMe.shouldCaptureScreen(selectedMessage: "Can you do Friday?", screenLookRequested: true))
        let prompt = CookieReplyForMe.prompt(instruction: "say yes but Friday", selectedMessage: "Can you do Friday?",
                                             voiceExamples: ["Sounds good to me."])
        precondition(prompt.contains("Can you do Friday?") && prompt.contains("Sounds good to me."))
        precondition(prompt.contains("Never send") && prompt.contains("Return only the message body"))
        precondition(CookieReplyForMe.systemInstructions.contains("Never use tools, send, submit"))
        let noMessagePrompt = CookieReplyForMe.prompt(instruction: "yes", selectedMessage: nil, voiceExamples: [])
        precondition(noMessagePrompt.contains("No message content was supplied") && noMessagePrompt.contains("explicitly hold the screen-look shortcut"))
        let original = "Can you do Friday?"
        let destination = CookieTextDestination(element: AXUIElementCreateSystemWide(), pid: 1, app: "Mail",
                                                value: original, range: CFRange(location: 0, length: original.utf16.count))
        precondition(destination.accepts(currentValue: "Can you do Friday?", currentRange: destination.range,
                                         currentPID: 1, sameElement: true))
        precondition(destination.replacing(with: "Yes, Friday works.") == "Yes, Friday works.")
        print("17 reply drafting checks passed.")
    }
}

enum CookieAIHandoffTests {
    static func run() {
        precondition(CookieAIHandoff.target(in: "give this to Claude") == .claude)
        precondition(CookieAIHandoff.target(in: "give this to Cursor") == .cursor)
        precondition(CookieAIHandoff.target(in: "open Claude") == nil)
        let history = [CompanionChatMessage(role: .user, text: "The launch is next week.")]
        let packet = CookieAIHandoff.packet(selectedText: "Selected paragraph", messages: history)!
        precondition(packet.contains("Selected paragraph") && packet.contains("The launch is next week."))
        precondition(CookieAIHandoff.packet(selectedText: nil, messages: []) == nil)
        let claude = URL(fileURLWithPath: "/Applications/Claude.app")
        if case .success(.app(let resolved)) = CookieAIHandoff.resolve(.claude, apps: [claude]) {
            precondition(resolved == claude)
        } else { preconditionFailure("installed app resolution") }
        if case .failure(let reason) = CookieAIHandoff.resolve(.cursor, apps: []) {
            precondition(reason.contains("no app"))
        } else { preconditionFailure("an absent app must be reported") }
        print("7 AI handoff checks passed.")
    }
}

enum CookieRecentGreetingTests {
    static func run() {
        let older = CookieThread(id: UUID(), messages: [CompanionChatMessage(role: .user, text: "Older project")],
                                 updatedAt: Date(timeIntervalSince1970: 1))
        let newer = CookieThread(id: UUID(), messages: [CompanionChatMessage(role: .user, text: "Cookie merge")],
                                 updatedAt: Date(timeIntervalSince1970: 2))
        precondition(CookieRecentGreeting.title(in: [older, newer]) == "Cookie merge")
        precondition(CookieRecentGreeting.title(in: []) == nil)
        let long = CookieThread(id: UUID(), messages: [CompanionChatMessage(role: .user, text: String(repeating: "project ", count: 20))])
        precondition((CookieRecentGreeting.title(in: [long])?.count ?? 100) <= 56)
        print("3 recent greeting checks passed.")
    }
}
