//
//  CookieApprentice.swift
//  Cookie
//
//  Opt-in pattern learning from input structure only. No screenshots, text
//  values, OCR, or uploads. The event tap is listen-only; the "Noticing" pill
//  and Settings stop it. Escape is never treated as "stop": it belongs to
//  whatever app you pressed it in.
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
            case .press(let role, let label): return label.isEmpty ? CookieApprentice.roleName(role) : label
            case .key(let combo): return combo
            case .typed: return "ask me"
            }
        }

        /// A deliberate step worth automating: a pressed control or a Cmd/Ctrl
        /// shortcut. Typing, arrows, Return and Tab only move around.
        var isMeaningful: Bool {
            switch self {
            case .press: return true
            case .key(let combo):
                let parts = combo.lowercased().split(separator: "+")
                return parts.contains("cmd") || parts.contains("ctrl")
            case .typed: return false
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
        let times = sessions == 1 ? "once" : "\(sessions) times"
        return "You've done ‘\(title)’ \(times) this week. Want Cookie to take it?"
    }

    /// Stable across launches: the same structural steps always give the same id.
    static func id<S: Sequence>(for steps: S) -> String where S.Element == CookieApprenticeStep {
        let key = steps.map(\.normalized).joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// This pattern and every shorter run inside it: "Later" snoozes them all for the day.
    func idsIncludingSubpatterns(minLength: Int = 3) -> [String] {
        guard steps.count >= minLength else { return [id] }
        var ids: [String] = []
        for length in minLength...steps.count {
            for start in 0...(steps.count - length) { ids.append(Self.id(for: steps[start..<(start + length)])) }
        }
        return ids
    }
}

struct CookieApprenticeArchive: Codable {
    var steps: [CookieApprenticeStep] = []
    var offered: [String: Date] = [:]
    var proofDay: String?
    /// Today's Proof row, revised with the real count at stop, rollover and on a timer.
    var proofEntryID: UUID?
}

/// Writes owner-only (0600) from the first byte, then renames into place, so
/// no reader ever sees a half file or a briefly world-readable one. The folder
/// it lives in is left exactly as it was.
enum CookieOwnerOnlyFile {
    static func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.posixError() }
        var renamed = false
        defer { if !renamed { unlink(temporary.path) } }
        do {
            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw Self.posixError()
                    }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0 else { throw Self.posixError() }
        } catch {
            close(descriptor)
            throw error
        }
        guard close(descriptor) == 0 else { throw Self.posixError() }
        guard rename(temporary.path, url.path) == 0 else { throw Self.posixError() }
        renamed = true
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

/// Seven-day, owner-only local store. Its schema contains control structure only.
/// Events change it in memory; the file is written in the background a moment
/// after activity settles, and right away on stop and quit.
@MainActor
final class CookieApprenticeStore {
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    static let maximumSteps = 20_000
    /// Trimming waits for this many extra steps, so a full archive doesn't shift 20,000 rows per event.
    static let trimSlack = 512
    static let defaultFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cookie/apprentice.json")

    private(set) var archive = CookieApprenticeArchive()
    private let file: URL?
    private(set) var loadProblem: String?
    /// Distinct steps stored on `countDay`, kept as events arrive (no scans).
    private(set) var stepsToday = 0
    private(set) var countDay: Date?
    var saveDelay: TimeInterval = 2
    /// A background save failed (or recovered: nil).
    var onSaveProblem: ((String?) -> Void)?

    private var saveScheduled = false
    private let saveQueue = DispatchQueue(label: "com.enkeon.cookie.apprentice.save", qos: .utility)

    init(file: URL?, now: Date = Date()) {
        self.file = file
        if let file, FileManager.default.fileExists(atPath: file.path) {
            do { archive = try JSONDecoder().decode(CookieApprenticeArchive.self, from: Data(contentsOf: file)) }
            catch { loadProblem = "Cookie couldn't read its local apprentice history: \(error.localizedDescription)" }
        }
        let previousStepCount = archive.steps.count
        let previousOfferCount = archive.offered.count
        prune(now: now)
        recount(now: now)
        if loadProblem == nil && (previousStepCount != archive.steps.count || previousOfferCount != archive.offered.count) {
            try? flush()
        }
    }

    var steps: [CookieApprenticeStep] { archive.steps }
    var proofEntryID: UUID? { archive.proofEntryID }
    var proofDay: String? { archive.proofDay }

