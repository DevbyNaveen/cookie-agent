//
//  CookieApprentice.swift
//  Cookie
//
//  Opt-in pattern learning from input structure only. No screenshots, text
//  values, OCR, or uploads. The event tap is listen-only and Escape disables it.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import CryptoKit
import Darwin
import Foundation
import SwiftUI

struct CookieApprenticeStep: Codable, Equatable, Identifiable {
    enum Action: Codable, Equatable {
        case press(role: String, label: String)
        case key(String)
        case typed

        var normalized: String {
            switch self {
            case .press(let role, let label): return "press|\(role.lowercased())|\(label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            case .key(let combo): return "key|\(combo.lowercased())"
            case .typed: return "typed"
            }
        }

        var display: String {
            switch self {
            case .press(_, let label): return label.isEmpty ? "press control" : label
            case .key(let combo): return combo
            case .typed: return "ask me"
            }
        }
    }

    var id: UUID
    var date: Date
    var appBundleID: String
    var action: Action

    init(date: Date = Date(), appBundleID: String, action: Action) {
        id = UUID()
        self.date = date
        self.appBundleID = appBundleID
        self.action = action
    }

    var normalized: String { appBundleID.lowercased() + "|" + action.normalized }
}

struct CookieApprenticePattern: Equatable, Identifiable {
    let id: String
    let steps: [CookieApprenticeStep]
    let occurrences: Int
    let sessions: Int

    var title: String { steps.map { $0.action.display }.joined(separator: " → ") }

    var offerText: String {
        let times = occurrences == 1 ? "once" : "\(occurrences) times"
        return "You've done ‘\(title)’ \(times) this week. Want Cookie to take it?"
    }
}

struct CookieApprenticeArchive: Codable {
    var steps: [CookieApprenticeStep] = []
    var offered: [String: Date] = [:]
    var proofDay: String?
}

/// Seven-day, owner-only local store. Its schema contains control structure only.
final class CookieApprenticeStore {
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    static let maximumSteps = 20_000
    static let defaultFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cookie/apprentice.json")

    private(set) var archive = CookieApprenticeArchive()
    private let file: URL?
    private(set) var loadProblem: String?

    init(file: URL?, now: Date = Date()) {
        self.file = file
        if let file, FileManager.default.fileExists(atPath: file.path) {
            do { archive = try JSONDecoder().decode(CookieApprenticeArchive.self, from: Data(contentsOf: file)) }
            catch { loadProblem = "Cookie couldn't read its local apprentice history: \(error.localizedDescription)" }
        }
        let previousStepCount = archive.steps.count
        let previousOfferCount = archive.offered.count
        prune(now: now)
        if loadProblem == nil && (previousStepCount != archive.steps.count || previousOfferCount != archive.offered.count) {
            try? save()
        }
    }

    var steps: [CookieApprenticeStep] { archive.steps }

    func append(_ step: CookieApprenticeStep, now: Date = Date()) throws {
        guard loadProblem == nil else { throw CocoaError(.fileReadCorruptFile) }
        // Several ordinary key presses are represented by one placeholder, never their characters.
        if step.action == .typed, let last = archive.steps.last,
           last.appBundleID == step.appBundleID, last.action == .typed,
           step.date.timeIntervalSince(last.date) < 3 {
            archive.steps[archive.steps.count - 1].date = step.date
        } else {
            archive.steps.append(step)
        }
        prune(now: now)
        try save()
    }

    func wasOffered(_ patternID: String, on day: Date, calendar: Calendar = .current) -> Bool {
        guard let date = archive.offered[patternID] else { return false }
        return calendar.isDate(date, inSameDayAs: day)
    }

    func markOffered(_ patternID: String, on day: Date) throws {
        archive.offered[patternID] = day
        try save()
    }

