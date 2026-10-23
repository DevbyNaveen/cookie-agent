import Foundation

struct CookieDockHoverIntent {
    enum Action: Equatable { case open(UUID), close }
    private(set) var deadline: TimeInterval?
    private var pending: Action?
    private var dismissedID: UUID?

    mutating func reset(dismissing id: UUID? = nil) {
        deadline = nil
        pending = nil
        dismissedID = id
    }

    mutating func update(insideID: UUID?, expandedID: UUID?, now: TimeInterval, enabled: Bool = true) -> Action? {
        guard enabled else { reset(); return nil }
        if insideID != dismissedID { dismissedID = nil }
        let action: Action?
        if let insideID {
            action = insideID == expandedID || insideID == dismissedID ? nil : .open(insideID)
        } else {
            action = expandedID == nil ? nil : .close
        }
        guard let action else { deadline = nil; pending = nil; return nil }
        if pending != action {
            pending = action
            deadline = now + (action == .close ? 0.32 : 0.22)
        }
        guard let deadline, now >= deadline else { return nil }
        self.deadline = nil
        pending = nil
        return action
    }
}

struct CookieDockGeometry {
    static let bubbleSize: CGFloat = 52
    static let inset: CGFloat = 8
    let availableSize: CGSize

    var canvas: CGSize {
        CGSize(width: min(336, max(0, availableSize.width - 16)),
               height: max(0, availableSize.height - min(90, availableSize.height * 0.12) - 12))
    }
    var cardWidth: CGFloat { max(0, canvas.width - Self.inset * 2) }
    var cardHeight: CGFloat { min(204, max(Self.bubbleSize, canvas.height - Self.inset * 2)) }
    var historyHeight: CGFloat { min(136, max(0, canvas.height - cardHeight - Self.inset * 2)) }

    func size(progress: CGFloat, historyExpanded: Bool) -> CGSize {
        let fraction = min(1, max(0, progress))
        let expandedHeight = cardHeight + (historyExpanded ? historyHeight : 0)
        return CGSize(width: Self.bubbleSize + (cardWidth - Self.bubbleSize) * fraction,
                      height: Self.bubbleSize + (expandedHeight - Self.bubbleSize) * fraction)
    }

    /// Matches the rounded visible surface; blank space in the native panel passes through.
    static func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
        guard rect.contains(point) else { return false }
        let radius = min(22, min(rect.width, rect.height) / 2)
        let nearest = CGPoint(x: min(max(point.x, rect.minX + radius), rect.maxX - radius),
                              y: min(max(point.y, rect.minY + radius), rect.maxY - radius))
        return hypot(point.x - nearest.x, point.y - nearest.y) <= radius
    }
}
