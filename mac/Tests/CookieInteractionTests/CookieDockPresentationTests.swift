import AppKit
import SwiftUI

@MainActor
enum CookieDockPresentationTests {
    static func run() {
        passingTheFaceDoesNotOpenLater()
        leavingAndReturningKeepsTheCardOpen()
        manualCollapseWaitsForAnotherApproach()
        switchingFacesRestartsIntent()
        geometryFitsAndEmptySpacePassesThrough()
        everyAnimationFrameClipsTheWholeSurface()
        nativeAnimationReportsItsVisibleBounds()
        print("7 dock presentation checks passed.")
    }

    private static func passingTheFaceDoesNotOpenLater() {
        let id = UUID()
        var hover = CookieDockHoverIntent()
        precondition(hover.update(insideID: id, expandedID: nil, now: 0) == nil)
        precondition(hover.update(insideID: nil, expandedID: nil, now: 0.1) == nil)
        precondition(hover.update(insideID: nil, expandedID: nil, now: 0.5) == nil && hover.deadline == nil)
        precondition(hover.update(insideID: id, expandedID: nil, now: 1) == nil)
        precondition(hover.update(insideID: id, expandedID: nil, now: 1.15) == nil)
        precondition(hover.update(insideID: id, expandedID: nil, now: 1.23) == .open(id))
    }

    private static func leavingAndReturningKeepsTheCardOpen() {
        let id = UUID()
        var hover = CookieDockHoverIntent()
        precondition(hover.update(insideID: nil, expandedID: id, now: 0) == nil)
        precondition(hover.update(insideID: id, expandedID: id, now: 0.2) == nil)
        precondition(hover.update(insideID: id, expandedID: id, now: 0.5) == nil && hover.deadline == nil)
        precondition(hover.update(insideID: nil, expandedID: id, now: 1) == nil)
        precondition(hover.update(insideID: nil, expandedID: id, now: 1.33) == .close)
    }

    private static func manualCollapseWaitsForAnotherApproach() {
        let id = UUID()
        var hover = CookieDockHoverIntent()
        hover.reset(dismissing: id)
        precondition(hover.update(insideID: id, expandedID: nil, now: 0) == nil)
        precondition(hover.update(insideID: id, expandedID: nil, now: 1) == nil && hover.deadline == nil)
        _ = hover.update(insideID: nil, expandedID: nil, now: 2)
        _ = hover.update(insideID: id, expandedID: nil, now: 3)
        precondition(hover.update(insideID: id, expandedID: nil, now: 3.23) == .open(id))
    }

    private static func switchingFacesRestartsIntent() {
        let first = UUID(), second = UUID()
        var hover = CookieDockHoverIntent()
        _ = hover.update(insideID: first, expandedID: nil, now: 0)
        _ = hover.update(insideID: second, expandedID: nil, now: 0.15)
        precondition(hover.update(insideID: second, expandedID: nil, now: 0.25) == nil)
        precondition(hover.update(insideID: second, expandedID: nil, now: 0.38) == .open(second))
        _ = hover.update(insideID: first, expandedID: second, now: 1)
        precondition(hover.update(insideID: first, expandedID: second, now: 1.5, enabled: false) == nil)
        precondition(hover.deadline == nil)
    }

    private static func geometryFitsAndEmptySpacePassesThrough() {
        for screen in [CGSize(width: 320, height: 350), CGSize(width: 800, height: 500), CGSize(width: 1920, height: 1080)] {
            let geometry = CookieDockGeometry(availableSize: screen)
            for history in [false, true] {
                let expanded = geometry.size(progress: 1, historyExpanded: history)
                precondition(expanded.width + 16 <= geometry.canvas.width)
                precondition(expanded.height + 16 <= geometry.canvas.height)
            }
        }
        let bounds = CGRect(x: 16, y: 8, width: 320, height: 204)
        precondition(!CookieDockGeometry.contains(CGPoint(x: 17, y: 9), in: bounds))
        precondition(!CookieDockGeometry.contains(CGPoint(x: 100, y: 220), in: bounds))
        precondition(!CookieDockGeometry.contains(CGPoint(x: 0, y: 100), in: bounds))
        precondition(CookieDockGeometry.contains(CGPoint(x: 30, y: 110), in: bounds))
        precondition(CookieDockGeometry.contains(CGPoint(x: 310, y: 180), in: bounds))
    }

    private static let entry = DockEntry(id: UUID(), agentID: nil, threadID: UUID(), status: "Speaking",
        step: "Your brief is ready. I’ve pulled together the key changes and three things to bring to tomorrow’s meeting.",
        history: ["Read the latest company update", "Compared it with your meeting notes", "Prepared a one-page brief"])

