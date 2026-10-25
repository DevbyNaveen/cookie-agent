//
//  OverlayWindow.swift
//  Cookie
//
//  System-wide transparent overlay window for blue glowing cursor.
//  One OverlayWindow is created per screen so the cursor buddy
//  seamlessly follows the cursor across multiple monitors.
//

import AppKit
import AVFoundation
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = CookieWindowLevel.pointerOverlay  // Above submenus and pop-ups: Cookie points at them
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

/// Whether the pointer is out of sight. macOS hides it while you type and
/// brings it back on the first move; Cookie follows the same rule, and also
/// fades after a short rest so it never sits on top of what you're reading.
@MainActor
final class CursorPresence: ObservableObject {
    static let shared = CursorPresence()
    @Published private(set) var isAway = false
    /// Keys are going down (not ⌘-shortcuts) and the pointer hasn't moved since.
    @Published private(set) var typing = false

    // ponytail: 2.5s rest before fading; make it a setting if people ask
    private let restDelay: TimeInterval = 2.5
    private var lastLocation = NSEvent.mouseLocation
    private var lastMoveAt = Date()
    private var monitors: [Any] = []
    private var timer: Timer?

    private init() {
        let keyDown: (NSEvent) -> Void = { [weak self] event in
            // ⌘-shortcuts don't hide the pointer; typing does.
            guard !event.modifierFlags.contains(.command) else { return }
            MainActor.assumeIsolated {
                if self?.typing == false { self?.typing = true }
                self?.update()
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyDown) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { keyDown($0); return $0 }) { monitors.append(m) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let location = NSEvent.mouseLocation
        if hypot(location.x - lastLocation.x, location.y - lastLocation.y) > 0.5 {
            lastLocation = location
            lastMoveAt = Date()
            if typing { typing = false }
        }
        update()
    }

    private func update() {
        let away = typing || Date().timeIntervalSince(lastMoveAt) > restDelay
        if away != isAway { isAway = away }
    }
}

// Cursor-like triangle shape (equilateral)
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        // Top vertex
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        // Bottom left vertex
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        // Bottom right vertex
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

// PreferenceKey for tracking bubble size
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it, its label beside the hand
    case pointingAtTarget
    /// Cookie's hand at work: the tip rides the pen while a mark is inked, or rests on a card or
    /// scene as it opens. Its position is set directly (no spring), frame by frame.
    case drawing
}

/// Speech must not replace the teaching pointer with a microphone animation.
enum CookiePointerPresentation {
    static func showsTriangle(voice: CompanionVoiceState, navigation: BuddyNavigationMode) -> Bool {
        voice == .idle || voice == .responding || voice == .processing && navigation != .followingCursor
    }

    static func keepsPoint(voice: CompanionVoiceState) -> Bool { voice == .responding }
}

/// Where Cookie's hand goes when something it shows opens in its own window (a card, a 3D scene).
/// Presenters call `open(at:)` with the window's frame; the pointer on that display glides to the
/// window's corner, rests while it opens, and goes back to the person's cursor.
@MainActor
final class CookieHand: ObservableObject {
    static let shared = CookieHand()

    struct Teaching: Equatable {
        let owner: UUID
        let point: CGPoint
    }
    @Published private(set) var teaching: Teaching?
    func teach(owner: UUID, at point: CGPoint) {
        if let current = teaching, current.owner == owner,
           hypot(current.point.x - point.x, current.point.y - point.y) < 0.35 { return }
        teaching = Teaching(owner: owner, point: point)
    }
    func stopTeaching(owner: UUID) { if teaching?.owner == owner { teaching = nil } }

    struct Visit: Equatable {
        let id = UUID()
        /// AppKit global coordinates, just inside the window's top-left corner.
        let point: CGPoint
    }

    @Published private(set) var visit: Visit?

    func open(at frame: CGRect) {
        visit = Visit(point: CGPoint(x: frame.minX + 14, y: frame.maxY - 18))
    }

    /// The spotlight's cut-out opened: the hand rests just outside its bottom-right corner.
    func rest(beside rect: CGRect) {
        visit = Visit(point: CGPoint(x: rect.maxX + 4, y: rect.minY - 4))
    }