    func append(_ step: CookieApprenticeStep, now: Date = Date()) throws {
        guard loadProblem == nil else { throw CocoaError(.fileReadCorruptFile) }
        guard step.date >= now.addingTimeInterval(-Self.retention) else { return } // already past the week
        // Several ordinary key presses are represented by one placeholder, never their characters.
        if step.action == .typed, let last = archive.steps.last,
           last.appBundleID == step.appBundleID, last.action == .typed,
           step.date.timeIntervalSince(last.date) < 3 {
            archive.steps[archive.steps.count - 1].date = step.date
        } else {
            archive.steps.append(step)
            if let countDay, Calendar.current.isDate(countDay, inSameDayAs: step.date) {
                stepsToday += 1
            } else {
                countDay = Calendar.current.startOfDay(for: step.date)
                stepsToday = 1
            }
        }
        if archive.steps.count > Self.maximumSteps + Self.trimSlack {
            archive.steps.removeFirst(archive.steps.count - Self.maximumSteps)
        }
        scheduleSave()
    }

    func wasOffered(_ patternID: String, on day: Date, calendar: Calendar = .current) -> Bool {
        guard let date = archive.offered[patternID] else { return false }
        return calendar.isDate(date, inSameDayAs: day)
    }

    func markOffered(_ patternIDs: [String], on day: Date) {
        for id in patternIDs { archive.offered[id] = day }
        scheduleSave()
    }

    func setProofEntry(_ id: UUID, day: String) {
        archive.proofDay = day
        archive.proofEntryID = id
        scheduleSave()
    }

    /// Steps and offers older than a week go; run at launch, hourly while on, and when turned off.
    func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        if let first = archive.steps.first, first.date < cutoff { archive.steps.removeAll { $0.date < cutoff } }
        if archive.steps.count > Self.maximumSteps {
            archive.steps.removeFirst(archive.steps.count - Self.maximumSteps)
        }
        archive.offered = archive.offered.filter { now.timeIntervalSince($0.value) <= Self.retention }
        if let countDay, !Calendar.current.isDate(countDay, inSameDayAs: now) { recount(now: now) }
    }

    /// Everything the apprentice kept: steps, offers and the day's Proof link.
    func clear() throws {
        archive = CookieApprenticeArchive()
        loadProblem = nil
        stepsToday = 0
        countDay = nil
        guard let file else { return }
        saveScheduled = false
        saveQueue.sync {}
        try? FileManager.default.removeItem(at: file)
    }

    /// Writes now, after any background save already under way.
    func flush() throws {
        saveScheduled = false
        guard let file, loadProblem == nil else { return }
        let data = try JSONEncoder().encode(archive)
        var failure: Error?
        saveQueue.sync {
            do { try CookieOwnerOnlyFile.write(data, to: file) } catch { failure = error }
        }
        if let failure { throw failure }
    }

    private func recount(now: Date) {
        let today = Calendar.current.startOfDay(for: now)
        countDay = today
        // ponytail: one scan per launch or day change; every event after that is O(1).
        stepsToday = archive.steps.reduce(0) { $0 + (Calendar.current.isDate($1.date, inSameDayAs: today) ? 1 : 0) }
    }

    private func scheduleSave() {
        guard file != nil, !saveScheduled else { return }
        saveScheduled = true
        let delay = saveDelay
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.saveScheduled else { return }
            self.saveInBackground()
        }
    }

    private func saveInBackground() {
        saveScheduled = false
        guard let file, loadProblem == nil else { return }
        let snapshot = archive
        saveQueue.async { [weak self] in
            let problem: String?
            do {
                try CookieOwnerOnlyFile.write(try JSONEncoder().encode(snapshot), to: file)
                problem = nil
            } catch {
                problem = "Cookie couldn't keep the local structural history: \(error.localizedDescription)"
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onSaveProblem?(problem) } }
        }
    }
}

/// What the tap callback copies out of an event before letting go of it: no
/// characters, only where, which key and from whom.
struct CookieApprenticeRawEvent {
    let isClick: Bool
    let location: CGPoint
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let targetPID: pid_t
    let sourcePID: pid_t
    let secureInput: Bool
    let date: Date
}

/// Accessibility lookups run here, one at a time and in order, with a 0.2 s
/// messaging cap, so a hung app can never freeze the notch.
final class CookieApprenticeReader: @unchecked Sendable {
    static let maximumPending = 64
    private let queue = DispatchQueue(label: "com.enkeon.cookie.apprentice.read", qos: .utility)
    private let lock = NSLock()
    private var pending = 0

