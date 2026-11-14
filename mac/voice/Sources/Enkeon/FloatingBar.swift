import Combine
import AppKit
import EnkeonVoiceKit
import SwiftUI

/// Click-open launcher state; pointer movement never starts recording or opens actions.
@MainActor
final class BarReach: ObservableObject {
    @Published var near = false
    @Published var edge: FloatingBarLayout.Edge = .bottom
    @Published var pointerIdle = false
    var pinned = false
}

/// The bar at the bottom of the screen: a panel that never becomes key or active, so the app the
/// person is typing in keeps its focus and its cursor while they talk.
final class FloatingBarPanel: NSPanel {
    static let size = FloatingBarLayout.panelSize
    private var boundDisplay: NSNumber?
    private var raised = false
    private var dragFromApp = false
    private var hitRegions: [CGRect] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var meetingDragOrigin: CGPoint?
    private var barDragOrigin: CGPoint?
    private var barDragPointer: CGPoint?
    private var lastPointerActivity = ProcessInfo.processInfo.systemUptime

    private let model: AppModel
    private let reach = BarReach()
    private var monitors: [Any] = []
    private var watching: [AnyCancellable] = []

    init(model: AppModel) {
        self.model = model
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        acceptsMouseMovedEvents = true
        let host = NSHostingView(rootView: FloatingBar(onHitRegionsChanged: { [weak self] regions in
            self?.hitRegions = regions
            self?.updateClicks()
        }, onMeetingDrag: { [weak self] delta, ended in self?.moveMeeting(delta, ended: ended) },
           onBarDrag: { [weak self] delta, ended in self?.moveBar(delta, ended: ended) }).environmentObject(model).environmentObject(reach))
        host.frame = NSRect(origin: .zero, size: Self.size)
        contentView = host

        // Observe movement and drags without synthesizing or forwarding user events.
        let track: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved(event) }
        }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp,
                                            .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown]
        monitors = [NSEvent.addGlobalMonitorForEvents(matching: events, handler: track),
                    NSEvent.addLocalMonitorForEvents(matching: events) { track($0); return $0 }].compactMap { $0 }
        watching = [
            Timer.publish(every: 0.25, tolerance: 0.1, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in self?.updatePointerIdle() },
            model.dictation.$phase.sink { [weak self] phase in
                guard let self else { return }
                switch phase {
                case .listening:
                    if !self.raised { self.boundDisplay = self.dictationScreen()?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber }
                    self.raised = true
                    self.cancelHover()
                case .finishing: self.raised = true
                case .idle:
                    self.raised = false
                    if !self.model.meetings.isActive { self.boundDisplay = nil }
                    self.cancelHover()
                case .done: break // Keep the result on the recording's display until dismissed.
                }
                self.place()
                DispatchQueue.main.async { self.updateClicks() }
            },
            reach.$near.sink { [weak self] _ in DispatchQueue.main.async { self?.updateClicks() } },
            model.meetings.$phase.sink { [weak self] phase in
                guard let self else { return }
                if phase != .idle, self.boundDisplay == nil {
                    self.boundDisplay = self.dictationScreen()?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                } else if phase == .idle, !self.raised { self.boundDisplay = nil }
                DispatchQueue.main.async { self.place() }
            },
        ]
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            }
            observers.append((workspace, token))
        }
        let token = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        observers.append((NotificationCenter.default, token))
        updateClicks()
    }

    deinit {
        monitors.forEach(NSEvent.removeMonitor)
        observers.forEach { $0.0.removeObserver($0.1) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func dictationScreen() -> NSScreen? {
        // Prefer the focused app's front window over a pointer parked on another monitor.
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
           let window = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) && ($0[kCGWindowLayer as String] as? Int) == 0 }),
           let bounds = window[kCGWindowBounds as String] as? NSDictionary,
           let rect = CGRect(dictionaryRepresentation: bounds) {
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let appRect = CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
            let selected = NSScreen.screens.max { lhs, rhs in
                let a = lhs.frame.intersection(appRect), b = rhs.frame.intersection(appRect)
                return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
            }
            if let selected, selected.frame.intersects(appRect) { return selected }
        }
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    /// An auto-hidden Dock can leave reserved space in visibleFrame. Use the physical
    /// bottom edge unless the Dock itself is actually visible there.
    private static func usableFrame(for screen: NSScreen) -> CGRect {
        var usable = screen.visibleFrame
        guard usable.minY > screen.frame.minY + 1 else { return usable }
        let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let bottomDockVisible = windows.contains { info in
            guard info[kCGWindowOwnerName as String] as? String == "Dock",
                  info[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.dockWindow)),
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            let dock = CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
            let overlap = dock.intersection(screen.frame)
            return !overlap.isNull && overlap.height > 4 && overlap.width > 40
                && dock.minY <= screen.frame.minY + 2 && dock.maxY < screen.frame.minY + screen.frame.height / 2
        }
        if !bottomDockVisible {
            let upperEdge = usable.maxY
            usable.origin.y = screen.frame.minY
            usable.size.height = upperEdge - usable.minY
        }
        return usable
    }

    func place() {
        guard barDragOrigin == nil else { return }
        let screen = boundDisplay.flatMap { id in
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == id }
        } ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        if raised { boundDisplay = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber }
        setFrame(FloatingBarLayout.frame(in: Self.usableFrame(for: screen), raised: raised || model.meetings.isActive), display: true)
        if model.meetings.isActive, !raised {
            let key = meetingPositionKey(screen)
            if let point = UserDefaults.standard.array(forKey: key) as? [Double], point.count == 2 {
                setFrameOrigin(clamped(CGPoint(x: point[0], y: point[1]), on: screen))
            }
        } else if !raised {
            let key = barPositionKey(screen)
            let edge = UserDefaults.standard.string(forKey: key + ".edge").flatMap(FloatingBarLayout.Edge.init(rawValue:)) ?? .bottom
            let fraction = UserDefaults.standard.object(forKey: key + ".fraction") as? Double ?? 0.5
            reach.edge = edge
            setFrame(FloatingBarLayout.dockedFrame(in: Self.usableFrame(for: screen), edge: edge, fraction: fraction), display: true)
        }
        updateClicks()
    }

    private func meetingPositionKey(_ screen: NSScreen) -> String {
        "enkeon.meeting.position.\(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "main")"
    }
    private func barPositionKey(_ screen: NSScreen) -> String {
        "enkeon.bar.position.\(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "main")"
    }

    private func moveBar(_ delta: CGSize, ended: Bool) {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? self.screen ?? NSScreen.main else { return }
        if barDragOrigin == nil {
            guard model.dictation.phase == .idle else { return }
            barDragOrigin = frame.origin
            barDragPointer = CGPoint(x: pointer.x - delta.width, y: pointer.y + delta.height)
            cancelHover()
        }
        if let origin = barDragOrigin, let start = barDragPointer {
            // Screen coordinates stay stable even as this window moves under the pointer.
            setFrameOrigin(clamped(CGPoint(x: origin.x + pointer.x - start.x,
                                           y: origin.y + pointer.y - start.y), on: screen))
        }
        if ended {
            let area = Self.usableFrame(for: screen)
            let edge = FloatingBarLayout.nearestEdge(to: pointer, in: area)
            let vertical = edge == .left || edge == .right
            let fraction = Double(vertical ? (pointer.y - area.minY) / max(1, area.height) : (pointer.x - area.minX) / max(1, area.width))
            let key = barPositionKey(screen)
            UserDefaults.standard.set(edge.rawValue, forKey: key + ".edge")
            UserDefaults.standard.set(fraction, forKey: key + ".fraction")
            reach.edge = edge
            let target = FloatingBarLayout.dockedFrame(in: area, edge: edge, fraction: fraction)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
                self.animator().setFrame(target, display: true)
            }
            barDragOrigin = nil
            barDragPointer = nil
        }
        updateClicks()
    }
    private func clamped(_ point: CGPoint, on screen: NSScreen) -> CGPoint {
        let area = Self.usableFrame(for: screen)
        return CGPoint(x: min(max(point.x, area.minX), max(area.minX, area.maxX - frame.width)),
                       y: min(max(point.y, area.minY + 16), max(area.minY + 16, area.maxY - frame.height)))
    }
    private func moveMeeting(_ delta: CGSize, ended: Bool) {
        guard let screen = self.screen ?? NSScreen.main else { return }
        if meetingDragOrigin == nil { meetingDragOrigin = frame.origin }
        let origin = meetingDragOrigin ?? frame.origin
        let point = clamped(CGPoint(x: origin.x + delta.width, y: origin.y - delta.height), on: screen)
        setFrameOrigin(point)
        if ended {
            UserDefaults.standard.set([Double(point.x), Double(point.y)], forKey: meetingPositionKey(screen))
            meetingDragOrigin = nil
        }
    }

    private func cancelHover() {
        reach.near = false
        reach.pinned = false
    }

    private func pointerMoved(_ event: NSEvent) {
        if event.type != .keyDown {
            lastPointerActivity = ProcessInfo.processInfo.systemUptime
            if reach.pointerIdle { reach.pointerIdle = false }
        }
        switch event.type {
        case .keyDown:
            // Observe Escape without swallowing the focused application's keyboard events.
            if event.keyCode == 53 { cancelHover() }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            dragFromApp = event.window !== self
            if dragFromApp && !reach.pinned { reach.near = false }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            dragFromApp = false
        default: break
        }
        updateClicks()
    }

    private func updatePointerIdle() {
        let idle = FloatingBarLayout.shouldHideIdleHandle(
            inactiveFor: ProcessInfo.processInfo.systemUptime - lastPointerActivity,
            engaged: reach.near || reach.pinned || barDragOrigin != nil || NSEvent.pressedMouseButtons != 0,
            active: model.dictation.phase != .idle || model.meetings.isActive
                || model.dictation.answer != nil || model.dictation.recoveryText != nil)
        if reach.pointerIdle != idle {
            reach.pointerIdle = idle
            updateClicks()
        }
    }

    /// SwiftUI reports actual control bounds; the rest of this transparent window passes clicks through.
    private func updateClicks() {
        if barDragOrigin != nil { ignoresMouseEvents = false; return }
        if reach.pointerIdle && !reach.near && model.dictation.phase == .idle && !model.meetings.isActive
            && model.dictation.answer == nil && model.dictation.recoveryText == nil {
            ignoresMouseEvents = true
            return
        }
        let mouse = NSEvent.mouseLocation
        let local = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
        ignoresMouseEvents = !FloatingBarLayout.captures(local, controls: hitRegions, draggingFromApp: dragFromApp)
    }

}