    /// Show, then do: one action Cookie is about to take on the screen.
    struct Act: Equatable {
        let id = UUID()
        /// AppKit global coordinates: where the tip lands and presses.
        let point: CGPoint
        /// A drag's drop point: the hand carries on there while the drag runs.
        let dragTo: CGPoint?
        /// Two to four words beside the hand, e.g. "Clicking Save".
        let label: String
    }

    @Published private(set) var act: Act?
    private var arrival: (id: UUID, continuation: CheckedContinuation<Void, Never>)?
    /// The longest the hand may hold up an action: past it the action runs wherever the hand is.
    static let actTimeout: Duration = .milliseconds(600)

    /// Moves the hand to `point`, presses, and returns once it has. The overlay on that display
    /// answers with `landed`; with no overlay there, or the hand busy pointing, it returns after
    /// `actTimeout` anyway, so the hand never blocks the work.
    func act(at point: CGPoint, dragTo: CGPoint? = nil, label: String) async {
        let act = Act(point: point, dragTo: dragTo, label: label)
        self.act = act
        await withCheckedContinuation { continuation in
            arrival = (act.id, continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.actTimeout)
                self?.landed(act.id)
            }
        }
    }

    /// The overlay's hand has landed and pressed for this act.
    func landed(_ id: UUID) {
        guard let arrival, arrival.id == id else { return }
        self.arrival = nil
        arrival.continuation.resume()
    }

    /// The action ran: the hand stays a moment, so a next action on the same control finds it there.
    func actionFinished() {
        act = nil
    }
}

/// One step of a guided walk-through on screen: the control the person should use, its number,
/// and what to do. `done` ticks the badge once they have.
struct CookieGuideStep: Equatable {
    let id = UUID()
    /// The control, AppKit global.
    let control: CGRect
    let displayFrame: CGRect
    let number: Int
    var instruction: String
    var done = false

    /// The control lit, the rest of its display dimmed.
    var spotlight: CookieSpotlight { CookieSpotlight(rect: control, displayFrame: displayFrame) }

    /// Where the hand's tip rests: just inside the control's lower right, the pointer below it.
    var restingTip: CGPoint { CGPoint(x: min(control.maxX - 6, control.midX + 30), y: control.minY + 6) }
}