    func read(_ raw: CookieApprenticeRawEvent, deliver: @escaping @MainActor (CookieApprentice.ObservedEvent) -> Void) {
        lock.lock()
        // ponytail: a stuck app backs events up; past 64 they're dropped rather than queued without end.
        guard pending < Self.maximumPending else { lock.unlock(); return }
        pending += 1
        lock.unlock()
        queue.async { [self] in
            let observed = Self.resolve(raw)
            lock.lock(); pending -= 1; lock.unlock()
            guard let observed else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(observed) } }
        }
    }

    /// Off the main thread. Cookie's own posted events and blocked apps never reach Accessibility.
    static func resolve(_ raw: CookieApprenticeRawEvent) -> CookieApprentice.ObservedEvent? {
        guard raw.sourcePID != getpid() else { return nil }
        let app = (raw.targetPID > 0 ? NSRunningApplication(processIdentifier: raw.targetPID) : nil)
            ?? NSWorkspace.shared.frontmostApplication
        guard let app, let bundleID = app.bundleIdentifier, app.processIdentifier != getpid() else { return nil }
        let category = app.bundleURL.flatMap(Bundle.init(url:))?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        guard !MacSafety.blocked(bundleID: bundleID, category: category) else { return nil }
        guard !raw.secureInput, !CaptureGuard.focusedElementIsSecure() else { return nil }
        let kind: CookieApprentice.ObservedEvent.Kind
        if raw.isClick {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.2)
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(raw.location.x), Float(raw.location.y), &element) == .success,
                  let element else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.2)
            guard let role = MacOperator.string(element, kAXRoleAttribute), CookieApprentice.isRecordableRole(role) else { return nil }
            let identifier = MacOperator.string(element, "AXIdentifier").flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
            kind = .press(role: role, label: CookieApprentice.isControlRole(role) ? controlLabel(element) : "", identifier: identifier)
        } else {
            kind = CookieApprentice.classifyKey(flags: raw.flags, keyCode: raw.keyCode)
        }
        return CookieApprentice.ObservedEvent(bundleID: bundleID, kind: kind, secureInput: false, blocked: false,
                                              date: raw.date, category: category)
    }

    /// Only for controls (buttons, menu items, tabs…). Never reads AXValue.
    private static func controlLabel(_ element: AXUIElement) -> String {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let label = MacOperator.string(element, key), !label.isEmpty { return String(label.prefix(120)) }
        }
        return ""
    }
}

@MainActor
final class CookieApprentice: ObservableObject {
    static let enabledKey = "cookie.apprentice.noticeRepeatedTasks"
    static let shared = CookieApprentice(store: CookieApprenticeStore(file: CookieApprenticeStore.defaultFile))
    static let idleBoundary: TimeInterval = 5 * 60
    /// The miner gives up past this, so a huge week never pins a core.
    static let miningBudget: TimeInterval = 2

    struct Offer: Identifiable, Equatable {
        let pattern: CookieApprenticePattern
        var id: String { pattern.id }
    }

    struct ObservedEvent: Equatable {
        enum Kind: Equatable {
            case press(role: String, label: String, identifier: String? = nil)
            case key(flags: CGEventFlags, keyCode: CGKeyCode)
            case typed
        }
        let bundleID: String
        let kind: Kind
        let secureInput: Bool
        let blocked: Bool
        let date: Date
        /// The app's App Store category: finance and medical apps are never observed.
        var category: String? = nil
        /// Posted by Cookie itself (a replay, a click it made).
        var postedByCookie = false
    }

    @Published private(set) var isRecording = false
    @Published private(set) var isEnabled: Bool
    @Published private(set) var problem: String?
    @Published private(set) var offer: Offer?
    /// The permission that's stopping noticing, for Settings' "Open System Settings".
    @Published private(set) var missingPermission: CookiePermission?

    private let defaults: UserDefaults
    private let store: CookieApprenticeStore
    private let proof: CookieProof
    private let reader = CookieApprenticeReader()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var idleTimer: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    private var miningTask: Task<Void, Never>?
    private var latestPatterns: [String: CookieApprenticePattern] = [:]
    private var proofRevisedAt: Date?
    /// Cookie driving the Mac (an approved task) or recording a lesson: its events aren't yours.
    var cookieIsActing: @MainActor () -> Bool = { MacOperator.shared.grant != nil || CookieTeach.shared.isTeaching }
    var onOffer: ((Offer) -> Void)? {
        didSet { if let offer { onOffer?(offer) } }
    }
    var onSchedule: ((String) -> Void)?

