import Foundation

/// All dimensions are display points, independent of a monitor's pixel density.
public enum FloatingBarLayout {
    /// Public macOS cursor visibility APIs are unsupported. Use a predictable inactivity
    /// policy instead; active controls/results must never disappear with the idle handle.
    public static func shouldHideIdleHandle(inactiveFor seconds: TimeInterval, engaged: Bool, active: Bool) -> Bool {
        seconds >= 3 && !engaged && !active
    }
    public enum Edge: String, CaseIterable { case bottom, top, left, right }
    public static func nearestEdge(to point: CGPoint, in area: CGRect) -> Edge {
        Edge.allCases.min { distance(point, edge: $0, area: area) < distance(point, edge: $1, area: area) } ?? .bottom
    }
    private static func distance(_ point: CGPoint, edge: Edge, area: CGRect) -> CGFloat {
        switch edge {
        case .bottom: return abs(point.y - area.minY)
        case .top: return abs(point.y - area.maxY)
        case .left: return abs(point.x - area.minX)
        case .right: return abs(point.x - area.maxX)
        }
    }
    public static func dockedFrame(in area: CGRect, edge: Edge, fraction: Double) -> CGRect {
        let width = min(panelSize.width, area.width), height = min(panelSize.height, area.height)
        let t = CGFloat(fraction.isFinite ? min(1, max(0, fraction)) : 0.5)
        let x = min(max(area.minX + area.width * t - width / 2, area.minX), area.maxX - width)
        let y = min(max(area.minY + area.height * t - height / 2, area.minY), area.maxY - height)
        switch edge {
        case .bottom: return CGRect(x: x, y: area.minY, width: width, height: height)
        case .top: return CGRect(x: x, y: area.maxY - height, width: width, height: height)
        case .left: return CGRect(x: area.minX, y: y, width: width, height: height)
        case .right: return CGRect(x: area.maxX - width, y: y, width: width, height: height)
        }
    }
    /// Transparent room around cards for the shadow to fade before the window edge.
    public static let panelSize = CGSize(width: 420, height: 240)
    public static func captures(_ point: CGPoint, controls: [CGRect], draggingFromApp: Bool) -> Bool {
        !draggingFromApp && controls.contains { $0.contains(point) }
    }

    public static func frame(in usable: CGRect, raised: Bool) -> CGRect {
        let width = min(panelSize.width, usable.width)
        let height = min(panelSize.height, usable.height)
        // The orb's lower edge is two points above the panel's lower edge.
        let clearance = min(24, max(16, usable.height * 0.02))
        let bottom = raised ? clearance - 2 : 8
        return CGRect(x: usable.midX - width / 2,
                      y: min(usable.minY + bottom, usable.maxY - height), width: width, height: height)
    }
}