    func markProofDay(_ day: String) throws -> Bool {
        guard archive.proofDay != day else { return false }
        archive.proofDay = day
        try save()
        return true
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        archive.steps.removeAll { $0.date < cutoff }
        if archive.steps.count > Self.maximumSteps {
            archive.steps.removeFirst(archive.steps.count - Self.maximumSteps)
        }
        archive.offered = archive.offered.filter { now.timeIntervalSince($0.value) <= Self.retention }
    }

    private func save() throws {
        guard let file else { return }
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try JSONEncoder().encode(archive).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

@MainActor
final class CookieApprentice: ObservableObject {
    static let enabledKey = "cookie.apprentice.noticeRepeatedTasks"
    static let shared = CookieApprentice(store: CookieApprenticeStore(file: CookieApprenticeStore.defaultFile))
    static let idleBoundary: TimeInterval = 5 * 60

    struct Offer: Identifiable, Equatable {
        let pattern: CookieApprenticePattern
        var id: String { pattern.id }
    }

    struct ObservedEvent: Equatable {
        enum Kind: Equatable {
            case press(role: String, label: String)
            case key(flags: CGEventFlags, keyCode: CGKeyCode)
            case typed
        }
        let bundleID: String
        let kind: Kind
        let secureInput: Bool
        let blocked: Bool
        let date: Date
    }

    @Published private(set) var isRecording = false
    @Published private(set) var isEnabled: Bool
    @Published private(set) var problem: String?
    @Published private(set) var offer: Offer?

    private let defaults: UserDefaults
    private let store: CookieApprenticeStore
    private let proof: CookieProof
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var startedAt: Date?
    private var timer: Task<Void, Never>?
    private var latestPatterns: [String: CookieApprenticePattern] = [:]
    var onOffer: ((Offer) -> Void)? {
        didSet { if let offer { onOffer?(offer) } }
    }
    var onSchedule: ((String) -> Void)?

    init(defaults: UserDefaults = .standard, store: CookieApprenticeStore = CookieApprenticeStore(file: nil),
         proof: CookieProof = .shared) {
        self.defaults = defaults
        self.store = store
        self.proof = proof
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        problem = store.loadProblem
    }

    var localSteps: [CookieApprenticeStep] { store.steps }

    func startIfEnabled() {
        guard isEnabled else { return }
        start()
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        isEnabled = enabled
        if enabled { start() } else { stop(keepEnabled: true); problem = store.loadProblem }
    }

    func retryPermissions() { guard isEnabled else { return }; start() }

    func openPermissionSettings() {
        let permission: CookiePermission = AXIsProcessTrusted() ? .inputMonitoring : .accessibility
        CookieSystemPermissions().openSettings(for: permission)
    }

    func start() {
        guard isEnabled, !isRecording else { return }
        guard store.loadProblem == nil else { problem = store.loadProblem; return }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            problem = "Allow Accessibility and Input Monitoring in System Settings, then retry. No input is being observed yet."
            return
        }
        let watched: [CGEventType] = [.leftMouseUp, .keyDown]
        let mask = watched.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let apprentice = Unmanaged<CookieApprentice>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                Task { @MainActor in apprentice.tapFailed() }
                return Unmanaged.passUnretained(event)
            }
            let copy = event.copy()
            let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
            let secure = IsSecureEventInputEnabled()
            Task { @MainActor in apprentice.handle(type: type, event: copy ?? event, pid: pid, secureInput: secure) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            problem = "macOS couldn't start the listen-only input tap. Check Input Monitoring, then retry."
            return
        }
        self.tap = tap
        startedAt = Date()
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            self.tap = nil
            problem = "Cookie couldn't connect its listen-only input tap to the run loop. Retry after checking permissions."
            return
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRecording = true
        problem = nil
    }

    func stop(keepEnabled: Bool = false) {
        guard !keepEnabled else { stopTap(); return }
        defaults.set(false, forKey: Self.enabledKey)
        isEnabled = false
        stopTap()
    }

    func cancelWithEscape() { setEnabled(false) }