    init(defaults: UserDefaults = .standard, store: CookieApprenticeStore? = nil, proof: CookieProof = .shared) {
        let store = store ?? CookieApprenticeStore(file: nil)
        self.defaults = defaults
        self.store = store
        self.proof = proof
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        problem = store.loadProblem
        store.onSaveProblem = { [weak self] problem in
            guard let self else { return }
            if let problem { self.problem = problem } else if self.problem?.hasPrefix("Cookie couldn't keep") == true { self.problem = nil }
        }
    }

    var localSteps: [CookieApprenticeStep] { store.steps }
    var isMining: Bool { miningTask != nil }

    /// At launch: never prompts. Permission prompts only follow the person's own click.
    func startIfEnabled() {
        guard isEnabled else { return }
        start(requestingAccess: false)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        isEnabled = enabled
        if enabled {
            start(requestingAccess: true)
        } else {
            stopTap()
            offer = nil
            missingPermission = nil
            store.prune(now: Date())
            do { try store.flush(); problem = store.loadProblem }
            catch { problem = "Cookie couldn't update the local apprentice history: \(error.localizedDescription)" }
        }
    }

    func retryPermissions() { guard isEnabled else { return }; start(requestingAccess: true) }

    func openPermissionSettings() {
        let permission = missingPermission ?? (AXIsProcessTrusted() ? .inputMonitoring : .accessibility)
        CookieSystemPermissions().openSettings(for: permission)
    }

    /// Settings' "Clear history": every step, offer and pending suggestion on this Mac.
    func clearHistory() {
        objectWillChange.send()
        offer = nil
        latestPatterns = [:]
        miningTask?.cancel(); miningTask = nil
        idleTimer?.cancel(); idleTimer = nil
        do { try store.clear(); problem = nil }
        catch { problem = "Cookie couldn't clear the local apprentice history: \(error.localizedDescription)" }
    }

