//
//  GlobalPushToTalkShortcutMonitor.swift
//  EnkeonVoiceKit (from Cookie, cookie-harness 8ffefde)
//
//  The one keyboard for voice: an active CGEvent tap that sees every chord.
//    Fn (or ⌃⌘ without Fn)  dictate      + ⌃ (⌥ with ⌃⌘) edit   + ⇧ keep in memory
//    Fn+⌥ (or ⌃⌥)           talk to Cookie
//    ⌥⌘ tapped alone         conversation on/off       ⌥⇧ held   explain what's under the pointer
//

import AppKit
import Combine
import CoreGraphics
import Foundation

public final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    public let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    public let cancellationPublisher = PassthroughSubject<Void, Never>()
    /// ⌃⌘ turned out to be the start of a Mac shortcut (⌃⌘Q, ⌃⌘F, ⌃⌘Space…) after dictation began:
    /// drop what was heard, type nothing.
    public let dictationAbortPublisher = PassthroughSubject<Void, Never>()
    /// ⌃⌘ is also how a dozen Mac shortcuts begin, so dictation starts only once the two keys
    /// have been held this long with no other key; a key inside the window makes it a shortcut.
    static let dictationArmDelay: TimeInterval = 0.2
    private var dictationArm: Timer?
    private var awaitsShortcutRelease = false
    public private(set) var isDictationShortcut = false
    /// ⌥⌘ tapped on their own (no other key): conversation mode on or off.
    public let conversationTogglePublisher = PassthroughSubject<Void, Never>()
    private var conversationGesture = ConversationGesture()
    private var conversationChordBlocked = false
    /// Hover to explain: whether ⌥⇧ are held on their own, sent on every modifier change.
    public let hoverShortcutPublisher = PassthroughSubject<Bool, Never>()
    /// A key typed while ⌥⇧ are held (they type symbols): no hover until they are let go.
    private var hoverTypedOver = false
    /// Fn+Space while dictating with Fn: keep listening after the keys come up; ✓ or Fn again ends it.
    let handsFreePublisher = PassthroughSubject<Void, Never>()
    /// ⇧ was held at some point during this dictation: it goes to Enkeon's memory, not into the field.
    private(set) var memoryRequested = false
    /// Editing is explicit and fixed when the chord arms; release order cannot change it.
    private(set) var editRequested = false
    private(set) var conflictingModifiers = false
    enum Recovery { case copy, paste }
    let recoveryPublisher = PassthroughSubject<Recovery, Never>()
    let lateEditModifierPublisher = PassthroughSubject<Void, Never>()
    private var armedFlags: CGEventFlags = []
    /// Asked first on every key-down while a dictation preview is showing; `true` swallows the key.
    var previewKey: ((CGEvent) -> Bool)?

    /// The two chords that dictate. Fn (Globe) alone works only on Apple keyboards — a third-party
    /// keyboard's Fn never reaches macOS — so ⌃⌘ is always there too. ⇧ may be added to either.
    /// Fn with ⌥ is not dictation: it is Talk to Cookie.
    enum Chord: Equatable { case controlCommand, fn }
    static func chord(_ raw: UInt64) -> Chord? {
        let flags = CGEventFlags(rawValue: raw)
        if flags.contains([.maskControl, .maskCommand]) { return .controlCommand }
        if flags.contains(.maskSecondaryFn) && flags.isDisjoint(with: [.maskCommand, .maskAlternate]) { return .fn }
        return nil
    }
    /// What a chord does, for Settings and the checks.
    public enum VoiceChord: Equatable { case dictate, edit, memory, talk }
    public static func voiceChord(_ raw: UInt64) -> VoiceChord? {
        let flags = CGEventFlags(rawValue: raw)
        if requestsTalk(flags) { return .talk }
        guard chord(raw) != nil else { return nil }
        if requestsEdit(flags) { return .edit }
        return flags.contains(.maskShift) ? .memory : .dictate
    }
    static func requestsTalk(_ flags: CGEventFlags) -> Bool {
        BuddyPushToTalkShortcut.talkHeld(NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)))
    }
    /// macOS's own "Press 🌐 key to" (System Settings → Keyboard). Anything but Do Nothing also fires
    /// when Fn is let go after dictating: Apple dictation, the emoji picker or an input-source switch.
    /// `usage` is `AppleFnUsageType` (0 Do Nothing, 1 input source, 2 emoji, 3 dictation); absent means
    /// the factory setting, which is not Do Nothing.
    public static func globeKeyConflict(usage: Int?) -> String? {
        guard usage != 0 else { return nil }
        let what: String
        switch usage {
        case 1: what = "changes the input source"
        case 3: what = "starts Apple's dictation"
        default: what = "opens Emoji & Symbols"
        }
        return "Your 🌐 key also \(what) when you let go of Fn. In System Settings → Keyboard, set “Press 🌐 key to” to Do Nothing."
    }
    public static func globeKeyConflict() -> String? {
        globeKeyConflict(usage: UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int)
    }
    /// ⌥⇧ on their own: explain what's under the pointer.
    public static func hoverHeld(_ raw: UInt64) -> Bool {
        let flags = CGEventFlags(rawValue: raw)
        return flags.contains([.maskAlternate, .maskShift]) && flags.isDisjoint(with: [.maskControl, .maskCommand, .maskSecondaryFn])
    }
    static func requestsEdit(_ flags: CGEventFlags) -> Bool {
        switch chord(flags.rawValue) {
        case .fn: return flags.contains(.maskControl)
        case .controlCommand: return flags.contains(.maskAlternate)
        case nil: return false
        }
    }
    public static func dictationHeld(_ raw: UInt64) -> Bool { chord(raw) != nil }
    private static let spaceKeyCode: UInt16 = 49
    private var activeShortcutHeld: Bool {
        isDictationShortcut ? Self.dictationHeld(CGEventSource.flagsState(.combinedSessionState).rawValue) : BuddyPushToTalkShortcut.isPhysicallyHeld
    }

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published public private(set) var isShortcutCurrentlyPressed = false
    /// While pressed, checks the keys themselves: the system can drop the
    /// release event (tap disabled for a slow main thread, secure input), and
    /// a press that never ends would keep listening and swallow the next press.
    private var releaseWatchdog: Timer?

    public init() {}

    deinit {
        stop()
    }

    /// True while the event tap is live: the shortcut works. False until Accessibility and Input
    /// Monitoring are granted (the tap can't be created before).
    public var isRunning: Bool { globalEventTap.map(CFMachPortIsValid) ?? false }

    public func start() {
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

        // An active tap is required: Fn+Space and recovery keys must not also
        // execute in the foreground app. A listen-only fallback cannot promise that.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let globalEventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                                     eventsOfInterest: eventMask, callback: eventTapCallback, userInfo: userInfo) else {
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

    public func stop() {
        if isShortcutCurrentlyPressed { cancellationPublisher.send(()) }
        conversationGesture.reset()
        conversationChordBlocked = false
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

    public func cancelUntilRelease() {
        if conversationGesture.held { conversationChordBlocked = true }
        conversationGesture.reset()
        awaitsShortcutRelease = awaitsShortcutRelease || isShortcutCurrentlyPressed || dictationArm != nil
        disarmDictation()
        setPressed(false)
    }

    /// The arming window passed: ⌃⌘ are still held (read from the keys unless a check says) and no
    /// other key came, so this is dictation.
    public func confirmDictation(held: Bool? = nil) {
        guard dictationArm != nil else { return }
        editRequested = Self.requestsEdit(armedFlags)
        memoryRequested = armedFlags.contains(.maskShift)
        conflictingModifiers = editRequested && memoryRequested
        disarmDictation()
        guard !isShortcutCurrentlyPressed, !awaitsShortcutRelease,
              held ?? Self.dictationHeld(CGEventSource.flagsState(.combinedSessionState).rawValue) else { return }
        isDictationShortcut = true
        setPressed(true)
        shortcutTransitionPublisher.send(.pressed)
    }

    /// The keys may now come up without ending the dictation.
    private func lockHandsFree() {
        guard isShortcutCurrentlyPressed, isDictationShortcut else { return }
        setPressed(false)
        awaitsShortcutRelease = true
        handsFreePublisher.send(())
    }

    private func disarmDictation() {
        dictationArm?.invalidate()
        dictationArm = nil
    }

    /// Someone else saw the keys let go (circle select's own check): end the
    /// press here too, so this monitor's state never disagrees with the keys.
    public func releaseIfNotHeld() {
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

    public func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            // Events were lost, not cancelled: a reply or speech in progress
            // carries on, and a press in progress ends when the keys do (the watchdog).
            print("🎙️ Global push-to-talk: event tap interrupted (\(eventType.rawValue))")
            conversationGesture.reset()
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            if awaitsShortcutRelease && !activeShortcutHeld { awaitsShortcutRelease = false }
            return Unmanaged.passUnretained(event)
        }


        // Synthetic copy/paste must not cancel the user's gesture or recursively trigger recovery.
        if event.getIntegerValueField(.eventSourceUserData) == TextInsertion.ownEventMark {
            return Unmanaged.passUnretained(event)
        }
        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = event.flags.intersection([.maskControl, .maskCommand, .maskAlternate, .maskShift, .maskSecondaryFn])
        if eventType == .keyDown, modifiers == [.maskControl, .maskCommand], [8, 9].contains(eventKeyCode) {
            cancelUntilRelease()
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                recoveryPublisher.send(eventKeyCode == 8 ? .copy : .paste)
            }
            return nil
        }
        let hoverHeld = Self.hoverHeld(event.flags.rawValue)
        if eventType == .keyDown && hoverHeld { hoverTypedOver = true }
        if !hoverHeld { hoverTypedOver = false }
        if eventType == .flagsChanged || hoverTypedOver { hoverShortcutPublisher.send(hoverHeld && !hoverTypedOver) }
        if eventType == .keyDown, let previewKey, previewKey(event) { return nil }
        if eventType == .keyDown && eventKeyCode == 53 {
            if isShortcutCurrentlyPressed { print("🎙️ Global push-to-talk: Escape") }
            cancelUntilRelease()
            cancellationPublisher.send(())
            return Unmanaged.passUnretained(event)
        }
        // ⌥⌘ tapped alone toggles conversation. With ⌃ they are ⌥⌃⌘ (edit, below); with ⇧ or a key,
        // a Mac shortcut, and nothing toggles until both are up.
        // ⌃ always means the dictation chords (⌥⌃⌘ edits), so it is never conversation.
        let conversationKeys = event.flags.contains([.maskAlternate, .maskCommand])
            && event.flags.isDisjoint(with: [.maskSecondaryFn, .maskControl])
        if conversationChordBlocked {
            if event.flags.isDisjoint(with: [.maskAlternate, .maskCommand]) { conversationChordBlocked = false }
            return Unmanaged.passUnretained(event)
        }
        if conversationKeys && event.flags.contains(.maskShift) {
            conversationChordBlocked = true
            conversationGesture.reset()
            return Unmanaged.passUnretained(event)
        }
        let conversationHeld = conversationKeys
        if conversationHeld || conversationGesture.held {
            let typed = eventType == .keyDown
            let toggle = conversationGesture.update(held: conversationHeld, otherKey: typed || event.flags.contains(.maskControl))
            if typed { conversationChordBlocked = true; conversationGesture.reset() }
            if toggle { conversationTogglePublisher.send(()) }
            if conversationHeld || typed { return Unmanaged.passUnretained(event) }
        }
        if awaitsShortcutRelease {
            if !Self.dictationHeld(event.flags.rawValue) && !BuddyPushToTalkShortcut.isHeld(modifierFlagsRawValue: event.flags.rawValue,
                                               spacePressed: CGEventSource.keyState(.combinedSessionState, key: 49)) {
                awaitsShortcutRelease = false
            }
            return Unmanaged.passUnretained(event)
        }
        if dictationArm != nil, Self.requestsTalk(event.flags) {
            // Fn, then ⌥: Talk to Cookie, not dictation. Falls through to the talk chord below.
            disarmDictation()
        } else if dictationArm != nil {
            armedFlags = event.flags
            if eventType == .keyDown && eventKeyCode == Self.spaceKeyCode && Self.chord(event.flags.rawValue) == .fn && !Self.requestsEdit(event.flags) && !editRequested {
                confirmDictation(held: true)
                lockHandsFree()
                return nil
            }
            if !editRequested, event.flags.contains(.maskShift) { memoryRequested = true }
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
            if eventType == .flagsChanged, (!editRequested && Self.requestsEdit(event.flags)) || Self.requestsTalk(event.flags) {
                // Never silently dictate an instruction when the edit modifier arrived too late.
                setPressed(false)
                awaitsShortcutRelease = true
                lateEditModifierPublisher.send(())
                return Unmanaged.passUnretained(event)
            }
            if eventType == .keyDown && eventKeyCode == Self.spaceKeyCode && Self.chord(event.flags.rawValue) == .fn && !Self.requestsEdit(event.flags) && !editRequested {
                lockHandsFree()
                return nil
            }
            if !editRequested, event.flags.contains(.maskShift) { memoryRequested = true }
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
            armedFlags = event.flags
            editRequested = false
            conflictingModifiers = false
            memoryRequested = event.flags.contains(.maskShift)
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
