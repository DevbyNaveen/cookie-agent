//
//  NotchIsland.swift
//  Cookie
//
//  Cookie lives in the notch.
//  closed → sits on the notch; while you talk it widens into a live activity
//  peek   → hover: companion status, latest update, up next and a quick question
//  home   → click: chats + conversation, attached under the notch
//  notice → Cookie finished while you were elsewhere: one card, then gone
//
//  One transparent panel spans the top of the screen. Only the island's own
//  rectangle takes the mouse; everything else passes through.
//

import AppKit
import Combine
import SwiftUI

struct NotchNotice: Equatable {
    let threadID: UUID
    let title: String
    let message: String
    let failed: Bool
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var state: NotchState = .closed
    @Published var notice: NotchNotice?
    @Published var threadCount = 0
    let notchSize: CGSize
    let hasNotch: Bool
    let layout: NotchLayout

    static let peekRows = 3
    init(notchSize: CGSize, hasNotch: Bool, availableSize: CGSize) {
        self.notchSize = notchSize
        self.hasNotch = hasNotch
        layout = NotchLayout(notchSize: notchSize, availableSize: availableSize)
    }

    func topRadius(_ state: NotchState) -> CGFloat { state == .closed ? 6 : 14 }

    func bottomRadius(_ state: NotchState) -> CGFloat {
        switch state {
        case .closed: return 10
        case .peek, .notice: return 24
        case .home: return 30
        }
    }

    func size(_ state: NotchState, voiceActive: Bool) -> CGSize {
        layout.size(for: state, voiceActive: voiceActive, threadCount: threadCount)
    }
}