    func start(requestingAccess: Bool = false) {
        guard isEnabled, !isRecording else { return }
        guard store.loadProblem == nil else { problem = store.loadProblem; return }
        if !AXIsProcessTrusted() {
            if requestingAccess {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            missingPermission = .accessibility
            problem = "Cookie needs Accessibility to tell which control you pressed. Allow it in System Settings, then retry. Nothing is being observed."
            return
        }
        if !CGPreflightListenEventAccess() {
            guard requestingAccess, CGRequestListenEventAccess() else {
                missingPermission = .inputMonitoring
                problem = "Input Monitoring is off for Cookie. Allow it in System Settings, then retry. Nothing is being observed."
                return
            }
        }
        missingPermission = nil
        let watched: [CGEventType] = [.leftMouseUp, .keyDown]
        let mask = watched.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        // Runs on the main run loop: copy a few fields, hand off, return. Nothing else.
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let apprentice = Unmanaged<CookieApprentice>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { apprentice.tapWasDisabled() }
                return Unmanaged.passUnretained(event)
            }
            let raw = CookieApprenticeRawEvent(
                isClick: type == .leftMouseUp, location: event.location,
                keyCode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags,
                targetPID: pid_t(event.getIntegerValueField(.eventTargetUnixProcessID)),
                sourcePID: pid_t(event.getIntegerValueField(.eventSourceUnixProcessID)),
                secureInput: IsSecureEventInputEnabled(), date: Date())
            MainActor.assumeIsolated {
                apprentice.reader.read(raw) { observed in apprentice.handleObserved(observed) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            missingPermission = .inputMonitoring
            problem = "macOS couldn't start the listen-only input tap. Check Input Monitoring, then retry."
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            problem = "Cookie couldn't connect its listen-only input tap to the run loop. Retry after checking permissions."
            return
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRecording = true
        problem = nil
        startMaintenance()
    }

    func stopForTermination() {
        stopTap()
        try? store.flush()
    }

    private func stopTap() {
        idleTimer?.cancel(); idleTimer = nil
        maintenance?.cancel(); maintenance = nil
        miningTask?.cancel(); miningTask = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isRecording = false
        reviseDailyProof()
    }

    /// macOS pauses a tap whose callback ran late or after secure input; turn it straight back on.
    private func tapWasDisabled() {
        guard let tap, isRecording else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        guard !CGEvent.tapIsEnabled(tap: tap) else { return }
        stopTap()
        problem = "macOS stopped input monitoring. Noticing is still on; press Retry to resume. Nothing was saved beyond the structural steps already recorded."
    }

    private func startMaintenance() {
        maintenance?.cancel()
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3_600)) } catch { return }
                guard let self else { return }
                self.store.prune(now: Date())
                self.reviseDailyProof()
            }
        }
    }

    /// The event tap and the interaction checks share this exact gate and recording path.
    func handleObserved(_ event: ObservedEvent) {
        guard isEnabled, store.loadProblem == nil, !event.secureInput, !event.blocked, !event.postedByCookie,
              !cookieIsActing(), event.bundleID != Bundle.main.bundleIdentifier,
              !MacSafety.blocked(bundleID: event.bundleID, category: event.category) else { return }
        let action: CookieApprenticeStep.Action
        switch event.kind {
        case .press(let role, let label, let identifier):
            guard Self.isRecordableRole(role) else { return }
            // Rows, links, cells and text hold mail subjects and file names: role only (or the app's own id).
            let kept = Self.isControlRole(role) ? (label.isEmpty ? identifier ?? "" : label) : identifier ?? ""
            action = .press(role: String(role.prefix(48)), label: Self.maskLabel(kept, app: event.bundleID, proof: proof))
        case .key(let flags, let keyCode):
            if keyCode == CGKeyCode(kVK_Escape) && flags.intersection([.maskCommand, .maskControl]).isEmpty { return }
            if case .typed = Self.classifyKey(flags: flags, keyCode: keyCode) {
                action = .typed
            } else {
                guard let combo = Self.combo(flags: flags, keyCode: keyCode) else { return }
                action = .key(combo)
            }
        case .typed:
            // Deliberately do not inspect CGEvent's Unicode string or AXValue.
            action = .typed
        }
        do {
            if let day = store.countDay, !Calendar.current.isDate(day, inSameDayAs: event.date) { reviseDailyProof() }
            try store.append(CookieApprenticeStep(date: event.date, appBundleID: event.bundleID, action: action), now: event.date)
            noteDailyProof(on: event.date)
            scheduleMiningAfterIdle()
            if problem?.hasPrefix("Cookie couldn't keep") == true { problem = nil }
        } catch {
            problem = "Cookie couldn't keep the local structural history: \(error.localizedDescription)"
        }
    }

    private func scheduleMiningAfterIdle() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.idleBoundary + 1)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.evaluatePatterns()
        }
    }

    /// Mines a snapshot off the main actor; the offer (if any) is applied back here.
    func evaluatePatterns(now: Date = Date()) {
        guard offer == nil, miningTask == nil, !store.steps.isEmpty else { return }
        let snapshot = store.steps
        let deadline = Date().addingTimeInterval(Self.miningBudget)
        miningTask = Task { [weak self] in
            let patterns = await Task.detached(priority: .utility) {
                CookieApprentice.repeats(in: snapshot, deadline: deadline)
            }.value
            guard let self else { return }
            self.miningTask = nil
            guard !Task.isCancelled else { return }
            self.apply(patterns, now: now)
        }
    }

    private func apply(_ patterns: [CookieApprenticePattern], now: Date) {
        guard offer == nil, isEnabled else { return }
        latestPatterns = Dictionary(patterns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let pattern = patterns.first(where: { !store.wasOffered($0.id, on: now) }) else { return }
        store.markOffered([pattern.id], on: now)
        let next = Offer(pattern: pattern)
        offer = next
        onOffer?(next)
    }

    /// "Later": this pattern and the shorter runs inside it rest until tomorrow, and nothing else is offered now.
    func dismissOffer(_ id: String, now: Date = Date()) {
        guard let current = offer, current.id == id else { return }
        store.markOffered(current.pattern.idsIncludingSubpatterns(), on: now)
        offer = nil
    }

    /// The offer's notice left the screen some other way (clicked away, Esc, replaced).
    func noticeLeft(_ id: String) {
        guard offer?.id == id else { return }
        offer = nil
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

    static func sawSummary(_ count: Int) -> String {
        "Observed \(count) structural \(count == 1 ? "step" : "steps") locally; no content uploaded"
    }

    private static func dayKey(_ date: Date) -> String {
        Calendar.current.startOfDay(for: date).formatted(.iso8601.year().month().day())
    }

    /// One .saw row per day: written at the first step, kept current at most once a minute.
    private func noteDailyProof(on date: Date) {
        let day = Self.dayKey(date)
        if store.proofDay == day, store.proofEntryID != nil {
            guard Date().timeIntervalSince(proofRevisedAt ?? .distantPast) >= 60 else { return }
            if reviseDailyProof() { return }
        }
        // First step of the day, or the row was forgotten from Proof: start it again, honestly counted.
        let id = proof.record(.saw, feature: "shadow-apprentice", summary: Self.sawSummary(store.stepsToday))
        store.setProofEntry(id, day: day)
        proofRevisedAt = Date()
    }

    /// The day's row gets the real count (on stop, at rollover, hourly).
    @discardableResult
    private func reviseDailyProof() -> Bool {
        guard let id = store.proofEntryID, let countDay = store.countDay,
              store.proofDay == Self.dayKey(countDay), store.stepsToday > 0 else { return false }
        proofRevisedAt = Date()
        return proof.revise(id, summary: Self.sawSummary(store.stepsToday))
    }

    /// Cmd or Ctrl makes a shortcut; so do the movement keys. Anything else,
    /// Option and Shift included (é, ß, ą on many layouts), is typing.
    nonisolated static func classifyKey(flags: CGEventFlags, keyCode: CGKeyCode) -> ObservedEvent.Kind {
        let shortcut = !flags.intersection([.maskCommand, .maskControl]).isEmpty
        return shortcut || specialKey(for: keyCode) != nil ? .key(flags: flags, keyCode: keyCode) : .typed
    }

    /// Controls keep their (masked) label: buttons, menu items, checkboxes, tabs, pop-ups.
    nonisolated static func isControlRole(_ role: String) -> Bool {
        ["AXButton", "AXMenuItem", "AXMenuBarItem", "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
         "AXTab", "AXToolbarItem", "AXDisclosureTriangle"].contains(role)
    }

    /// Content roles are recorded by role only: what's in them is the person's mail, files and messages.
    nonisolated static func isContentRole(_ role: String) -> Bool {
        ["AXRow", "AXOutlineRow", "AXLink", "AXCell", "AXStaticText", "AXTextField", "AXSearchField", "AXComboBox"].contains(role)
    }

    nonisolated static func isRecordableRole(_ role: String) -> Bool { isControlRole(role) || isContentRole(role) }

    nonisolated static func roleName(_ role: String) -> String {
        switch role {
        case "AXRow", "AXOutlineRow": return "a row"
        case "AXLink": return "a link"
        case "AXCell": return "a cell"
        case "AXStaticText": return "some text"
        case "AXTextField", "AXSearchField", "AXComboBox": return "a text field"
        default: return "a control"
        }
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

    nonisolated private static func specialKey(for keyCode: CGKeyCode) -> String? {
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
    /// Steps become integer ids; each candidate is a start index plus a rolling
    /// hash, so memory stays at one small record per distinct window.
    nonisolated static func repeats(in input: [CookieApprenticeStep], minLength: Int = 3, minCount: Int = 3,
                                    maxLength: Int = 12, deadline: Date = .distantFuture) -> [CookieApprenticePattern] {
        guard minLength > 0, minCount > 1, maxLength >= minLength, input.count >= minLength else { return [] }
        let ordered = zip(input.indices, input).sorted { ($0.1.date, $0.0) < ($1.1.date, $1.0) }.map(\.1)
        var idOf: [String: Int32] = [:]
        var meaningful: [Bool] = []
        var ids: [Int32] = []
        ids.reserveCapacity(ordered.count)
        for step in ordered {
            let key = step.normalized
            if let id = idOf[key] { ids.append(id); continue }
            let id = Int32(meaningful.count)
            idOf[key] = id
            meaningful.append(step.action.isMeaningful)
            ids.append(id)
        }
        var sessions: [Range<Int>] = []
        var sessionStart = 0
        for index in 1..<ordered.count where ordered[index].date.timeIntervalSince(ordered[index - 1].date) >= idleBoundary {
            sessions.append(sessionStart..<index)
            sessionStart = index
        }
        sessions.append(sessionStart..<ordered.count)

        struct Key: Hashable { let length: Int; let hash: UInt64 }
        struct Candidate { let start: Int; let length: Int; var occurrences: Int; var sessions: Int; var lastSession: Int }
        var table: [Key: Int] = [:]
        var candidates: [Candidate] = []
        func same(_ a: Int, _ b: Int, _ length: Int) -> Bool {
            for offset in 0..<length where ids[a + offset] != ids[b + offset] { return false }
            return true
        }
        for (sessionIndex, session) in sessions.enumerated() where session.count >= minLength {
            if Date() > deadline { break }
            for start in session.lowerBound...(session.upperBound - minLength) {
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                var firstMeaningful: Int32?
                var twoMeaningful = false
                for length in 1...min(maxLength, session.upperBound - start) {
                    let id = ids[start + length - 1]
                    hash = (hash ^ UInt64(UInt32(bitPattern: id))) &* 0x0000_0100_0000_01b3
                    if meaningful[Int(id)] {
                        if let firstMeaningful { if firstMeaningful != id { twoMeaningful = true } } else { firstMeaningful = id }
                    }
                    // Junk filter: at least two different deliberate steps (not Down → Down → Down).
                    guard length >= minLength, twoMeaningful else { continue }
                    var key = Key(length: length, hash: hash)
                    while true {
                        if let slot = table[key] {
                            if same(candidates[slot].start, start, length) {
                                candidates[slot].occurrences += 1
                                if candidates[slot].lastSession != sessionIndex {
                                    candidates[slot].sessions += 1
                                    candidates[slot].lastSession = sessionIndex
                                }
                                break
                            }
                            key = Key(length: length, hash: key.hash &+ 1) // collision: probe on
                        } else {
                            table[key] = candidates.count
                            candidates.append(Candidate(start: start, length: length, occurrences: 1, sessions: 1, lastSession: sessionIndex))
                            break
                        }
                    }
                }
            }
        }
        // ponytail: the 200 best are plenty to choose one offer from; the rest are dropped.
        let qualifying = candidates.filter { $0.sessions >= minCount }
            .sorted {
                let left = $0.occurrences * $0.length, right = $1.occurrences * $1.length
                if left != right { return left > right }
                if $0.length != $1.length { return $0.length > $1.length }
                return ids[$0.start..<($0.start + $0.length)].lexicographicallyPrecedes(ids[$1.start..<($1.start + $1.length)])
            }
            .prefix(200)
        // A run inside a longer qualifying pattern is the same habit: offer the long one only.
        var covered = Set<[Int32]>()
        for candidate in qualifying where candidate.length > minLength {
            for length in minLength..<candidate.length {
                for offset in 0...(candidate.length - length) {
                    covered.insert(Array(ids[(candidate.start + offset)..<(candidate.start + offset + length)]))
                }
            }
        }
        return qualifying.compactMap { candidate in
            let window = Array(ids[candidate.start..<(candidate.start + candidate.length)])
            guard !covered.contains(window) else { return nil }
            let steps = Array(ordered[candidate.start..<(candidate.start + candidate.length)])
            return CookieApprenticePattern(id: CookieApprenticePattern.id(for: steps), steps: steps,
                                           occurrences: candidate.occurrences, sessions: candidate.sessions)
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
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: CookieApprenticePill { apprentice.setEnabled(false) })
        cancellable = apprentice.$isRecording.receive(on: RunLoop.main).sink { [weak self] active in self?.update(active) }
        update(apprentice.isRecording)
    }

    private func update(_ active: Bool) {
        guard active, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else {
            panel.orderOut(nil)
            return
        }
        let size = panel.contentView?.fittingSize ?? NSSize(width: 110, height: 22)
        let top = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : NSStatusBar.system.thickness
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - top - size.height - 30,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }
}

private struct CookieApprenticePill: View {
    let stop: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(CK.accent).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text("Noticing").font(.system(size: 11, weight: .semibold)).foregroundStyle(CK.text)
                .accessibilityLabel("Noticing repeated tasks. Only app names, control labels, keyboard shortcuts and typed placeholders are recorded.")
            Button(action: stop) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hovering ? CK.text : CK.secondary)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(hovering ? CK.fill : Color.clear))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Stop noticing repeated tasks")
            .accessibilityLabel("Stop noticing repeated tasks")
        }
        .padding(.leading, 10).padding(.trailing, 5)
        .frame(height: 22)
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().strokeBorder(CK.hairline))
        .accessibilityElement(children: .contain)
        .environment(\.colorScheme, .dark)
    }
}