/// The resting pill opens three explicit actions on click. While you talk it becomes a fluid
/// orb whose colors say the stage —
/// teal listening, amber for memory, violet while writing it out, a green breath when done. It never
/// shows text unless something went wrong, never takes focus, and the orb's GPU work stops at rest.
private struct BarHitRegions: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

private extension View {
    func barHitRegion(enabled: Bool = true) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: BarHitRegions.self,
                                   value: enabled ? [geometry.frame(in: .named("floatingBar"))] : [])
        })
    }
}

struct FloatingBar: View {
    var onHitRegionsChanged: ([CGRect]) -> Void = { _ in }
    var onMeetingDrag: (CGSize, Bool) -> Void = { _, _ in }
    var onBarDrag: (CGSize, Bool) -> Void = { _, _ in }
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var reach: BarReach
    @AppStorage(AppModel.barWhenIdleKey) private var showWhenIdle = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var memory = false
    @State private var glow: Color?
    @State private var preparationScale: CGFloat = 1
    @State private var showMemory = false
    @State private var handleHovered = false

    private static let morph = Animation.spring(response: 0.42, dampingFraction: 0.8)
    private let orb: CGFloat = 40

    var body: some View {
        Group {
        if dockedIdle {
            dockedLauncher
        } else {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            if let text = model.dictation.recoveryText {
                recovery(text).transition(.opacity)
            } else if let card = model.dictation.answer {
                answerCard(card).padding(.bottom, 20).transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            } else if (listening || finishing), model.dictation.isAskingMemory {
                notice(finishing ? "Searching your memory…" : "Ask Enkeon · Say your question")
            } else if (listening || finishing), let scope = model.dictation.editScope {
                notice(scope + (finishing ? " · Working…" : " · Say the change"))
            } else if case .done(let message, false) = model.dictation.phase {
                notice(message).transition(.opacity.combined(with: .offset(y: 6)))
            } else if case .idle = model.dictation.phase, reach.near, !model.meetings.isActive {
                launcher.transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.65, anchor: .bottom)).combined(with: .offset(y: 14)))
            }
            HStack(spacing: 10) {
                if model.meetings.isActive && !listening && !finishing {
                    meetingPill
                } else {
                if case .listening(true) = model.dictation.phase {
                    glassButton("X", label: "Cancel") { model.dictation.cancel() }.transition(.scale.combined(with: .opacity))
                }
                shape
                if case .listening(true) = model.dictation.phase {
                    glassButton("Check", label: "Finish") { model.dictation.finishHandsFree() }.transition(.scale.combined(with: .opacity))
                }
                }
            }
            if model.meetings.isActive && (listening || finishing) {
                Text(model.meetings.phase == .paused ? "Meeting paused" : "Meeting recording continues").font(.caption2).foregroundStyle(.white)
            }
        }
        .padding(.bottom, max(2, 10 - size.height / 2))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        }
        .coordinateSpace(name: "floatingBar")
        .onPreferenceChange(BarHitRegions.self, perform: onHitRegionsChanged)
        .animation(Self.morph, value: model.dictation.phase)
        .animation(Self.morph, value: model.dictation.answer)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Self.morph, value: reach.near)
        .onChange(of: reach.near) { _, opened in if !opened { showMemory = false } }
        .onChange(of: showMemory) { _, shown in reach.pinned = shown; if shown { reach.near = true } }
        .onChange(of: model.dictation.phase) { _, phase in
            handleHovered = false
            if phase != .idle { showMemory = false; reach.pinned = false; reach.near = false }
            if case .listening = phase { return }
            if case .done(_, true) = phase { breathe(model.dictation.toMemory ? Color(hex: 0xE0A458) : Theme.live) }
            memory = false
        }
    }

    // MARK: The shape: pill ⇄ orb

    private var dockedIdle: Bool {
        model.dictation.phase == .idle && !model.meetings.isActive
            && model.dictation.answer == nil && model.dictation.recoveryText == nil
    }
    private var verticalHandle: Bool { dockedIdle && (reach.edge == .left || reach.edge == .right) }

    private var dockedLauncher: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            let handle: CGPoint = switch reach.edge {
            case .bottom: CGPoint(x: w / 2, y: h - 22)
            case .top: CGPoint(x: w / 2, y: 22)
            case .left: CGPoint(x: 22, y: h / 2)
            case .right: CGPoint(x: w - 22, y: h / 2)
            }
            let actions: CGPoint = switch reach.edge {
            case .bottom: CGPoint(x: w / 2, y: h - 100)
            case .top: CGPoint(x: w / 2, y: 100)
            case .left: CGPoint(x: 185, y: h / 2)
            case .right: CGPoint(x: w - 185, y: h / 2)
            }
            ZStack {
                shape.position(handle)
                if reach.near {
                    launcher.position(actions)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
    }

    private var shape: some View {
        ZStack {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(Color.black.opacity(0.38))
            // The light on glass: brighter at the top, no outline.
            Capsule().fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.02)], startPoint: .top, endPoint: .center))
            if !isOrb {
                Capsule().fill(LinearGradient(
                    colors: [.white.opacity(handleHovered ? 0.26 : 0), Theme.accent.opacity(handleHovered ? 0.16 : 0)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            if isOrb {
                // Pauses with the rest of the bar: the view (and its GPU work) exists only while active.
                FluidOrb(energy: listening ? model.dictation.level : 0, palette: palette)
                    .onReceive(Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()) { date in
                        latchMemory()
                        preparationScale = preparing
                            ? 1 + 0.025 * CGFloat(sin(date.timeIntervalSinceReferenceDate * 2 * .pi / 1.2))
                            : 1
                    }
                    .padding(2)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(preparing ? preparationScale : (listening ? 1 + min(0.1, model.dictation.level * 0.14) : (finishing ? 0.92 : 1)))
        .shadow(color: isOrb ? .clear : (glow ?? .black).opacity(glow != nil ? 0.35 : 0.2),
                radius: isOrb ? 0 : 6, y: isOrb ? 0 : 2)
        .animation(.easeOut(duration: 0.12), value: model.dictation.level)
        .animation(.easeOut(duration: 0.1), value: preparationScale)
        .animation(.easeInOut(duration: 0.5), value: glow)
        .animation(.easeOut(duration: reach.pointerIdle ? 0.25 : 0.12), value: reach.pointerIdle)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.82), value: handleHovered)
        .opacity(visible ? 1 : 0)
        // Keep the target stable while the glass inside expands: no hover-edge flicker.
        // Only this small control captures clicks; the surrounding panel stays click-through.
        .frame(width: isOrb ? orb : (verticalHandle ? 28 : 80),
               height: isOrb ? orb : (verticalHandle ? 80 : 28), alignment: dockedIdle ? .center : .bottom)
        .contentShape(Capsule())
        .barHitRegion(enabled: visible && model.dictation.phase == .idle)
        .onHover { inside in
            handleHovered = inside && visible && model.dictation.phase == .idle
        }
        .gesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .global)
                .onChanged { value in
                    guard model.dictation.phase == .idle else { return }
                    onBarDrag(value.translation, false)
                }
                .onEnded { value in onBarDrag(value.translation, true) }
                .exclusively(before: TapGesture().onEnded { toggleLauncher() })
        )
        .accessibilityAction { toggleLauncher() }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var size: CGSize {
        if isOrb { return CGSize(width: orb, height: orb) }
        let length: CGFloat = handleHovered && !reduceMotion ? 66 : 52
        let thickness: CGFloat = handleHovered && !reduceMotion ? 15 : 12
        return verticalHandle ? CGSize(width: thickness, height: length) : CGSize(width: length, height: thickness)
    }

    private var listening: Bool { if case .listening = model.dictation.phase { return true }; return false }
    private var preparing: Bool { listening && !model.dictation.isMicrophoneReady }
    private var finishing: Bool { model.dictation.phase == .finishing }
    private var isOrb: Bool { listening || finishing }
    private var visible: Bool {
        if dockedIdle && reach.pointerIdle && !reach.near && !reach.pinned && glow == nil { return false }
        if case .idle = model.dictation.phase { return showWhenIdle || reach.near || glow != nil || model.dictation.answer != nil }
        if case .done(_, false) = model.dictation.phase { return showWhenIdle }
        return true
    }

    private var palette: OrbPalette {
        if finishing { return model.dictation.toMemory ? .memory : .thinking }
        return memory ? .memory : .listening
    }

    private var paletteGlow: Color {
        switch palette {
        case .memory: return Color(hex: 0xE0A458)
        case .thinking: return Color(hex: 0x7A64DA)
        default: return Color(hex: 0x3FA6CC)
        }
    }

    /// ⇧ during a dictation sends it to memory; the orb turns amber the moment it's pressed, and stays.
    private func latchMemory() {
        if listening, !model.dictation.isEditing, !model.dictation.isAskingMemory, NSEvent.modifierFlags.contains(.shift), !memory { withAnimation(.easeInOut(duration: 0.3)) { memory = true } }
    }

    /// A soft glow on the pill as it settles back: done, without a word.
    private func breathe(_ color: Color) {
        glow = color
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            glow = nil
        }
    }

    private var accessibilityText: String {
        switch model.dictation.phase {
        case .listening: if !model.dictation.isMicrophoneReady { return "Starting microphone" }; if let scope = model.dictation.editScope { return scope }; return model.dictation.isAskingMemory ? "Listening to your memory question" : memory ? "Listening, saving to memory" : "Listening"
        case .finishing: return model.dictation.editScope ?? "Writing it out"
        default: return reach.near ? "Close Enkeon actions" : "Open Speak, Meeting and Memory"
        }
    }

    // MARK: Around the shape

    private func toggleLauncher() {
        guard model.dictation.phase == .idle else { return }
        reach.near.toggle()
    }

    private var launcher: some View {
        HStack(alignment: .bottom, spacing: 20) {
            launcherOrb("Microphone", label: "Speak", palette: .listening) {
                reach.near = false
                model.dictation.startHandsFree()
            }
            launcherOrb("ChatCircleText", label: "Meeting", palette: .thinking) {
                reach.near = false
                model.openMeetings(setup: true)
            }
            launcherOrb("Brain", label: "Memory", palette: .memory) {
                showMemory.toggle()
            }
            .background(MemoryPanelAnchor(isPresented: $showMemory, model: model))
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Enkeon actions")
    }

    private func launcherOrb(_ icon: String, label: String, palette: OrbPalette, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LauncherOrbFace(icon: icon, label: label, palette: palette)
        }
        .buttonStyle(LauncherOrbStyle(reduceMotion: reduceMotion))
        .barHitRegion()
        .accessibilityLabel(label == "Speak" ? "Start hands-free dictation" : label == "Meeting" ? "Set up a meeting" : "Open memory")
    }

    private var meetingPill: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").frame(width: 14, height: 24)
                .help("Drag meeting controls")
                .gesture(DragGesture().onChanged { onMeetingDrag($0.translation, false) }.onEnded { onMeetingDrag($0.translation, true) })
            Button("Meeting") { model.meetings.showCard.toggle() }
                .popover(isPresented: $model.meetings.showCard, arrowEdge: .top) {
                    MeetingCompanionView().environmentObject(model)
                }
            MeetingControls().environmentObject(model)
        }
        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.6), in: Capsule())
        .barHitRegion()
    }

    /// Only when something went wrong: what happened, in a line.
    private func notice(_ message: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.warning).frame(width: 6, height: 6)
            Text(message).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(2)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: 320)
        .background(Capsule().fill(.ultraThinMaterial))
        .background(Capsule().fill(Color.black.opacity(0.5)))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }

    /// An answer from memory: the answer, when it was saved, and the two keys. Nothing to click; the
    /// cursor stays in the person's message.
    private func answerCard(_ card: MemoryAnswer.Card) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.text)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.96))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 0) {
                if let date = card.date {
                    Text(date, format: Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
                         ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 12)
                Text("tab insert · esc close").foregroundStyle(.white.opacity(0.32))
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(width: 330, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial))
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.42)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.0)], startPoint: .top, endPoint: .center))
            .allowsHitTesting(false))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("From your memory: \(card.text)")
    }

    private func recovery(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .done(let message, _) = model.dictation.phase {
                Text(message).font(.system(size: 11, weight: .semibold)).lineLimit(2)
            }
            Text(text).font(.system(size: 12)).lineLimit(3)
            HStack {
                Button("Copy") { model.dictation.copyLast() }
                    .accessibilityLabel("Copy the last result")
                Spacer()
                Button("Dismiss") { model.dictation.dismissRecovery() }
            }
            .buttonStyle(.bordered)
        }
        .foregroundStyle(.white.opacity(0.95))
        .padding(12).frame(width: 330)
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.6)))
        .barHitRegion()
    }

    private func glassButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PhosphorIcon(name: symbol, size: 13)
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.ultraThinMaterial))
                .background(Circle().fill(Color.black.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .barHitRegion()
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Hover changes only the artwork; the target stays the same size throughout.
private struct LauncherOrbFace: View {
    let icon: String
    let label: String
    let palette: OrbPalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    private var glow: Color {
        let color = palette.colors[1]
        return Color(red: Double(color.x), green: Double(color.y), blue: Double(color.z))
    }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                FluidOrb(energy: hovered ? 0.18 : 0, palette: palette, framesPerSecond: 24)
                    .allowsHitTesting(false)
                Group {
                    if label == "Memory" { MemoryCardsIcon().frame(width: 19, height: 19) }
                    else { PhosphorIcon(name: icon, size: 19) }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            }
            .frame(width: 50, height: 50)
            .clipShape(Circle())
            .shadow(color: glow.opacity(hovered ? 0.48 : 0), radius: 9, y: 2)
            .brightness(hovered ? 0.045 : 0)
            .scaleEffect(hovered && !reduceMotion ? 1.07 : 1)
            .offset(y: hovered && !reduceMotion ? -2 : 0)
            .accessibilityHidden(true)
            Text(label).font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(hovered ? 1 : 0.8))
        }
        .frame(width: 58)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onDisappear { hovered = false }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.8), value: hovered)
    }
}

private struct LauncherOrbStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .frame(width: 58, height: 70)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