// SwiftUI view for the blue glowing cursor pointer.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// triangle when it is. During voice interaction, the triangle is
// replaced by a waveform (listening), spinner (processing), or
// streaming text bubble (responding).
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    /// Follows the person's pointer on this screen's display link.
    @State private var tracking = CookieScreenTicker()
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0
    @ObservedObject private var presence = CursorPresence.shared
    @ObservedObject private var hand = CookieHand.shared
    @ObservedObject private var hover = CookieHoverExplainer.shared
    /// What holds the hand away from the person's cursor: a card or scene opening (`visit`), an
    /// action about to run (`act`), a guided step waiting on the person (`guide`), an element
    /// explained on hover (`hover`); nil when nothing does.
    private enum HandHold { case visit, act, guide, hover, teaching }
    @State private var handHold: HandHold?
    @State private var lastPenMark: UUID?
    /// The pill beside the hand while an action or a guided step holds it.
    @State private var handLabel = ""
    /// The guided step the hand rests on here.
    @State private var guidedStepID: UUID?
    /// Each press of the hand bumps this; the ink ring spreads from `pressPoint`.
    @State private var pressCount = 0
    @State private var pressPoint: CGPoint = .zero

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// The rotation angle of the triangle in degrees. Default is -35° (cursor-like).
    /// Changes to face the direction of travel when navigating to a target.
    @State private var triangleRotationDegrees: Double = -35.0

    /// What Cookie points at, in her ink beside the hand; only when the model named it.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// The hand's flight: a spring on this screen's display link, retargeted when the target moves.
    @State private var flight = CookiePointerFlight()
    /// The pointing this view is showing: the one hold (show the label, then go back) belongs to it,
    /// so a timer from an older pointing can never end a newer one.
    @State private var pointingSession: UUID?
    @State private var pointerTransitionID = UUID()
    @State private var pointingHold: Task<Void, Never>?
    /// The hand's own fade: Reduce Motion, or a target on another screen, crossfades in place
    /// instead of flying.
    @State private var pointerFade: Double = 1

    /// The press cue's dip (`pressHand`).
    @State private var buddyFlightScale: CGFloat = 1.0

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    // MARK: - Onboarding Video Layout

    private let onboardingVideoPlayerWidth: CGFloat = 330
    private let onboardingVideoPlayerHeight: CGFloat = 186

    private let fullWelcomeMessage = "hey! i'm cookie"

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            // The rest of the screen dims while Cookie explains one part of it; marks ink over it.
            CookieSpotlightLayer(spotlight: companionManager.spotlight ?? companionManager.guideStep?.spotlight,
                                 screenFrame: screenFrame, typing: presence.typing)

            // A guided step: its number at the control's corner, ticked once the person has done it.
            if let step = companionManager.guideStep, step.displayFrame == screenFrame {
                CookieGuideBadge(number: step.number, done: step.done)
                    .position(convertScreenPointToSwiftUICoordinates(CGPoint(x: step.control.minX, y: step.control.maxY)))
                    .transition(.scale.combined(with: .opacity))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: step.done)
            }

            // Cookie's drawings on this display.
            if !companionManager.marks.isEmpty {
                CookieMarksLayer(marks: companionManager.marks, screenFrame: screenFrame, onPen: { pen in follow(pen) })
                    .transition(.opacity)
            }

            // Hover to explain: the outline round the element and the answer beside the hand.
            CookieHoverLayer(explanation: hover.explanation, screenFrame: screenFrame)

            // Welcome speech bubble (first launch only)
            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Onboarding video — always in the view tree so opacity animation works
            // reliably. When no player exists or opacity is 0, nothing is visible.
            // allowsHitTesting(false) prevents it from intercepting clicks.
            OnboardingVideoPlayerView(player: companionManager.onboardingVideoPlayer)
                .frame(width: onboardingVideoPlayerWidth, height: onboardingVideoPlayerHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.black.opacity(0.4 * companionManager.onboardingVideoOpacity), radius: 12, x: 0, y: 6)
                .opacity(isCursorOnThisScreen ? companionManager.onboardingVideoOpacity : 0)
                .position(
                    x: cursorPosition.x + 10 + (onboardingVideoPlayerWidth / 2),
                    y: cursorPosition.y + 18 + (onboardingVideoPlayerHeight / 2)
                )
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeInOut(duration: 2.0), value: companionManager.onboardingVideoOpacity)
                .allowsHitTesting(false)

            // Onboarding prompt — "press control + option and say hi" streamed after video ends
            if isCursorOnThisScreen && companionManager.showOnboardingPrompt && !companionManager.onboardingPromptText.isEmpty {
                Text(companionManager.onboardingPromptText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(companionManager.onboardingPromptOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.4), value: companionManager.onboardingPromptOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // What Cookie points at, named by the model, in her ink beside the hand and on screen.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                CookieHandPill(text: navigationBubbleText, hand: cursorPosition, area: CookieMarksLayer.visibleArea(of: screenFrame))
                    .opacity(navigationBubbleOpacity)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
            }

            // Blue triangle cursor — shown when idle or while TTS is playing (responding).
            // All three states (triangle, waveform, spinner) stay in the view tree
            // permanently and cross-fade via opacity so SwiftUI doesn't remove/re-insert
            // them (which caused a visible cursor "pop").
            //
            // During cursor following: fast spring animation for snappy tracking.
            // During navigation: NO implicit animation — the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            // Cookie's triangle rides next to the pointer; its tip points
            // where Cookie is looking, and turns toward a target in flight.
            CookiePointer(size: 16, degrees: triangleRotationDegrees)
                .scaleEffect(buddyFlightScale)
                .opacity(buddyIsVisibleOnThisScreen && CookiePointerPresentation.showsTriangle(voice: companionManager.voiceState, navigation: buddyNavigationMode) && !pointerAway ? cursorOpacity * pointerFade : 0)
                .animation(.easeOut(duration: pointerAway ? 0.1 : 0.2), value: pointerAway)
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(.easeIn(duration: 0.25), value: companionManager.voiceState)
                .animation(
                    buddyNavigationMode == .navigatingToTarget || buddyNavigationMode == .drawing ? nil : .easeInOut(duration: 0.3),
                    value: triangleRotationDegrees
                )

            // What the hand is doing ("Clicking Save") or what the person should do next.
            if handHold == .act || handHold == .guide, !handLabel.isEmpty {
                CookieHandPill(text: handLabel, hand: cursorPosition, area: CookieMarksLayer.visibleArea(of: screenFrame))
                    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: cursorPosition)
                    .transition(.opacity)
            }

            // The ink ring of a press, spreading from the tip.
            CookiePressRipple(trigger: pressCount)
                .position(pressPoint)

            // Listening owns the microphone waveform; speaking keeps Cookie's triangle.
            BlueCursorWaveformView(audioPowerLevel: companionManager.currentAudioPowerLevel,
                                   active: buddyIsVisibleOnThisScreen && companionManager.voiceState == .listening)
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .listening ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            // Blue spinner — shown while the AI is processing (transcription + Claude + waiting for TTS)
            BlueCursorSpinnerView()
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .processing
                    && buddyNavigationMode == .followingCursor ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

            startTrackingCursor()

            // Only show welcome message on first appearance (app start)
            // and only if the cursor starts on this screen
            if isFirstAppearance && isCursorOnThisScreen {
                withAnimation(.easeIn(duration: 2.0)) {
                    self.cursorOpacity = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                    startWelcomeAnimation()
                }
            } else {
                self.cursorOpacity = 1.0
            }
        }
        .onDisappear {
            tracking.stop()
            flight.cancel()
            pointingHold?.cancel()
            companionManager.tearDownOnboardingVideo()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { newLocation in
            // When a UI element location is detected, navigate the buddy to
            // that position so it points at the element.
            guard let screenLocation = newLocation,
                  let displayFrame = companionManager.detectedElementDisplayFrame else {
                // The control went away (or the pointing was cleared): the hand leaves now.
                if newLocation == nil, buddyNavigationMode == .pointingAtTarget
                    || buddyNavigationMode == .navigatingToTarget && !isReturningToCursor {
                    endPointing()
                }
                return
            }

            // Only navigate if the target is on THIS screen
            guard screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
                  || displayFrame == screenFrame else {
                return
            }

            startNavigatingToElement(screenLocation: screenLocation)
        }
        .onChange(of: companionManager.pointPresentationID) { _ in
            guard let location = companionManager.detectedElementScreenLocation,
                  let display = companionManager.detectedElementDisplayFrame else { return }
            guard display == screenFrame else {
                if buddyNavigationMode == .pointingAtTarget || buddyNavigationMode == .navigatingToTarget && !isReturningToCursor {
                    endPointing()
                }
                return
            }
            startNavigatingToElement(screenLocation: location, newPoint: true)
        }
        .onReceive(hand.$teaching) { cue in handTeaches(cue) }
        .onReceive(hand.$visit) { visit in handOpens(visit) }
        .onReceive(hand.$act) { act in handActs(act) }
        .onReceive(companionManager.$guideStep) { step in handGuides(step) }
        .onReceive(hover.$explanation) { explanation in handHovers(explanation) }
    }

    // MARK: - Cookie's hand

    /// Cookie's hand while it draws on this display: the pointer's tip on the pen.
    private func follow(_ pen: CookiePen?) {
        guard let pen else {
            if buddyNavigationMode == .drawing && handHold == nil { returnHandToCursor() }
            return
        }
        // A new spoken mark owns the hand, a lesson's included (a quote read after a part was
        // named). An older mark cannot steal it back from a later point or lesson, and ink must
        // never interrupt an action or a guided step.
        guard handHold != .act, handHold != .guide else { return }
        if handHold == .teaching, lastPenMark == pen.markID { return }
        if lastPenMark != pen.markID {
            lastPenMark = pen.markID
            if buddyNavigationMode == .navigatingToTarget || buddyNavigationMode == .pointingAtTarget {
                finishNavigationAndResumeFollowing()
            }
        }
        guard buddyNavigationMode == .followingCursor || buddyNavigationMode == .drawing else { return }
        let centre = Self.centre(placingTipAt: pen.point, degrees: pen.degrees)
        handHold = nil
        if pen.travelling || buddyNavigationMode != .drawing {
            withAnimation(.spring(response: CookieMarksLayer.lead, dampingFraction: 0.9)) {
                cursorPosition = centre
                triangleRotationDegrees = pen.degrees
            }
        } else {
            cursorPosition = centre
            triangleRotationDegrees = pen.degrees
        }
        buddyNavigationMode = .drawing
    }

    private func handTeaches(_ cue: CookieHand.Teaching?) {
        guard let cue, screenFrame.contains(cue.point) else {
            if handHold == .teaching { returnHandToCursor() }
            return
        }
        guard handHold != .act, handHold != .guide else { return }
        if buddyNavigationMode == .pointingAtTarget || buddyNavigationMode == .navigatingToTarget {
            finishNavigationAndResumeFollowing()
        }
        handHold = .teaching
        buddyNavigationMode = .drawing
        handLabel = ""
        let tip = convertScreenPointToSwiftUICoordinates(cue.point)
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.94)) {
            cursorPosition = Self.centre(placingTipAt: tip, degrees: -35)
            triangleRotationDegrees = -35
        }
    }

    /// A card or a scene opened on this display: the hand goes to its corner, rests while it
    /// opens, then goes back. Reduce Motion keeps the hand with the person.
    private func handOpens(_ visit: CookieHand.Visit?) {
        guard let visit, screenFrame.contains(visit.point), handHold == nil || handHold == .visit,
              buddyNavigationMode == .followingCursor || buddyNavigationMode == .drawing,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let target = convertScreenPointToSwiftUICoordinates(visit.point)
        let degrees = Double(atan2(target.y - cursorPosition.y, target.x - cursorPosition.x)) * 180 / .pi + 90
        buddyNavigationMode = .drawing
        handHold = .visit
        withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) {
            cursorPosition = Self.centre(placingTipAt: target, degrees: degrees)
            triangleRotationDegrees = degrees
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard self.handHold == .visit, self.hand.visit == visit else { return }
            if self.buddyNavigationMode == .drawing { self.returnHandToCursor() }
        }
    }

    /// Show, then do: the hand flies to where Cookie is about to act (already there for another action
    /// on the same control), presses, and only then lets the action run; a drag carries on to its
    /// drop point while it runs. The hand stays a moment after, then goes back.
    private func handActs(_ act: CookieHand.Act?) {
        guard let act else {
            guard handHold == .act else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                guard self.handHold == .act, self.hand.act == nil, self.buddyNavigationMode == .drawing else { return }
                self.returnHandToCursor()
            }
            return
        }
        // Pointing and guiding come first: the operator's wait times out and the action runs anyway.
        guard screenFrame.contains(act.point), handHold != .guide,
              buddyNavigationMode == .followingCursor || buddyNavigationMode == .drawing else { return }
        handLabel = act.label
        let tip = convertScreenPointToSwiftUICoordinates(act.point)
        moveHand(toTip: tip, hold: .act) {
            guard self.hand.act?.id == act.id else { return }
            self.pressHand(at: tip)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pressSeconds) {
                self.hand.landed(act.id)
                guard let dragTo = act.dragTo, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                // The drag itself takes about 0.15 s; the hand rides it.
                withAnimation(.easeInOut(duration: 0.16)) {
                    self.cursorPosition = Self.centre(placingTipAt: self.convertScreenPointToSwiftUICoordinates(dragTo), degrees: -35)
                }
            }
        }
    }

    /// A guided step: the hand flies to the control and stays there, its instruction beside it,
    /// until the step is done or gone. New words on the same step (the nudge) tap the control again.
    private func handGuides(_ step: CookieGuideStep?) {
        guard let step, step.displayFrame == screenFrame else {
            if handHold == .guide { returnHandToCursor() }
            return
        }
        handLabel = step.instruction
        let tip = convertScreenPointToSwiftUICoordinates(step.restingTip)
        if handHold == .guide, guidedStepID == step.id {
            if !step.done { pressHand(at: tip) }
            return
        }
        guard buddyNavigationMode == .followingCursor || buddyNavigationMode == .drawing else { return }
        guidedStepID = step.id
        moveHand(toTip: tip, hold: .guide) {}
    }

    /// Hover to explain: the hand glides beside the element and stays while its answer shows;
    /// another element while the keys are held, and it moves there.
    private func handHovers(_ explanation: CookieHoverExplanation?) {
        guard let explanation, explanation.displayFrame == screenFrame else {
            if handHold == .hover { returnHandToCursor() }
            return
        }
        guard handHold == nil || handHold == .hover,
              buddyNavigationMode == .followingCursor || buddyNavigationMode == .drawing else { return }
        moveHand(toTip: convertScreenPointToSwiftUICoordinates(explanation.restingTip), hold: .hover) {}
    }

    /// How long a press takes: down and back up, with the ring.
    private static let pressSeconds = 0.18

    /// Flies the hand's tip to a point (at most 0.4 s, by distance) and holds it there. Reduce Motion:
    /// it jumps.
    private func moveHand(toTip tip: CGPoint, hold: HandHold, then arrived: @escaping () -> Void) {
        let centre = Self.centre(placingTipAt: tip, degrees: -35)
        let distance = hypot(centre.x - cursorPosition.x, centre.y - cursorPosition.y)
        let alreadyThere = buddyNavigationMode == .drawing && distance < 2
        buddyNavigationMode = .drawing
        handHold = hold
        guard !alreadyThere, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            cursorPosition = centre
            triangleRotationDegrees = -35
            arrived()
            return
        }
        let seconds = min(0.4, max(0.12, Double(distance) / 1800))
        withAnimation(.easeInOut(duration: seconds)) {
            cursorPosition = centre
            triangleRotationDegrees = -35
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: arrived)
    }

    /// The press cue: the pointer dips and springs back while an ink ring spreads from its tip.
    /// Reduce Motion: no cue.
    private func pressHand(at tip: CGPoint) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        pressPoint = tip
        pressCount += 1
        let half = Self.pressSeconds / 2
        withAnimation(.easeIn(duration: half)) { buddyFlightScale = 0.8 }
        DispatchQueue.main.asyncAfter(deadline: .now() + half) {
            withAnimation(.easeOut(duration: half)) { self.buddyFlightScale = 1 }
        }
    }

    private func returnHandToCursor() {
        handHold = nil
        handLabel = ""
        guidedStepID = nil
        buddyNavigationMode = .followingCursor
        let mouse = convertScreenPointToSwiftUICoordinates(NSEvent.mouseLocation)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            triangleRotationDegrees = -35
            cursorPosition = CGPoint(x: mouse.x + 35, y: mouse.y + 25)
        }
    }

    /// The pointer is drawn centred on its position; this puts its tip on a point instead.
    /// Half its height: `CookiePointer(size: 16)` is 16 × 16·√3/2.
    private static func centre(placingTipAt tip: CGPoint, degrees: Double) -> CGPoint {
        let reach = 16 * 0.866 / 2
        let turn = degrees * .pi / 180
        return CGPoint(x: tip.x - reach * sin(turn), y: tip.y + reach * cos(turn))
    }

    /// Whether the buddy triangle should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When another
    /// screen is navigating (detectedElementScreenLocation is set but this
    /// screen isn't the one animating), hide the cursor so only one buddy
    /// is ever visible at a time.
    /// The pointer is hidden (you're typing) or resting: Cookie steps away
    /// too, but only while it is just following — never mid-flight or mid-answer.
    private var pointerAway: Bool {
        presence.isAway && buddyNavigationMode == .followingCursor && companionManager.voiceState == .idle
    }

    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen's BlueCursorView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate buddy
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget, .drawing:
            return true
        }
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        // 60 a second is enough to follow the person's pointer (SwiftUI's spring smooths it).
        tracking.start(on: NSScreen.screens.first { $0.frame == screenFrame }, rate: 60) {
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            // During forward flight or pointing, the buddy is NOT interrupted by
            // mouse movement — it completes its full animation and return flight.
            // Only during the RETURN flight do we allow cursor movement to cancel
            // (so the buddy snaps to following if the user moves while it's flying back).
            if self.buddyNavigationMode == .navigatingToTarget && self.isReturningToCursor {
                let currentMouseInSwiftUI = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
                let distanceFromNavigationStart = hypot(
                    currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                    currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
                )
                if distanceFromNavigationStart > 100 {
                    cancelNavigationAndResumeFollowing()
                }
                return
            }

            // During forward navigation or pointing, just skip cursor tracking
            if self.buddyNavigationMode != .followingCursor {
                return
            }

            // Normal cursor following
            let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            let buddyX = swiftUIPosition.x + 35
            let buddyY = swiftUIPosition.y + 25
            self.cursorPosition = CGPoint(x: buddyX, y: buddyY)
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    /// Starts the hand toward a detected UI element, or — when it is already on its way there or
    /// pointing and the control moved — sends it on to the new place without starting again.
    private func startNavigatingToElement(screenLocation: CGPoint, newPoint: Bool = false) {
        // Don't interrupt welcome animation
        guard !showWelcome || welcomeText.isEmpty else { return }

        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Offset the target so the buddy sits beside the element rather than
        // directly on top of it — 8px to the right, 12px below.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        // Clamp target to screen bounds with padding
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        // The same pointing, its control moved: follow it.
        if !newPoint, buddyNavigationMode == .navigatingToTarget && !isReturningToCursor {
            // A crossfade has no spring to retarget. Restart its destination safely.
            if !flight.isFlying {
                let session = pointingSession
                fly(to: clampedTarget) {
                    if let session, self.pointingSession == session { self.startPointingAtElement(session: session) }
                }
            } else { flight.retarget(clampedTarget) }
            return
        }
        if !newPoint, buddyNavigationMode == .pointingAtTarget {
            fly(to: clampedTarget) {}
            return
        }

        if newPoint { navigationBubbleOpacity = 0 }

        // Record the current cursor position so we can detect if the user
        // moves the mouse enough to cancel the return flight
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        // Enter navigation mode — stop cursor following
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false
        let session = UUID()
        pointingSession = session
        pointingHold?.cancel()

        fly(to: clampedTarget) {
            guard self.pointingSession == session, self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement(session: session)
        }
    }

    /// Moves the hand on a spring (retargetable, on the display's clock). Under Reduce Motion, or
    /// when the person's pointer is on another screen, it fades out, moves and fades in instead:
    /// motion across a screen that tells nothing is left out.
    private func fly(to destination: CGPoint, then arrived: @escaping () -> Void) {
        let transition = UUID()
        pointerTransitionID = transition
        let screen = NSScreen.screens.first { $0.frame == screenFrame }
        let crossfade = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || (!isCursorOnThisScreen && buddyNavigationMode == .navigatingToTarget && !isReturningToCursor)
        guard !crossfade else {
            flight.cancel()
            let session = pointingSession
            withAnimation(.easeOut(duration: 0.12)) { pointerFade = 0 }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard self.pointingSession == session, self.pointerTransitionID == transition else { return }
                self.cursorPosition = destination
                self.triangleRotationDegrees = -35
                withAnimation(.easeIn(duration: 0.15)) { self.pointerFade = 1 }
                arrived()
            }
            return
        }
        flight.onFrame = { position, degrees in
            self.cursorPosition = position
            self.triangleRotationDegrees = degrees
        }
        flight.fly(from: cursorPosition, to: destination, on: screen, arrived: arrived)
    }

    /// Pointing: the label the model gave, if any, beside the hand for 3 s, then back to the cursor.
    /// One hold per pointing, cancelled by whatever replaces it.
    private func startPointingAtElement(session: UUID) {
        buddyNavigationMode = .pointingAtTarget
        print("🎯 Pointer landed on display \(Int(screenFrame.minX)),\(Int(screenFrame.minY))")
        triangleRotationDegrees = -35.0

        navigationBubbleText = companionManager.detectedElementBubbleText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        navigationBubbleOpacity = 1.0
        pointingHold?.cancel()
        let presentation = companionManager.pointPresentationID
        let generation = companionManager.pointGeneration
        pointingHold = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled, self.pointingSession == session,
                  self.companionManager.pointGeneration == generation,
                  CookiePointerPresentation.keepsPoint(voice: self.companionManager.voiceState) {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard !Task.isCancelled, self.pointingSession == session, self.buddyNavigationMode == .pointingAtTarget,
                  self.companionManager.pointGeneration == generation else { return }
            if self.companionManager.pointPresentationID == presentation {
                self.companionManager.clearDetectedElementLocation()
            }
            self.endPointing()
        }
    }

    /// The label fades, then the hand goes back to the person's pointer.
    private func endPointing() {
        pointerTransitionID = UUID()
        flight.cancel()
        let session = pointingSession
        pointingHold?.cancel()
        navigationBubbleOpacity = 0.0
        pointingHold = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, self.pointingSession == session,
                  self.buddyNavigationMode == .pointingAtTarget || self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startFlyingBackToCursor()
        }
    }

    /// Flies the buddy back to the current cursor position after pointing is done.
    private func startFlyingBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorWithTrackingOffset = CGPoint(x: cursorInSwiftUI.x + 35, y: cursorInSwiftUI.y + 25)

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        flight.cancel()
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true
        let session = pointingSession

        fly(to: cursorWithTrackingOffset) {
            guard self.pointingSession == session else { return }
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        finishNavigationAndResumeFollowing()
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        flight.cancel()
        pointingHold?.cancel()
        pointingHold = nil
        pointingSession = nil
        pointerFade = 1
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        triangleRotationDegrees = -35.0
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        companionManager.clearDetectedElementLocation()
    }

    // MARK: - Welcome Animation

    private func startWelcomeAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                // Hold the text for 2 seconds, then fade it out
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                    // Start the onboarding video right after the welcome text disappears
                    self.companionManager.setupOnboardingVideo()
                }
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }
}