    private func stopTap() {
        timer?.cancel(); timer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        let count = store.steps.filter { Calendar.current.isDateInToday($0.date) }.count
        isRecording = false
        startedAt = nil
        recordDailyProofIfNeeded(stepCount: count)
    }

    func stopForTermination() { stopTap() }

    private func tapFailed() {
        problem = "macOS stopped input monitoring. Nothing was saved beyond the structural steps already recorded."
        defaults.set(false, forKey: Self.enabledKey)
        isEnabled = false
        stopTap()
    }

    private func handle(type: CGEventType, event: CGEvent, pid: pid_t, secureInput: Bool) {
        guard isEnabled, isRecording else { return }
        if type == .keyDown, CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == CGKeyCode(kVK_Escape) {
            cancelWithEscape()
            return
        }
        let app = (pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil) ?? NSWorkspace.shared.frontmostApplication
        guard let bundleID = app?.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              !MacSafety.blocked(bundleID: bundleID, category: nil),
              !secureInput, !CaptureGuard.focusedElementIsSecure() else { return }
        if type == .leftMouseUp {
            var element: AXUIElement?
            let point = event.location
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
                  let element,
                  let role = MacOperator.string(element, kAXRoleAttribute), Self.isControlRole(role) else { return }
            let label = Self.structuralLabel(element)
            handleObserved(ObservedEvent(bundleID: bundleID, kind: .press(role: role, label: label),
                                         secureInput: false, blocked: false, date: Date()))
        } else if type == .keyDown {
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let kind = Self.classifyKey(flags: flags, keyCode: code)
            handleObserved(ObservedEvent(bundleID: bundleID, kind: kind, secureInput: false, blocked: false, date: Date()))
        }
    }

    /// The event tap and the interaction checks share this exact gate and recording path.
    func handleObserved(_ event: ObservedEvent) {
        guard isEnabled, store.loadProblem == nil, !event.secureInput, !event.blocked,
              event.bundleID != Bundle.main.bundleIdentifier,
              !CaptureGuard.blockedBundleIDs.contains(event.bundleID) else { return }
        let action: CookieApprenticeStep.Action
        switch event.kind {
        case .press(let role, let label):
            guard Self.isControlRole(role) else { return }
            action = .press(role: String(role.prefix(48)), label: Self.maskLabel(label, app: event.bundleID, proof: proof))
        case .key(let flags, let keyCode):
            guard let combo = Self.combo(flags: flags, keyCode: keyCode) else { return }
            action = .key(combo)
        case .typed:
            // Deliberately do not inspect CGEvent's Unicode string or AXValue.
            guard !event.secureInput else { return }
            action = .typed
        }
        do {
            try store.append(CookieApprenticeStep(date: event.date, appBundleID: event.bundleID, action: action), now: event.date)
            let stepsToday = store.steps.filter { Calendar.current.isDateInToday($0.date) }.count
            recordDailyProofIfNeeded(stepCount: stepsToday)
            scheduleMiningAfterIdle()
            problem = nil
        } catch {
            problem = "Cookie couldn't keep the local structural history: \(error.localizedDescription)"
        }
    }

