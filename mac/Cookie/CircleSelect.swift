//
//  CircleSelect.swift
//  Cookie
//
//  Hold ⌃⌥ and drag: a magic trail follows the pointer, a little cookie
//  riding its head and sparkles falling off behind. Let go of the mouse and
//  the loop closes and shimmers; Cookie photographs just that area (in
//  memory, never on disk) and sends it with what you said.
//
//  While the talk keys are held, an event tap takes the mouse (so the drag
//  doesn't also select text or move windows underneath); the moment they are
//  released, every click goes to your apps again. The trail windows are
//  glass and never take a click themselves.
//

import AppKit
import SwiftUI

@MainActor
final class CircleSelectModel: ObservableObject {
    @Published var points: [CGPoint] = []
    @Published var closed = false
    @Published var opacity: Double = 1
}

@MainActor
final class CircleSelectController {
    /// Called with the circled area in global screen coordinates.
    var onRegion: (CGRect) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onShortcutReleased: () -> Void = {}
    var allowsSelectionAt: (CGPoint) -> Bool = { _ in true }

    private var surfaces: [(panel: NSPanel, model: CircleSelectModel, screen: NSScreen)] = []
    private var active = false
    private var dragging: (model: CircleSelectModel, screen: NSScreen)?
    private var mouseTap: CFMachPort?
    private var mouseTapSource: CFRunLoopSource?
    private var releaseWatchdog: Timer?
    private var selectionID = UUID()

