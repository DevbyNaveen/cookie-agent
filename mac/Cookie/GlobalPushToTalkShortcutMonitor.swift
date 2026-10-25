//
//  GlobalPushToTalkShortcutMonitor.swift
//  Cookie
//
//  Captures push-to-talk keyboard shortcuts while Cookie is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    let cancellationPublisher = PassthroughSubject<Void, Never>()
    /// ⌃⌘ turned out to be the start of a Mac shortcut (⌃⌘Q, ⌃⌘F, ⌃⌘Space…) after dictation began:
    /// drop what was heard, type nothing.
    let dictationAbortPublisher = PassthroughSubject<Void, Never>()
    /// ⌃⌘ is also how a dozen Mac shortcuts begin, so dictation starts only once the two keys
    /// have been held this long with no other key; a key inside the window makes it a shortcut.
    static let dictationArmDelay: TimeInterval = 0.2
    private var dictationArm: Timer?
    private var awaitsShortcutRelease = false
    private(set) var isDictationShortcut = false
    static func dictationHeld(_ raw: UInt64) -> Bool {
        let flags = CGEventFlags(rawValue: raw)
        return flags.contains([.maskControl, .maskCommand]) && !flags.contains(.maskAlternate)
    }
    private var activeShortcutHeld: Bool {
        isDictationShortcut ? Self.dictationHeld(CGEventSource.flagsState(.combinedSessionState).rawValue) : BuddyPushToTalkShortcut.isPhysicallyHeld
    }

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false
    /// While pressed, checks the keys themselves: the system can drop the
    /// release event (tap disabled for a slow main thread, secure input), and
    /// a press that never ends would keep listening and swallow the next press.
    private var releaseWatchdog: Timer?
    /// Hover to explain: whether ⌥⇧ are held on their own, sent on every modifier change.
    let hoverShortcutPublisher = PassthroughSubject<Bool, Never>()
    /// A key typed while ⌥⇧ are held (they type symbols): no hover until they are let go.
    private var hoverTypedOver = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        // A tap the system invalidated never delivers again: replace it.
        if let globalEventTap {
            if CFMachPortIsValid(globalEventTap) { return }
            stop()
        }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
        print("🎙️ Global push-to-talk: monitoring started")
    }

    func stop() {
        if isShortcutCurrentlyPressed { cancellationPublisher.send(()) }
        disarmDictation()
        setPressed(false)
        hoverShortcutPublisher.send(false)
        awaitsShortcutRelease = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    func cancelUntilRelease() {
        awaitsShortcutRelease = awaitsShortcutRelease || isShortcutCurrentlyPressed || dictationArm != nil
        disarmDictation()
        setPressed(false)
    }

    /// The arming window passed: ⌃⌘ are still held (read from the keys unless a check says) and no
    /// other key came, so this is dictation.
    func confirmDictation(held: Bool? = nil) {
        guard dictationArm != nil else { return }
        disarmDictation()
        guard !isShortcutCurrentlyPressed, !awaitsShortcutRelease,
              held ?? Self.dictationHeld(CGEventSource.flagsState(.combinedSessionState).rawValue) else { return }
        isDictationShortcut = true
        setPressed(true)
        shortcutTransitionPublisher.send(.pressed)
    }

    private func disarmDictation() {
        dictationArm?.invalidate()
        dictationArm = nil
    }

    /// Someone else saw the keys let go (circle select's own check): end the
    /// press here too, so this monitor's state never disagrees with the keys.
    func releaseIfNotHeld() {
        guard isShortcutCurrentlyPressed, !activeShortcutHeld else { return }
        print("🎙️ Global push-to-talk: released (missed release recovered)")
        setPressed(false)
        shortcutTransitionPublisher.send(.released)
    }

    private func setPressed(_ pressed: Bool) {
        isShortcutCurrentlyPressed = pressed
        releaseWatchdog?.invalidate()
        releaseWatchdog = nil
        guard pressed else { return }
        // The tap's run loop is the main one, so this fires on the main thread too.
        let watchdog = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.releaseIfNotHeld() }
        releaseWatchdog = watchdog
        RunLoop.main.add(watchdog, forMode: .common)
    }

    func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            // Events were lost, not cancelled: a reply or speech in progress
            // carries on, and a press in progress ends when the keys do (the watchdog).
            print("🎙️ Global push-to-talk: event tap interrupted (\(eventType.rawValue))")
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            if awaitsShortcutRelease && !activeShortcutHeld { awaitsShortcutRelease = false }
            return Unmanaged.passUnretained(event)
        }

        let hoverHeld = CookieHoverShortcut.isHeld(modifierFlagsRawValue: event.flags.rawValue)
        if eventType == .keyDown && hoverHeld { hoverTypedOver = true }
        if !hoverHeld { hoverTypedOver = false }
        if eventType == .flagsChanged || hoverTypedOver { hoverShortcutPublisher.send(hoverHeld && !hoverTypedOver) }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if eventType == .keyDown && eventKeyCode == 53 {
            if isShortcutCurrentlyPressed { print("🎙️ Global push-to-talk: Escape") }
            cancelUntilRelease()
            cancellationPublisher.send(())
            return Unmanaged.passUnretained(event)
        }
        if awaitsShortcutRelease {
            if !Self.dictationHeld(event.flags.rawValue) && !BuddyPushToTalkShortcut.isHeld(modifierFlagsRawValue: event.flags.rawValue,
                                               spacePressed: CGEventSource.keyState(.combinedSessionState, key: 49)) {
                awaitsShortcutRelease = false
            }
            return Unmanaged.passUnretained(event)
        }
        if dictationArm != nil {
            if eventType == .keyDown {
                // ⌃⌘ plus a key: a Mac shortcut. Nothing started, and nothing does until both are up.
                disarmDictation()
                awaitsShortcutRelease = true
            } else if !Self.dictationHeld(event.flags.rawValue) {
                disarmDictation()
            }
            return Unmanaged.passUnretained(event)
        }
        if isShortcutCurrentlyPressed && isDictationShortcut {
            if eventType == .keyDown {
                // A slow shortcut, after dictation had started: it was never meant to be dictated.
                print("🎙️ Dictation: a shortcut key came while ⌃⌘ were held; nothing typed")
                setPressed(false)
                awaitsShortcutRelease = true
                dictationAbortPublisher.send(())
            } else if !Self.dictationHeld(event.flags.rawValue) {
                setPressed(false)
                shortcutTransitionPublisher.send(.released)
            }
            return Unmanaged.passUnretained(event)
        }
        if !isShortcutCurrentlyPressed && eventType == .flagsChanged && Self.dictationHeld(event.flags.rawValue) {
            // The tap's run loop is the main one, so the timer fires on the main thread.
            let arm = Timer(timeInterval: Self.dictationArmDelay, repeats: false) { [weak self] _ in self?.confirmDictation() }
            dictationArm = arm
            RunLoop.main.add(arm, forMode: .common)
            return Unmanaged.passUnretained(event)
        }
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            print("🎙️ Global push-to-talk: pressed")
            isDictationShortcut = false
            setPressed(true)
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            print("🎙️ Global push-to-talk: released")
            setPressed(false)
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }
}
