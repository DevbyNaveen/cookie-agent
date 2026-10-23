import AppKit
import Combine
import SwiftUI

@MainActor
final class CookieDockState: ObservableObject {
    @Published var expandedID: UUID?
    @Published var historyID: UUID?
    @Published var entries: [DockEntry] = []
    @Published var availableSize = CGSize(width: 1440, height: 900)
    var geometryChanged: ([UUID: CGRect]) -> Void = { _ in }
    var expand: (UUID) -> Void = { _ in }
    var collapse: () -> Void = {}
}

/// The window stays still while one clipped SwiftUI surface grows out of a face.
/// Only the visible surfaces take mouse events, including during the spring.
@MainActor
final class CookieAgentDock {
    static let openThread = Notification.Name("cookie.agentDock.openThread")
    private static let foregroundID = UUID(uuidString: "C0011E00-0000-0000-0000-000000000001")!

    private let panel: NSPanel
    private let hosting: NSHostingView<AgentDockView>
    private let state = CookieDockState()
    private var cancellables = Set<AnyCancellable>()
    private var monitors: [Any] = []
    private var hitRegions: [UUID: CGRect] = [:]
    private var hoverIntent = CookieDockHoverIntent()
    private var hoverTimer: Timer?
    var hidden = false { didSet { layout() } }

    init(companionManager: CompanionManager) {
        hosting = NSHostingView(rootView: AgentDockView(state: state, stop: { entry in
            if entry.background { CookieBackgroundRuns.shared.stop(entry.id) }
            else { companionManager.stopResponse() }
        }, open: { entry in
            NotificationCenter.default.post(name: Self.openThread, object: entry.threadID)
        }))
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hosting.sizingOptions = []
        panel.contentView = hosting
        state.geometryChanged = { [weak self] regions in
            self?.hitRegions = regions
            self?.updatePointer()
        }
        state.expand = { [weak self] id in self?.expand(id) }
        state.collapse = { [weak self] in self?.collapse() }
        installMonitors()

        let foreground = companionManager.$voiceState.combineLatest(companionManager.$workingStep, companionManager.$workingThreadID, companionManager.$streamingText)
            .map { [weak companionManager] voice, step, threadID, streaming -> DockEntry? in
                guard let manager = companionManager, step != nil || voice == .processing || voice == .responding else { return nil }
                let thread = manager.threads.first { $0.id == threadID }
                let status: String
                let line: String
                switch voice {
                case .responding:
                    status = "Speaking"
                    let reply = thread?.messages.last { $0.role == .assistant }?.text ?? streaming
                    line = reply.isEmpty ? "Reading the reply out loud" : String(reply.prefix(240))
                case .listening:
                    status = "Listening"
                    line = "Say it, then release the keys"
                default:
                    status = "Working"
                    line = step ?? (streaming.isEmpty ? "Thinking through your request…" : String(streaming.prefix(240)))
                }
                return DockEntry(id: Self.foregroundID, agentID: thread?.agentID, threadID: thread?.id,
                                 status: status, step: line, history: manager.workingHistory, background: false)
            }
        foreground.combineLatest(CookieBackgroundRuns.shared.$runs)
            .map { front, runs -> [DockEntry] in
                [front].compactMap { $0 } + runs.map { run in
                    DockEntry(id: run.id, agentID: run.agentID, threadID: run.threadID,
                              status: run.kind == .watcher ? "Watching" : run.kind == .handoff ? "Picking it up" : "Working on its own",
                              step: run.step, history: run.history, background: true)
                }
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] entries in
                guard let self else { return }
                self.state.entries = entries
                if let open = self.state.expandedID, !entries.contains(where: { $0.id == open }) { self.collapse() }
                self.layout()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.layout() }.store(in: &cancellables)
    }

    deinit {
        hoverTimer?.invalidate()
        monitors.forEach(NSEvent.removeMonitor)
    }

    private func layout() {
        guard !state.entries.isEmpty, !hidden,
              let screen = panel.isVisible ? panel.screen ?? NSScreen.main : NSScreen.main ?? NSScreen.screens.first else {
            hoverTimer?.invalidate()
            hoverTimer = nil
            hoverIntent.reset()
            hitRegions = [:]
            state.expandedID = nil
            state.historyID = nil
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
            return
        }
        let visible = screen.visibleFrame
        if state.availableSize != visible.size { state.availableSize = visible.size }
        let geometry = CookieDockGeometry(availableSize: visible.size)
        let size = geometry.canvas
        let frame = NSRect(x: visible.maxX - size.width - 8,
                           y: visible.maxY - min(90, visible.height * 0.12) - size.height,
                           width: size.width, height: size.height)
        // Streaming text never resizes or repositions the native window.
        if panel.frame != frame {
            hosting.frame = NSRect(origin: .zero, size: size)
            panel.setFrame(frame, display: true)
        }
        panel.orderFrontRegardless()
        updatePointer()
    }

    private func expand(_ id: UUID) {
        guard state.entries.contains(where: { $0.id == id }) else { return }
        hoverIntent.reset()
        hoverTimer?.invalidate()
        state.historyID = nil
        state.expandedID = id
    }

    private func collapse() {
        hoverIntent.reset(dismissing: state.expandedID)
        hoverTimer?.invalidate()
        state.expandedID = nil
        // Keep history mounted until the surface has folded; it cannot escape the clip.
        updatePointer(scheduleHover: false)
    }

    private func installMonitors() {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer() }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updatePointer() }
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse() }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { MainActor.assumeIsolated { self?.collapse() } }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { MainActor.assumeIsolated { self?.collapse() } }
            return event
        }) { monitors.append(monitor) }
    }

    private func updatePointer(scheduleHover: Bool = true) {
        guard panel.isVisible, !hidden else { return }
        let location = NSEvent.mouseLocation
        let point = CGPoint(x: location.x - panel.frame.minX, y: panel.frame.maxY - location.y)
        let canvas = CGRect(origin: .zero, size: panel.frame.size)
        let entryID = canvas.contains(point) ? state.entries.first { entry in
            hitRegions[entry.id].map { CookieDockGeometry.contains(point, in: $0) } ?? false
        }?.id : nil
        panel.ignoresMouseEvents = entryID == nil
        guard scheduleHover else { return }
        let previousDeadline = hoverIntent.deadline
        let action = hoverIntent.update(insideID: entryID, expandedID: state.expandedID,
                                        now: Date.timeIntervalSinceReferenceDate, enabled: NSEvent.pressedMouseButtons == 0)
        if let action {
            switch action {
            case .open(let id): expand(id)
            case .close: collapse()
            }
        } else if previousDeadline != hoverIntent.deadline || hoverTimer == nil {
            hoverTimer?.invalidate()
            hoverTimer = nil
            if let deadline = hoverIntent.deadline {
                hoverTimer = Timer.scheduledTimer(withTimeInterval: max(0.001, deadline - Date.timeIntervalSinceReferenceDate), repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.hoverTimer = nil; self?.updatePointer() }
                }
            }
        }
    }
}

struct DockEntry: Identifiable, Equatable {
    let id: UUID
    let agentID: UUID?
    let threadID: UUID?
    let status: String
    let step: String
    let history: [String]
    let background: Bool

    var phase: CookieComposerPhase {
        status == "Speaking" ? .speaking : status == "Listening" ? .listening : .thinking
    }
}
