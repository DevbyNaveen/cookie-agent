import Foundation

enum NotchState: Equatable { case closed, peek, home, notice }

/// A brief crossing never opens the island; leaving has a little forgiveness too.
struct NotchHoverIntent {
    private(set) var pendingState: NotchState?
    private(set) var deadline: TimeInterval?

    mutating func reset() {
        pendingState = nil
        deadline = nil
    }

    mutating func update(state: NotchState, insideTrigger: Bool, insideIsland: Bool,
                         enabled: Bool, now: TimeInterval) -> NotchState? {
        let destination: NotchState?
        if state == .closed && insideTrigger && enabled {
            destination = .peek
        } else if state == .peek && !insideIsland {
            destination = .closed
        } else {
            destination = nil
        }

        guard let destination else { reset(); return nil }
        if pendingState != destination {
            pendingState = destination
            deadline = now + (destination == .peek ? 0.22 : 0.18)
        }
        guard let deadline, now >= deadline else { return nil }
        reset()
        return destination
    }
}

struct CookieHomeLayout {
    let width: CGFloat

    var showsSidebar: Bool { width >= 740 }
    var sidebarWidth: CGFloat { showsSidebar ? min(236, max(196, width * 0.25)) : 0 }
    var drawerWidth: CGFloat { min(236, max(0, width - 56)) }
    var conversationWidth: CGFloat { max(0, width - sidebarWidth) }

    // A preview moves over the conversation when both would become too narrow.
    var showsInlinePreview: Bool { conversationWidth >= 680 }
    var previewWidth: CGFloat { min(440, max(0, conversationWidth - 372)) }
}

struct NotchLayout {
    let notchSize: CGSize
    let availableSize: CGSize

    var panelSize: CGSize {
        CGSize(width: min(960, max(0, availableSize.width)), height: min(660, max(0, availableSize.height)))
    }

    func size(for state: NotchState, voiceActive: Bool, threadCount: Int) -> CGSize {
        let preferredSize: CGSize
        switch state {
        case .closed:
            preferredSize = CGSize(width: notchSize.width + 12 + (voiceActive ? 96 : 0), height: notchSize.height)
        case .peek:
            preferredSize = CGSize(width: 488, height: CookiePeekMetrics.height(header: max(notchSize.height, 32)))
        case .home:
            preferredSize = CGSize(width: 928, height: 580)
        case .notice:
            preferredSize = CGSize(width: 468, height: max(notchSize.height, 32) + 104)
        }
        return CGSize(width: min(preferredSize.width, panelSize.width), height: min(preferredSize.height, panelSize.height))
    }
}