    init() {
        rebuild()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            surfaces.forEach { $0.panel.orderFrontRegardless() }
            startMouseTap()
            releaseWatchdog?.invalidate()
            let watchdog = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.active, !self.shortcutIsHeld else { return }
                    print("🎙️ Circle select: recovering a missed shortcut release")
                    self.setActive(false)
                    self.onShortcutReleased()
                }
            }
            releaseWatchdog = watchdog
            RunLoop.main.add(watchdog, forMode: .common)
        } else {
            releaseWatchdog?.invalidate()
            releaseWatchdog = nil
            stopMouseTap()
            if dragging != nil { finishDrag() }
        }
    }

    private var shortcutIsHeld: Bool {
        BuddyPushToTalkShortcut.isHeld(modifierFlagsRawValue: CGEventSource.flagsState(.combinedSessionState).rawValue,
                                      spacePressed: CGEventSource.keyState(.combinedSessionState, key: 49))
    }

    /// Cancel never submits the unfinished selection and immediately gives input back.
    func cancel() {
        active = false
        selectionID = UUID()
        dragging = nil
        releaseWatchdog?.invalidate()
        releaseWatchdog = nil
        stopMouseTap()
        surfaces.forEach {
            $0.model.points = []
            $0.model.closed = false
            $0.panel.orderOut(nil)
        }
    }

    // MARK: - Mouse tap

    private func startMouseTap() {
        if let mouseTap { CGEvent.tapEnable(tap: mouseTap, enable: true); return }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                    .rightMouseDown, .rightMouseDragged, .rightMouseUp, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<CircleSelectController>.fromOpaque(userInfo).takeUnretainedValue()
            let swallow = MainActor.assumeIsolated { controller.handle(type: type, event: event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            print("⚠️ Circle select: couldn't create mouse tap (Accessibility off?)")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        mouseTap = tap
        mouseTapSource = source
    }

    /// Gone for good (Accessibility revoked); a new one is made if it comes back.
    func tearDown() {
        cancel()
        if let mouseTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), mouseTapSource, .commonModes) }
        mouseTapSource = nil
        if let mouseTap { CGEvent.tapEnable(tap: mouseTap, enable: false); CFMachPortInvalidate(mouseTap) }
        mouseTap = nil
        dragging = nil
    }

    private func stopMouseTap() {
        if let mouseTap, CGEvent.tapIsEnabled(tap: mouseTap) {
            CGEvent.tapEnable(tap: mouseTap, enable: false)
        }
    }

    /// Returns true when the event was ours and must not reach the app underneath.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        // Disabling our tap can itself deliver tapDisabledByUserInput. Once
        // selection ended, that notification must not cancel speech or disable
        // the tap again (which would enqueue another cancellation notification).
        guard active else { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            print("🎙️ Circle select: event tap interrupted (\(type.rawValue)), active: \(active)")
            cancel()
            let cancelledSelectionID = selectionID
            Task { [weak self] in
                guard let self, self.selectionID == cancelledSelectionID, !self.active else { return }
                self.onCancel()
            }
            return false
        }
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                cancel()
                Task { onCancel() }
            }
            return false
        }
        guard shortcutIsHeld else {
            setActive(false)
            Task { onShortcutReleased() }
            return false
        }
        // CGEvent: top-left of the main display, y down. AppKit: bottom-left, y up.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let global = CGPoint(x: event.location.x, y: mainHeight - event.location.y)
        switch type {
        case .leftMouseDown, .rightMouseDown:
            guard allowsSelectionAt(global) else { return false }
            guard let surface = surfaces.first(where: { $0.screen.frame.contains(global) }) else { return false }
            beginDrag(at: local(global, in: surface.screen), model: surface.model, screen: surface.screen)
        case .leftMouseDragged, .rightMouseDragged:
            guard dragging != nil else { return false }
            if let screen = dragging?.screen { moveDrag(to: local(global, in: screen)) }
        case .leftMouseUp, .rightMouseUp:
            guard dragging != nil else { return false }
            finishDrag()
        default:
            return false
        }
        return true
    }

    /// Global AppKit point → the trail view's top-left coordinates.
    private func local(_ global: CGPoint, in screen: NSScreen) -> CGPoint {
        CGPoint(x: global.x - screen.frame.minX, y: screen.frame.maxY - global.y)
    }

    private func rebuild() {
        cancel()
        surfaces.forEach { $0.panel.orderOut(nil) }
        surfaces = NSScreen.screens.map { screen in
            let model = CircleSelectModel()
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

            let host = NSHostingView(rootView: MagicTrailView(model: model))
            host.frame = NSRect(origin: .zero, size: screen.frame.size)
            panel.contentView = host
            panel.setFrame(screen.frame, display: false)
            return (panel, model, screen)
        }
    }

    private func beginDrag(at point: CGPoint, model: CircleSelectModel, screen: NSScreen) {
        selectionID = UUID()
        surfaces.forEach { $0.model.points = []; $0.model.closed = false }
        model.closed = false
        model.opacity = 1
        model.points = [point]
        dragging = (model, screen)
    }

    private func moveDrag(to point: CGPoint) {
        guard let model = dragging?.model else { return }
        if let last = model.points.last, hypot(point.x - last.x, point.y - last.y) < 2 { return }
        model.points.append(point)
        if model.points.count > 512 {
            model.points = model.points.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        }
    }

    private func finishDrag() {
        guard let (model, screen) = dragging else { return }
        dragging = nil
        let xs = model.points.map(\.x), ys = model.points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
              maxX - minX > 24 || maxY - minY > 24 else {
            model.points = []   // ponytail: a click, not a circle
            return
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { model.closed = true }

        // View coordinates are top-left; the screen is bottom-left.
        let padding: CGFloat = 12
        let region = CGRect(x: screen.frame.minX + minX - padding,
                            y: screen.frame.maxY - maxY - padding,
                            width: maxX - minX + padding * 2,
                            height: maxY - minY + padding * 2)
        let finishedSelectionID = selectionID
        Task { [weak self] in
            guard let self, self.selectionID == finishedSelectionID else { return }
            self.onRegion(region)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard self?.selectionID == finishedSelectionID else { return }
            withAnimation(.easeOut(duration: 0.45)) { model.opacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard self?.selectionID == finishedSelectionID, model.closed else { return }
                model.points = []
                model.closed = false
            }
        }
    }
}