// MARK: - Cookie's hand at work

/// The words beside the hand, in Cookie's ink: leading edge just right of the tip, or left of the
/// hand when that would run off the display; always whole inside its visible area.
private struct CookieHandPill: View {
    let text: String
    /// The hand's position in the overlay.
    let hand: CGPoint
    let area: CGRect

    var body: some View {
        CookieOnScreen(point: CGPoint(x: hand.x + 12, y: hand.y + 22), side: .leading, flipX: hand.x - 12, area: area) { _ in
            CookieInkPill(text: text)
        }
        .allowsHitTesting(false)
    }
}

/// A guided step's number in an ink disc, as the `number` mark draws it; a check once done.
private struct CookieGuideBadge: View {
    let number: Int
    let done: Bool

    var body: some View {
        ZStack {
            Circle().fill(CookieMarksLayer.ink).frame(width: 24, height: 24)
            if done {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).transition(.scale.combined(with: .opacity))
            } else {
                Text("\(number)").font(.system(size: 12, weight: .bold, design: .rounded)).transition(.opacity)
            }
        }
        .foregroundStyle(CookieMarksLayer.onInk)
        .shadow(color: .black.opacity(0.38), radius: 2.5, y: 1)
        .allowsHitTesting(false)
    }
}

/// The soft ink ring of a press: spreads and fades in 180 ms each time `trigger` changes, and is
/// invisible otherwise (a keyframe animation stays at its end value, opacity 0).
private struct CookiePressRipple: View {
    let trigger: Int