    private func scheduleMiningAfterIdle() {
        timer?.cancel()
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.idleBoundary + 1)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.evaluatePatterns()
        }
    }

    func evaluatePatterns(now: Date = Date()) {
        guard offer == nil else { return }
        let patterns = Self.repeats(in: store.steps, minLength: 3, minCount: 3)
        latestPatterns = Dictionary(uniqueKeysWithValues: patterns.map { ($0.id, $0) })
        for pattern in patterns where !store.wasOffered(pattern.id, on: now) {
            do { try store.markOffered(pattern.id, on: now) }
            catch { problem = "Cookie couldn't save the local offer history: \(error.localizedDescription)"; return }
            let next = Offer(pattern: pattern)
            offer = next
            onOffer?(next)
            return
        }
    }

    func dismissOffer(_ id: String) {
        guard offer?.id == id else { return }
        offer = nil
        evaluatePatterns()
    }

    func acceptOffer(_ id: String) {
        guard let pattern = latestPatterns[id] ?? offer?.pattern, pattern.id == id else { return }
        offer = nil
        let steps = pattern.steps.map { step -> CookieTeachStep in
            let app = Self.applicationName(for: step.appBundleID)
            switch step.action {
            case .press(let role, let label): return .press(app: app, role: role, label: label)
            case .key(let combo): return .key(app: app, combo: combo)
            case .typed: return .typedSomethingPrivate(app: app)
            }
        }
        CookieTeach.shared.review(steps: steps, suggestedName: pattern.title) { [weak self] name in
            self?.offerScheduling(for: name)
        }
    }

    private func offerScheduling(for name: String) {
        let alert = NSAlert()
        alert.messageText = "Would you like to schedule ‘\(name)’?"
        alert.informativeText = "Cookie will ask you for days and a time, then use the existing routine approval. It won't run this task without the usual start-task approval."
        alert.addButton(withTitle: "Choose a schedule…")
        alert.addButton(withTitle: "Not now")
        if alert.runModal() == .alertFirstButtonReturn { onSchedule?(name) }
    }

    func recordDailyProofIfNeeded(stepCount: Int) {
        guard stepCount > 0 else { return }
        let day = Calendar.current.startOfDay(for: Date()).formatted(.iso8601.year().month().day())
        do {
            guard try store.markProofDay(day) else { return }
            proof.record(.saw, feature: "shadow-apprentice",
                                      summary: "Observed \(stepCount) structural steps locally; no content uploaded")
        } catch { problem = "Cookie couldn't update the local apprentice history: \(error.localizedDescription)" }
    }

    static func classifyKey(flags: CGEventFlags, keyCode: CGKeyCode) -> ObservedEvent.Kind {
        let special = specialKey(for: keyCode) != nil
        let nonTextModifier: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]
        let hasNonTextModifier = !flags.intersection(nonTextModifier).isEmpty
        return hasNonTextModifier || special ? .key(flags: flags, keyCode: keyCode) : .typed
    }

    private static func isControlRole(_ role: String) -> Bool {
        ["AXButton", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXTab",
         "AXToolbarItem", "AXLink", "AXTextField", "AXSearchField", "AXRow", "AXOutlineRow"].contains(role)
    }

    /// Never reads AXValue: text entered into a field is excluded even if an app mislabels it.
    private static func structuralLabel(_ element: AXUIElement) -> String {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute, "AXIdentifier"] {
            if let label = MacOperator.string(element, key), !label.isEmpty { return String(label.prefix(120)) }
        }
        return ""
    }

    private static func maskLabel(_ input: String, app: String, proof: CookieProof) -> String {
        var label = String(input.prefix(120))
        let ranges = SensitiveText.ranges(in: label)
        for range in ranges.reversed() { label.replaceSubrange(range, with: "•••") }
        if !ranges.isEmpty {
            proof.record(.redacted, feature: "shadow-apprentice", app: app,
                         summary: "masked a sensitive control label", hidden: ranges.count)
        }
        return label
    }

    private static func specialKey(for keyCode: CGKeyCode) -> String? {
        let known: Set<CGKeyCode> = [CGKeyCode(kVK_Return), CGKeyCode(kVK_Tab), CGKeyCode(kVK_Delete),
            CGKeyCode(kVK_ForwardDelete), CGKeyCode(kVK_LeftArrow), CGKeyCode(kVK_RightArrow),
            CGKeyCode(kVK_UpArrow), CGKeyCode(kVK_DownArrow), CGKeyCode(kVK_Home),
            CGKeyCode(kVK_End), CGKeyCode(kVK_PageUp), CGKeyCode(kVK_PageDown)]
        guard known.contains(keyCode) else { return nil }
        return MacKeys.name(for: keyCode) ?? "key\(keyCode)"
    }

    private static func combo(flags: CGEventFlags, keyCode: CGKeyCode) -> String? {
        let name = MacKeys.name(for: keyCode) ?? specialKey(for: keyCode)
        guard let name else { return nil }
        let modifiers: [(CGEventFlags, String)] = [(.maskControl, "ctrl"), (.maskAlternate, "opt"),
                                                   (.maskShift, "shift"), (.maskCommand, "cmd"), (.maskSecondaryFn, "fn")]
        let parts = modifiers.compactMap { flags.contains($0.0) ? $0.1 : nil }
        guard !parts.isEmpty || specialKey(for: keyCode) != nil else { return nil }
        return (parts + [name]).joined(separator: "+")
    }

    private static func applicationName(for bundleID: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String { return name }
        return bundleID
    }

    /// Finds contiguous sequences repeated in at least `minCount` separate sessions.
    /// A new session begins after five minutes without an observed structural step.
    static func repeats(in input: [CookieApprenticeStep], minLength: Int = 3, minCount: Int = 3) -> [CookieApprenticePattern] {
        guard minLength > 0, minCount > 1 else { return [] }
        let ordered = input.sorted { $0.date < $1.date }
        var sessions: [[CookieApprenticeStep]] = []
        for step in ordered {
            if let last = sessions.last?.last,
               step.date.timeIntervalSince(last.date) >= idleBoundary {
                sessions.append([step])
            } else if sessions.isEmpty {
                sessions.append([step])
            } else {
                sessions[sessions.count - 1].append(step)
            }
        }

        struct Candidate {
            var steps: [CookieApprenticeStep]
            var occurrences = 0
            var sessions: Set<Int> = []
        }
        var candidates: [String: Candidate] = [:]
        for (sessionIndex, session) in sessions.enumerated() where session.count >= minLength {
            for length in minLength...min(12, session.count) {
                for start in 0...(session.count - length) {
                    let slice = Array(session[start..<(start + length)])
                    let key = slice.map(\.normalized).joined(separator: "\u{1f}")
                    var candidate = candidates[key] ?? Candidate(steps: slice)
                    candidate.occurrences += 1
                    candidate.sessions.insert(sessionIndex)
                    candidates[key] = candidate
                }
            }
        }
        let patterns = candidates.values.compactMap { candidate -> CookieApprenticePattern? in
            guard candidate.sessions.count >= minCount else { return nil }
            let key = candidate.steps.map(\.normalized).joined(separator: "\u{1f}")
            let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            return CookieApprenticePattern(id: digest, steps: candidate.steps,
                                           occurrences: candidate.occurrences, sessions: candidate.sessions.count)
        }
        return patterns.sorted {
            let left = $0.occurrences * $0.steps.count
            let right = $1.occurrences * $1.steps.count
            if left != right { return left > right }
            if $0.steps.count != $1.steps.count { return $0.steps.count > $1.steps.count }
            return $0.id < $1.id
        }
    }
}

@MainActor
final class CookieApprenticeIndicator {
    private let panel: NSPanel
    private var cancellable: AnyCancellable?

    init(apprentice: CookieApprentice = .shared) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = CookieWindowLevel.notch
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: CookieApprenticePill())
        cancellable = apprentice.$isRecording.receive(on: RunLoop.main).sink { [weak self] active in self?.update(active) }
        update(apprentice.isRecording)
    }

    private func update(_ active: Bool) {
        guard active, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else {
            panel.orderOut(nil)
            return
        }
        let size = panel.contentView?.fittingSize ?? NSSize(width: 78, height: 22)
        let top = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : NSStatusBar.system.thickness
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - top - size.height - 30,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }
}

private struct CookieApprenticePill: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(CK.accent).frame(width: 6, height: 6)
            Text("Noticing").font(.system(size: 11, weight: .semibold)).foregroundStyle(CK.text)
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().strokeBorder(CK.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Noticing repeated tasks. Only app names, control labels, keyboard shortcuts and typed placeholders are recorded. Press Escape to stop.")
        .environment(\.colorScheme, .dark)
    }
}