/// Becomes key so text fields take typing, without activating Cookie:
/// the app you were in stays in front.
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchPanelManager {
    private let companionManager: CompanionManager
    let navigation = CookieNavigation()
    private var screen: NSScreen
    private var model: NotchModel
    private let panel: NotchPanel
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var noticeTimer: Timer?
    private var noticeDeadline: Date?
    private var hoverTimer: Timer?
    private var hoverIntent = NotchHoverIntent()
    private var transitionGeneration = 0
    private var agentDock: CookieAgentDock?
    private lazy var windowController = CookieWindowController(companionManager: companionManager, navigation: navigation)

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        screen = Self.notchScreen()
        model = Self.makeModel(for: screen)
        panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: model.layout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        mountContent()
        panel.orderFrontRegardless()
        installMonitors()
        applyPreferences()
        agentDock = CookieAgentDock()
        NotificationCenter.default.publisher(for: CookieAgentDock.openThread)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.openThread(note.object as? UUID) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.screenChanged() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyPreferences() }
            .store(in: &cancellables)
        companionManager.$threads
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] count in self?.model.threadCount = count }
            .store(in: &cancellables)
        companionManager.$voiceState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.mouseMoved(to: NSEvent.mouseLocation) }
            .store(in: &cancellables)
        companionManager.$isSetupPresented
            .receive(on: RunLoop.main)
            .sink { [weak self] presented in
                guard let self else { return }
                if presented { self.setState(.closed); self.cancelHoverIntent() }
                self.updateMousePassThrough(at: NSEvent.mouseLocation)
            }
            .store(in: &cancellables)
        // What Cookie opened goes in front: the island sits above every window.
        NotificationCenter.default.publisher(for: CookieOpen.didOpen)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.setState(.closed) }
            .store(in: &cancellables)
        // A question for you is never hidden: open the island to show its card.
        companionManager.$pendingApproval
            .receive(on: RunLoop.main)
            .sink { [weak self] approval in
                guard let self, let approval else { return }
                let visible = self.model.state == .home || self.windowController.isFrontmost
                let question = approval.actions.count == 1 ? approval.actions[0].question : "Cookie wants to do \(approval.actions.count) things"
                CookieNotifications.shared.post(.approval, threadID: self.companionManager.currentThreadID,
                                                title: question, body: "", panelOpen: visible)
                guard !visible else { return }
                self.setState(.home)
            }
            .store(in: &cancellables)
        companionManager.replyFinished
            .receive(on: RunLoop.main)
            .sink { [weak self] reply in self?.replyFinished(threadID: reply.threadID, message: reply.message) }
            .store(in: &cancellables)
        WorkStore.shared.follow(companionManager.replyFinished)
        WorkStore.shared.syncAll()
    }

    // MARK: - Layout

    private static func notchScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private static func makeModel(for screen: NSScreen) -> NotchModel {
        let availableSize = CGSize(width: screen.frame.width - 24,
                                   height: screen.frame.maxY - screen.visibleFrame.minY - 16)
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchModel(notchSize: CGSize(width: width, height: screen.safeAreaInsets.top),
                              hasNotch: true, availableSize: availableSize)
        }
        // ponytail: no notch (external display) → the island hangs from the menu bar centre
        return NotchModel(notchSize: CGSize(width: 190, height: NSStatusBar.system.thickness),
                          hasNotch: false, availableSize: availableSize)
    }

    private func mountContent() {
        let hostingView = NSHostingView(rootView: NotchIslandView(
            model: model,
            companionManager: companionManager,
            navigation: navigation,
            setState: { [weak self] in self?.setState($0) },
            openThread: { [weak self] id in self?.openThread(id) },
            popOut: { [weak self] in self?.popOut() }
        ))
        hostingView.sizingOptions = []
        let panelSize = model.layout.panelSize
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        panel.contentView = hostingView
        panel.setFrame(NSRect(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.maxY - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        ), display: true)
        model.threadCount = companionManager.threads.count
    }

    private func screenChanged() {
        let state = model.state
        cancelHoverIntent()
        noticeTimer?.invalidate()
        transitionGeneration += 1
        screen = Self.notchScreen()
        model = Self.makeModel(for: screen)
        mountContent()
        model.state = state == .notice ? .closed : state
        if model.state == .home { panel.makeKey() }
        updateMousePassThrough(at: NSEvent.mouseLocation)
    }

    private func islandRect(_ state: NotchState) -> NSRect {
        let size = model.size(state, voiceActive: companionManager.voiceState != .idle)
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private func applyPreferences() {
        cancelHoverIntent()
        let defaults = UserDefaults.standard
        let wantsDock = defaults.bool(forKey: CK.Key.showInDock)
        let policy: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    // MARK: - State

    func showHome(settingsPage: CookieNavigation.SettingsPage? = nil) {
        navigation.settingsPage = settingsPage
        navigation.preview = nil
        if windowController.isFrontmost { windowController.show() }
        else { setState(.home); panel.makeKey() }
    }

    private func setState(_ state: NotchState) {
        guard state != model.state else { return }
        cancelHoverIntent()
        agentDock?.hidden = state == .home
        switch (model.state, state) {
        case (_, .home): CookieSounds.play(.open)
        case (.home, _): CookieSounds.play(.close)
        case (.closed, .peek): CookieSounds.play(.bloop)
        case (.peek, .closed): CookieSounds.play(.plop)
        default: break
        }
        if state != .notice {
            noticeTimer?.invalidate()
            noticeDeadline = nil
        }
        if state != .home {
            navigation.showsShortcuts = false
            navigation.showsSidebarDrawer = false
        }
        transitionGeneration += 1
        let generation = transitionGeneration
        let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : CK.spring
        withAnimation(animation, completionCriteria: .removed) {
            model.state = state
        } completion: { [weak self] in
            guard let self, self.transitionGeneration == generation,
                  self.model.state != .home, self.panel.isKeyWindow else { return }
            // Return the keyboard only once the island has settled. Ordering the
            // panel out mid-collapse used to expose the outgoing content layers.
            self.panel.orderOut(nil)
            self.panel.orderFrontRegardless()
            self.updateMousePassThrough(at: NSEvent.mouseLocation)
        }
        if state == .home { panel.makeKey() }
        updateMousePassThrough(at: NSEvent.mouseLocation)
    }

    private func openThread(_ id: UUID?) {
        if let id { companionManager.selectThread(id); CookieNotifications.shared.clear(threadID: id) } else { companionManager.newThread() }
        navigation.settingsPage = nil
        navigation.agentPage = nil
        navigation.section = .chats
        setState(.home)
    }

    private func popOut() {
        setState(.closed)
        windowController.show()
    }

    /// A notification was clicked: show that chat.
    func openFromNotification(_ threadID: UUID) {
        openThread(threadID)
        panel.makeKey()
    }

    private func replyFinished(threadID: UUID, message: CompanionChatMessage) {
        let title = companionManager.threads.first { $0.id == threadID }?.title ?? "Cookie"
        CookieNotifications.shared.post(message.role == .failure ? .failure : .reply, threadID: threadID, title: title,
                                        body: message.text, panelOpen: model.state == .home || windowController.isFrontmost)
        // You're here and just got a reply: the moment to ask for notification permission, once.
        CookieNotifications.shared.prepare()
        // Only interrupt when you can't already see the reply.
        guard model.state == .closed || model.state == .peek, !windowController.isFrontmost else { return }
        model.notice = NotchNotice(threadID: threadID, title: title, message: message.text, failed: message.role == .failure)
        setState(.notice)
        noticeTimer?.invalidate()
        noticeDeadline = Date().addingTimeInterval(7)
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 7, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.state == .notice else { return }
                if self.islandRect(.notice).contains(NSEvent.mouseLocation) { return } // reading it: keep
                self.setState(.closed)
            }
        }
    }

    // MARK: - Mouse + keyboard

    private func installMonitors() {
        let moved: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved(to: NSEvent.mouseLocation) }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: moved) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { moved($0); return $0 }) {
            monitors.append(m)
        }
        // Global monitors only see clicks that went to other apps — "outside".
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.state != .closed else { return }
                if !self.islandRect(self.model.state).contains(NSEvent.mouseLocation) {
                    self.setState(.closed)
                }
            }
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            guard event.keyCode == 53, event.window === self?.panel else { return event } // Esc in the island
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.companionManager.voiceState != .idle || self.companionManager.isWorking {
                    self.companionManager.cancelCurrentInteraction()
                } else if self.navigation.showsSidebarDrawer {
                    withAnimation(CK.spring) { self.navigation.showsSidebarDrawer = false }
                } else if self.navigation.showsWorkComposer && self.navigation.settingsPage == nil {
                    withAnimation(CK.quick) { self.navigation.showsWorkComposer = false }
                } else if self.navigation.preview != nil {
                    withAnimation(CK.spring) { self.navigation.preview = nil }
                } else {
                    self.setState(.closed)
                }
            }
            return nil
        }) {
            monitors.append(m)
        }
    }

    private func mouseMoved(to location: NSPoint) {
        guard !companionManager.isSetupPresented else { return }
        if model.state == .peek && companionManager.voiceState != .idle {
            cancelHoverIntent()
            updateMousePassThrough(at: location)
            return
        }
        let peekOnHover = UserDefaults.standard.object(forKey: CK.Key.peekOnHover) as? Bool ?? true
        let previousDeadline = hoverIntent.deadline
        if let destination = hoverIntent.update(
            state: model.state,
            insideTrigger: islandRect(.closed).insetBy(dx: -4, dy: -2).contains(location),
            insideIsland: islandRect(.peek).insetBy(dx: -12, dy: -12).contains(location),
            enabled: peekOnHover && NSEvent.pressedMouseButtons == 0, now: Date.timeIntervalSinceReferenceDate
        ) {
            setState(destination)
        } else if hoverIntent.deadline != previousDeadline || hoverTimer == nil {
            hoverTimer?.invalidate()
            if let deadline = hoverIntent.deadline {
                hoverTimer = Timer.scheduledTimer(withTimeInterval: max(0.001, deadline - Date.timeIntervalSinceReferenceDate), repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.hoverTimer = nil
                        self?.mouseMoved(to: NSEvent.mouseLocation)
                    }
                }
            }
        }
        if model.state == .notice, let noticeDeadline, Date() >= noticeDeadline,
           !islandRect(.notice).insetBy(dx: -12, dy: -12).contains(location) {
            setState(.closed)
        }
        updateMousePassThrough(at: location)
    }

    private func cancelHoverIntent() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverIntent.reset()
    }

    private func updateMousePassThrough(at location: NSPoint) {
        let isVisible = model.hasNotch || model.state != .closed || companionManager.voiceState != .idle
        let inside = !companionManager.isSetupPresented && isVisible && islandRect(model.state).contains(location)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    }
}