    private struct Ring {
        var scale: CGFloat = 0.3
        var opacity: Double = 0
    }

    var body: some View {
        Circle()
            .stroke(CookieMarksLayer.ink, lineWidth: 2)
            .frame(width: 30, height: 30)
            .keyframeAnimator(initialValue: Ring(), trigger: trigger) { ring, value in
                ring.scaleEffect(value.scale).opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    LinearKeyframe(0.3, duration: 0)
                    CubicKeyframe(1.4, duration: 0.18)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0.75, duration: 0)
                    LinearKeyframe(0, duration: 0.18)
                }
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Blue Cursor Waveform

/// A small blue waveform that replaces the triangle cursor while
/// the user is holding the push-to-talk shortcut and speaking.
private struct BlueCursorWaveformView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let audioPowerLevel: CGFloat
    var active = true

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || !active)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.overlayCursorBlue)
                        .frame(
                            width: 2,
                            height: barHeight(
                                for: barIndex,
                                timelineDate: reduceMotion ? Date(timeIntervalSinceReferenceDate: 0) : timelineContext.date
                            )
                        )
                }
            }
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// MARK: - Blue Cursor Spinner

/// A small blue spinning indicator that replaces the triangle cursor
/// while the AI is processing a voice input.
private struct BlueCursorSpinnerView: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        DS.Colors.overlayCursorBlue.opacity(0.0),
                        DS.Colors.overlayCursorBlue
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }
}

// MARK: - Onboarding Video Player

/// NSViewRepresentable wrapping an AVPlayerLayer so HLS video plays
/// inside SwiftUI. Uses a custom NSView subclass to keep the player
/// layer sized to the view's bounds automatically.
private struct OnboardingVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerNSView {
        let view = AVPlayerNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerNSView, context: Context) {
        nsView.player = player
    }
}

private class AVPlayerNSView: NSView {
    var player: AVPlayer? {
        didSet { playerLayer.player = player }
    }

    private let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
