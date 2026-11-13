import AppKit
import Combine

@MainActor
enum CookieConversationModeTests {
    static func run() {
        var gesture = CookieConversationGesture()
        precondition(!gesture.update(held: true))
        precondition(!gesture.update(held: true), "holding cannot repeatedly toggle")
        precondition(gesture.update(held: false), "release toggles once")
        precondition(!gesture.update(held: false))
        _ = gesture.update(held: true)
        _ = gesture.update(held: true, otherKey: true)
        precondition(!gesture.update(held: false), "a normal app shortcut must not toggle conversation")
        _ = gesture.update(held: true)
        gesture.reset()
        precondition(!gesture.update(held: false), "Escape invalidates the gesture")
        var turn = CookieConversationTurn(at: 0)
        precondition(turn.sample(power: 0, at: 2) == .listen)
        precondition(turn.sample(power: 0, at: 20) == .timeout, "silence ends the session")
        turn = CookieConversationTurn(at: 0)
        turn.transcript("I would like", at: 1)
        precondition(turn.sample(power: 0, at: 2) == .listen, "allow a thinking pause")
        turn.transcript("I would like to practice", at: 2)
        precondition(turn.sample(power: 0, at: 3) == .listen)
        precondition(turn.sample(power: 0, at: 3.7) == .finish)
        turn = CookieConversationTurn(at: 0)
        for index in 1...4 { _ = turn.sample(power: 0.1, at: Double(index) / 10) }
        precondition(turn.sample(power: 0, at: 2.1) == .finish, "upload-only providers use audio endpointing")
        turn = CookieConversationTurn(at: 0)
        for index in 1...4 { _ = turn.sample(power: 0.1, at: Double(index)) }
        precondition(turn.sample(power: 0.1, at: 60) == .finish, "bound continuous noise or long speech")
        turn = CookieConversationTurn(at: 0, requiresRecognizedSpeech: true)
        for index in 1...10 { precondition(turn.sample(power: 0.15, at: Double(index)) == .listen) }
        precondition(turn.sample(power: 0, at: 12) == .listen, "ambient sound must not restart Apple recognition")
        precondition(turn.sample(power: 0, at: 20) == .timeout)
        let monitor = GlobalPushToTalkShortcutMonitor()
        var toggles = 0
        var releases = 0
        let subscriptions = [
            monitor.conversationTogglePublisher.sink { toggles += 1 },
            monitor.shortcutTransitionPublisher.sink { if case .released = $0 { releases += 1 } }
        ]
        let event = CGEvent(source: nil)!
        event.flags = [.maskCommand, .maskAlternate]
        _ = monitor.handleGlobalEventTap(eventType: .flagsChanged, event: event)
        event.flags = []
        _ = monitor.handleGlobalEventTap(eventType: .flagsChanged, event: event)
        precondition(toggles == 1 && releases == 0)
        event.flags = [.maskCommand, .maskAlternate]
        _ = monitor.handleGlobalEventTap(eventType: .flagsChanged, event: event)
        let key = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true)!
        key.flags = event.flags
        _ = monitor.handleGlobalEventTap(eventType: .keyDown, event: key)
        event.flags = []
        _ = monitor.handleGlobalEventTap(eventType: .flagsChanged, event: event)
        precondition(toggles == 1, "Option Command C remains an app shortcut")
        event.flags = [.maskCommand, .maskAlternate, .maskShift]
        _ = monitor.handleGlobalEventTap(eventType: .flagsChanged, event: event)
        event.flags = [.maskCommand, .maskAlternate]
        _ = monitor.handleGlobalEventTap(eventType: .flagsChanged, event: event)
        event.flags = []
        _ = monitor.handleGlobalEventTap(eventType: .flagsChanged, event: event)
        precondition(toggles == 1, "releasing Shift from another chord must not arm conversation")
        event.flags = [.maskControl, .maskAlternate]
        _ = monitor.handleGlobalEventTap(eventType: .flagsChanged, event: event)
        event.flags = []
        _ = monitor.handleGlobalEventTap(eventType: .flagsChanged, event: event)
        precondition(toggles == 1 && releases == 1, "Control Option remains ordinary push-to-talk")
        for text in ["Can you just underline under the bullet point, hold control option? Quick voice request.", "It's already been shared, I think.", "Circle that"] {
            precondition(CookieRequestMode.choose(text, selection: false, visual: false) == .screen)
        }
        precondition(CookieRequestMode.refersToPrevious("Do it there"))
        monitor.stop()
        withExtendedLifetime(subscriptions) { }
        let manager = CompanionManager()
        manager.toggleConversationMode()
        precondition(manager.isConversationMode)
        manager.cancelCurrentInteraction()
        precondition(!manager.isConversationMode, "Stop cancels even during the initial idle gap")
        print("Conversation mode: gesture, silence, transcript pauses and bounded turns passed.")
    }
}