// MARK: - Pop-out window

@MainActor
final class CookieWindowController: NSObject, NSWindowDelegate {
    private let companionManager: CompanionManager
    private let navigation: CookieNavigation
    private var window: NSWindow?

    init(companionManager: CompanionManager, navigation: CookieNavigation) {
        self.companionManager = companionManager
        self.navigation = navigation
    }

    var isFrontmost: Bool { window?.isKeyWindow == true && NSApp.isActive }

    func show() {
        let visibleFrame = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame.insetBy(dx: 16, dy: 16)
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: min(1000, visibleFrame.width), height: min(680, visibleFrame.height)),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "Cookie"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // Only the title bar moves the window: a drag on a card must move the card.
            window.isMovableByWindowBackground = false
            window.backgroundColor = NSColor(CK.island)
            window.appearance = NSAppearance(named: .darkAqua)
            window.minSize = NSSize(width: min(480, visibleFrame.width), height: min(400, visibleFrame.height))
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: CookieHomeView(
                mode: .window, companionManager: companionManager, navigation: navigation
            ))
            window.center()
            window.setFrameAutosaveName("CookieWindow")
            window.delegate = self
            self.window = window
        }
        if let window {
            var frame = window.frame
            frame.size.width = min(frame.width, visibleFrame.width)
            frame.size.height = min(frame.height, visibleFrame.height)
            frame.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height)
            window.setFrame(frame, display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Shape

/// The notch silhouette: concave flares into the top edge, rounded bottom.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius, b = min(bottomRadius, (rect.height - t) / 2, (rect.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Island

/// A single silhouette owns every layer, including content being removed.
struct NotchSurface<Content: View>: View {
    let size: CGSize
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    var closed = false
    var capturing = false
    @ViewBuilder let content: Content

    var body: some View {
        let shape = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
        ZStack(alignment: .top) {
            shape
                .fill(closed ? Color.black : CK.island)
                .overlay(shape.stroke(Color.white.opacity(closed ? 0 : 0.07), lineWidth: 0.5))
                .overlay(shape.stroke(Color.white.opacity(capturing ? 0.85 : 0), lineWidth: 1.5)
                    .blur(radius: capturing ? 1.5 : 0))
            content
                .padding(.horizontal, topRadius)
                .frame(width: size.width, height: size.height, alignment: .top)
        }
        .frame(width: size.width, height: size.height)
        // A child-only clip keeps its old bounds during a removal transition.
        .compositingGroup()
        .clipShape(shape)
    }
}

struct NotchIslandView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var lock = ChatLock.shared
    @State private var capturing = false
    @ObservedObject var model: NotchModel
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var navigation: CookieNavigation
    let setState: (NotchState) -> Void
    let openThread: (UUID?) -> Void
    let popOut: () -> Void

    private var voiceActive: Bool { companionManager.voiceState != .idle }

    var body: some View {
        let state = model.state
        let size = model.size(state, voiceActive: voiceActive && state == .closed)
        VStack(spacing: 0) {
            NotchSurface(size: size, topRadius: model.topRadius(state), bottomRadius: model.bottomRadius(state),
                         closed: state == .closed, capturing: capturing) {
                content(state)
            }
            .opacity(!model.hasNotch && state == .closed && !voiceActive ? 0 : 1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(CK.spring, value: voiceActive)
        .animation(CK.spring, value: model.threadCount)
        .onChange(of: companionManager.lastCaptureAt) { _, _ in
            withAnimation(.easeOut(duration: 0.12)) { capturing = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeOut(duration: 0.45)) { capturing = false }
            }
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .cookieMotionPreferences()
    }

    private var contentTransition: AnyTransition {
        if reduceMotion { return .identity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                .animation(.easeOut(duration: 0.16).delay(0.04)),
            removal: .opacity.animation(.easeOut(duration: 0.10))
        )
    }

    @ViewBuilder
    private func content(_ state: NotchState) -> some View {
        switch state {
        case .closed:
            ZStack {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { setState(.home) }
                if voiceActive {
                    LiveActivity(companionManager: companionManager, notchWidth: model.notchSize.width)
                        .transition(.opacity)
                }
            }
            .frame(height: model.notchSize.height)
        case .peek:
            PeekView(model: model, companionManager: companionManager, navigation: navigation,
                     openThread: openThread, openHome: {
                         navigation.settingsPage = nil
                         setState(.home)
                     }, openSettings: {
                         navigation.settingsPage = .general
                         setState(.home)
                     })
                .transition(contentTransition)
        case .home:
            CookieHomeView(mode: .notch, companionManager: companionManager, navigation: navigation,
                           topInset: model.notchSize.height, popOut: popOut, close: { setState(.closed) })
                .transition(contentTransition)
        case .notice:
            if let notice = model.notice {
                NoticeView(notice: lock.isLocked ? NotchNotice(threadID: notice.threadID, title: "Cookie", message: notice.failed ? "Something went wrong." : "Unlock to read the reply.", failed: notice.failed) : notice,
                           agent: CookieAgentStore.shared.agent(companionManager.threads.first { $0.id == notice.threadID }?.agentID),
                           notchHeight: model.notchSize.height,
                           voiceState: companionManager.voiceState,
                           stop: companionManager.stopResponse,
                           open: { openThread(notice.threadID) },
                           dismiss: { setState(.closed) })
                    .transition(contentTransition)
            }
        }
    }
}

/// While you talk: Cookie on the left of the notch, your voice on the right.
private struct LiveActivity: View {
    @ObservedObject var companionManager: CompanionManager
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            CookieAvatar(size: 22, agent: CookieAgentStore.shared.agent(companionManager.currentThread?.agentID), mood: companionManager.characterMood, gaze: companionManager.gazeTowardPointer)
                .frame(maxWidth: .infinity)
            Color.clear.frame(width: notchWidth)
            HStack(spacing: 3) {
                Group {
                    switch companionManager.voiceState {
                    case .processing:
                        ThinkingDots().scaleEffect(0.7)
                    default:
                        VoiceBars(level: companionManager.currentAudioPowerLevel,
                                  live: companionManager.voiceState == .listening)
                    }
                }
                .scaleEffect(0.65).frame(width: 15, height: 18)
                Button(action: companionManager.stopResponse) {
                    Image(systemName: "stop.fill").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(CK.secondary).frame(width: 16, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).cookiePointingCursor().help("Stop · Escape")
                .accessibilityLabel("Stop Cookie")
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct VoiceBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let level: CGFloat
    let live: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { i in
                    let wave = (sin(t * 7 + Double(i) * 1.1) + 1) / 2
                    let energy = live ? max(level, 0.12) : 0.35
                    Capsule()
                        .fill(CK.accent)
                        .frame(width: 2.5, height: 4 + 12 * energy * CGFloat(wave))
                }
            }
            .frame(height: 16)
        }
    }
}

// MARK: - Peek

private struct PeekView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var navigation: CookieNavigation
    let openThread: (UUID?) -> Void
    let openHome: () -> Void
    let openSettings: () -> Void

    @ObservedObject private var lock = ChatLock.shared
    @ObservedObject private var work = WorkStore.shared
    @ObservedObject private var calendar = CookieCalendar.shared
    @ObservedObject private var recorder = CookieRecorder.shared
    @ObservedObject private var cookie = CookieAPI.shared

    private var lines: [PeekLine] {
        var notes: PeekLines.MeetingNotes?
        if case .ready(_, _, let promises, let minutes) = recorder.phase { notes = .init(minutes: minutes, promises: promises) }
        let approval = companionManager.pendingApproval.map { approval in
            approval.actions.count == 1 ? approval.actions[0].question : "\(approval.actions.count) things to approve"
        }
        let meeting = calendar.next
        return [
            PeekLines.latest(threads: companionManager.threads, work: work.items, meetingNotes: notes, chatsLocked: lock.isLocked),
            PeekLines.now(working: companionManager.isWorking, step: companionManager.workingStep,
                          threadTitle: companionManager.currentThread?.title, approval: approval, work: work.items,
                          voiceState: companionManager.voiceState, dozing: companionManager.isDozing,
                          boardNeeds: cookie.needs.map(\.title)),
            PeekLines.upNext(access: calendar.access, meeting: meeting, recalled: meeting.flatMap { calendar.recalled[$0.id] },
                             work: work.items),
        ]
    }

    var body: some View {
        CookiePeekContent(
            lines: lines, isLocked: lock.isLocked,
            needsPermissions: !companionManager.allPermissionsGranted,
            headerHeight: max(model.notchSize.height, 32), showsShortcuts: $navigation.showsShortcuts,
            perform: perform,
            send: { text in
                companionManager.newThread()
                companionManager.sendTypedMessage(text)
                openThread(companionManager.currentThreadID)
            },
            openChats: { openThread(companionManager.currentThreadID ?? companionManager.threads.first?.id) },
            openSettings: openSettings,
            draft: $navigation.peekDraft,
            composerPhase: CookieComposerPhase(voiceState: companionManager.voiceState,
                                              isWorking: companionManager.isWorking, holding: false),
            audioLevel: companionManager.currentAudioPowerLevel,
            gaze: companionManager.gazeTowardPointer
        )
        .onAppear {
            calendar.refresh()
            cookie.refreshIfRunning()
        }
        .overlay(alignment: .topTrailing) {
            if navigation.showsShortcuts {
                ShortcutsCard()
                    .padding(.top, max(model.notchSize.height, 32) + 2)
                    .padding(.trailing, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)))
            }
        }
    }

    private func perform(_ action: PeekAction) {
        switch action {
        case .none: return
        case .openThread(let id): openThread(id)
        case .openWork(let id):
            navigation.openWork = id
            navigation.section = .board
            openHome()
        case .openWorkBoard:
            navigation.openWork = nil
            navigation.section = .board
            openHome()
        case .openMeeting, .review: openThread(companionManager.currentThreadID)
        case .stop: companionManager.stopResponse()
        case .connectCalendar: calendar.connect()
        case .prepare(let meeting):
            companionManager.newThread()
            companionManager.sendTypedMessage(PeekLines.prepareMessage(meeting))
            openThread(companionManager.currentThreadID)
        }
    }
}