    private static func everyAnimationFrameClipsTheWholeSurface() {
        let geometry = CookieDockGeometry(availableSize: CGSize(width: 1440, height: 900))
        for history in [false, true] {
            for progress: CGFloat in [0, 0.1, 0.25, 0.5, 0.75, 0.9, 1] {
                let surface = makeSurface(geometry: geometry, progress: progress, history: history)
                    .frame(width: 368, height: 380, alignment: .topTrailing)
                let renderer = ImageRenderer(content: surface)
                renderer.scale = 1
                guard let image = renderer.cgImage else { preconditionFailure("Dock render failed") }
                let bitmap = NSBitmapImageRep(cgImage: image)
                let size = geometry.size(progress: progress, historyExpanded: history)
                let bounds = CGRect(x: 368 - size.width, y: 0, width: size.width, height: size.height)
                let silhouette = RoundedRectangle(cornerRadius: 22, style: .continuous).path(in: bounds)
                let edge = silhouette.strokedPath(StrokeStyle(lineWidth: 4))
                for vertical in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
                    for horizontal in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                        let point = CGPoint(x: Double(horizontal) + 0.5, y: Double(vertical) + 0.5)
                        if !silhouette.contains(point) && !edge.contains(point) {
                            let alpha = bitmap.colorAt(x: horizontal, y: vertical)?.alphaComponent ?? 0
                            precondition(alpha <= 4.0 / 255, "Dock content escaped at \(progress): \(point)")
                        }
                    }
                }
            }
        }
    }

    static func render() {
        let geometry = CookieDockGeometry(availableSize: CGSize(width: 1440, height: 900))
        for (name, progress, history) in [("collapsed", CGFloat(0), false), ("opening", 0.5, false), ("speaking", 1, false), ("activity", 1, true)] {
            snapshot("cookie-dock-\(name)", content: makeSurface(geometry: geometry, progress: progress, history: history).padding(20))
        }
        let narrow = CookieDockGeometry(availableSize: CGSize(width: 320, height: 350))
        snapshot("cookie-dock-narrow", content: makeSurface(geometry: narrow, progress: 1, history: true).padding(16))
        let stages = HStack(alignment: .top, spacing: 26) {
            makeSurface(geometry: geometry, progress: 0, history: false)
            makeSurface(geometry: geometry, progress: 0.5, history: false)
            makeSurface(geometry: geometry, progress: 1, history: false)
        }.padding(28).background(Color(white: 0.06))
        snapshot("cookie-dock-preview", content: stages)
    }

    private static func nativeAnimationReportsItsVisibleBounds() {
        let state = CookieDockState()
        state.availableSize = CGSize(width: 800, height: 500)
        state.entries = [entry]
        var regions: [CGRect] = []
        state.geometryChanged = { if let rect = $0[entry.id] { regions.append(rect) } }
        let size = CookieDockGeometry(availableSize: state.availableSize).canvas
        let hosting = NSHostingView(rootView: AgentDockView(state: state, stop: { _ in }, open: { _ in }))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        precondition(regions.last?.width == 52, "Collapsed dock must report its face, not the whole window")
        let originalFrame = window.frame
        state.expandedID = entry.id
        RunLoop.current.run(until: Date().addingTimeInterval(0.65))
        precondition(abs((regions.last?.width ?? 0) - 320) < 1, "Expanded dock must report its card")
        precondition(regions.contains { $0.width > 60 && $0.width < 310 }, "Hit region must follow intermediate animation frames")
        precondition(window.frame == originalFrame, "The native window must not resize during expansion")
        regions.removeAll()
        state.expandedID = nil
        RunLoop.current.run(until: Date().addingTimeInterval(0.65))
        precondition(abs((regions.last?.width ?? 0) - 52) < 1, "Collapse must return to the face")
        precondition(regions.contains { $0.width > 60 && $0.width < 310 }, "Collapse must also animate its hit region")
        window.close()
    }

    private static func makeSurface(geometry: CookieDockGeometry, progress: CGFloat, history: Bool) -> some View {
        CookieDockSurface(entry: entry, agent: nil, geometry: geometry, progress: progress,
                          historyProgress: history ? 1 : 0, expand: {}, collapse: {}, toggleHistory: {}, stop: {}, open: {})
            .environment(\.colorScheme, .dark)
    }

    private static func snapshot<Content: View>(_ name: String, content: Content) {
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { preconditionFailure("Could not render \(name)") }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/\(name).png")
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output)
        window.close()
        print("Rendered build/\(name).png")
    }
}
