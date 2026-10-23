//
//  CookieNotifications.swift
//  Cookie
//
//  macOS notifications, for when you're away from the Mac. While you're at
//  it, the notch card already shows on every Space, so a notification only
//  goes out when Cookie's panel is closed and the Mac has been idle for a
//  minute or is locked; it then waits in Notification Center. Focus and Do
//  Not Disturb apply as for any app, and macOS hides notifications while
//  the screen is shared. An approval is never answered from a notification:
//  clicking opens the card.
//

import AppKit
@preconcurrency import UserNotifications

@MainActor
final class CookieNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CookieNotifications()

    enum Kind { case reply, failure, approval }

    enum Level: String, CaseIterable {
        /// Replies, failures and approvals.
        case all
        /// Approvals and failures only.
        case important
        case off
    }

    static let levelKey = "cookie.notify.level"
    static var level: Level { Level(rawValue: UserDefaults.standard.string(forKey: levelKey) ?? "") ?? .all }

    /// Away means idle this long (or locked).
    nonisolated static let awayAfter: TimeInterval = 60

    private var openThread: ((UUID) -> Void)?

    func start(openThread: @escaping (UUID) -> Void) {
        self.openThread = openThread
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: Decisions (pure, checked by the interaction tests)

    nonisolated static func shouldNotify(_ kind: Kind, level: Level, panelOpen: Bool, idleSeconds: TimeInterval, screenLocked: Bool) -> Bool {
        guard !panelOpen, screenLocked || idleSeconds >= awayAfter else { return false }
        switch level {
        case .all: return true
        case .important: return kind != .reply
        case .off: return false
        }
    }

    /// What the notification says. With chats locked it says nothing about them.
    nonisolated static func text(title: String, body: String, kind: Kind, chatsLocked: Bool) -> (title: String, body: String) {
        switch kind {
        case .approval: return ("Cookie needs your OK", title)
        case .failure: return (chatsLocked ? "Cookie" : title, "Something went wrong. Open Cookie to see why.")
        case .reply: return chatsLocked ? ("Cookie", "Cookie has a reply.") : (title, body)
        }
    }

    // MARK: Posting

    /// Asks for permission while you're here (after a reply you just saw),
    /// never in the middle of being away.
    func prepare() {
        guard Self.level != .off else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func post(_ kind: Kind, threadID: UUID?, title: String, body: String, panelOpen: Bool) {
        guard Self.shouldNotify(kind, level: Self.level, panelOpen: panelOpen,
                                idleSeconds: Self.idleSeconds(), screenLocked: Self.screenLocked()) else { return }
        let words = Self.text(title: title, body: body, kind: kind, chatsLocked: ChatLock.shared.isLocked)
        let content = UNMutableNotificationContent()
        content.title = words.title
        content.body = String(words.body.prefix(240))
        content.sound = kind == .reply ? nil : .default
        if let threadID { content.userInfo = ["thread": threadID.uuidString] }
        // One per chat: a newer reply replaces the older notification.
        let id = threadID?.uuidString ?? UUID().uuidString
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// The chat is open now: its notification has done its job.
    func clear(threadID: UUID) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [threadID.uuidString])
    }

    private static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private static func screenLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let thread = (response.notification.request.content.userInfo["thread"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            if let thread { self.openThread?(thread) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