private struct ShortcutsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Shortcuts", systemImage: "keyboard")
                .font(.system(size: 12, weight: .semibold))
            row("Talk", trailing: AnyView(HStack(spacing: 5) { Text("Hold").font(.system(size: 11)).foregroundStyle(CK.tertiary); TalkKeys() }))
            row("Open", trailing: AnyView(Text("Click the notch").font(.system(size: 11)).foregroundStyle(CK.secondary)))
            row("Close", trailing: AnyView(KeyCap(label: "esc")))
        }
        .padding(14)
        .frame(width: 250)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.18)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(CK.hairline))
    }

    private func row(_ title: String, trailing: AnyView) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
            trailing
        }
    }
}

// MARK: - Notice

private struct NoticeView: View {
    let notice: NotchNotice
    let agent: CookieAgent?
    let notchHeight: CGFloat
    let voiceState: CompanionVoiceState
    let stop: () -> Void
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: max(notchHeight, 32))
            HStack(alignment: .top, spacing: 12) {
                CookieAvatar(size: 40, agent: agent,
                             mood: voiceState != .idle ? voiceState.cookieMood : notice.failed ? .sad : .happy)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(notice.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Circle().fill(notice.failed ? Color.orange : CK.accent).frame(width: 5, height: 5)
                        Text(voiceState == .responding ? "Speaking" : notice.failed ? "Couldn't reply" : "Replied")
                            .font(.system(size: 11))
                            .foregroundStyle(notice.failed ? Color.orange : CK.secondary)
                    }
                    Text(notice.message)
                        .font(.system(size: 12))
                        .foregroundStyle(CK.secondary)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Spacer()
                        if voiceState != .idle { PillButton(title: "Stop", symbol: "stop.fill", action: stop) }
                        PillButton(title: "Dismiss", action: dismiss)
                        PillButton(title: "Open", primary: true, action: open)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .foregroundStyle(CK.text)
    }
}