// MARK: - The trail

private struct MagicTrailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: CircleSelectModel

    private static let colors: [Color] = [
        Color(red: 0.42, green: 0.62, blue: 1.0),
        Color(red: 0.98, green: 0.52, blue: 0.78),
        Color(red: 1.0, green: 0.80, blue: 0.38),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || model.points.isEmpty)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, _ in
                draw(in: &ctx, t: t)
            } symbols: {
                CookiePointer(size: 15).tag(0)
            }
        }
        .opacity(model.opacity)
        .allowsHitTesting(false)
    }

    private func draw(in ctx: inout GraphicsContext, t: Double) {
        let points = model.points
        guard points.count > 1 else { return }
        var path = Self.smooth(points)
        if model.closed { path.closeSubpath() }
        let bounds = path.boundingRect
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: Self.colors),
            startPoint: CGPoint(x: bounds.minX, y: bounds.minY),
            endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)
        )
        let round = StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)

        if model.closed {
            ctx.fill(path, with: .color(Self.colors[0].opacity(0.10 + 0.05 * sin(t * 6))))
        }
        // Glow, colour, then a bright core that marches once the loop closes.
        var glow = ctx
        glow.addFilter(.blur(radius: 9))
        glow.opacity = 0.75
        glow.stroke(path, with: shading, style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round))
        ctx.stroke(path, with: shading, style: round)
        ctx.stroke(path, with: .color(.white.opacity(0.9)),
                   style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round,
                                      dash: model.closed ? [7, 9] : [], dashPhase: -t * 70))

        // Sparkles shed behind the head, drifting and twinkling.
        let count = points.count
        for index in stride(from: max(0, count - 90), to: count, by: 2) {
            let seed = Double(index) * 12.9898
            let random = { (k: Double) in (sin(seed * k) * 43758.5453).truncatingRemainder(dividingBy: 1).magnitude }
            let age = Double(count - index) / 90
            let angle = random(1.3) * .pi * 2
            let drift = 6 + 22 * age * random(2.1)
            let center = CGPoint(x: points[index].x + cos(angle) * drift, y: points[index].y + sin(angle) * drift + age * 10)
            let twinkle = 0.5 + 0.5 * sin(t * (6 + 6 * random(3.7)) + seed)
            let alpha = (1 - age) * twinkle
            guard alpha > 0.05 else { continue }
            let size = 2 + 4.5 * random(5.3)
            let color = index % 3 == 0 ? Color.white : Self.colors[index % Self.colors.count]
            ctx.fill(Self.star(at: center, radius: size), with: .color(color.opacity(alpha)))
        }

        // The head: a soft light with Cookie riding it.
        if !model.closed, let head = points.last {
            var halo = ctx
            halo.addFilter(.blur(radius: 8))
            halo.fill(Path(ellipseIn: CGRect(x: head.x - 14, y: head.y - 14, width: 28, height: 28)),
                      with: .color(.white.opacity(0.55)))
            if let cookie = ctx.resolveSymbol(id: 0) {
                var spun = ctx
                spun.translateBy(x: head.x, y: head.y)
                spun.rotate(by: .radians(t * 3))
                spun.draw(cookie, at: .zero)
            }
        }
    }

    /// Midpoint quad curves: a hand-drawn line without the jitter.
    private static func smooth(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.move(to: points[0])
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            path.addQuadCurve(to: mid, control: points[i - 1])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// Four-point sparkle.
    private static func star(at c: CGPoint, radius r: Double) -> Path {
        var path = Path()
        for i in 0..<8 {
            let angle = Double(i) * .pi / 4 - .pi / 2
            let length = i % 2 == 0 ? r : r * 0.32
            let point = CGPoint(x: c.x + cos(angle) * length, y: c.y + sin(angle) * length)
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}
