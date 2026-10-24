//
//  CookiePointTarget.swift
//  Cookie
//
//  The pointer is checked against the screen as it is when it flies, not as
//  it was in the screenshot seconds earlier. The model names the target by
//  its visible text ([POINT:x,y:label]); just before the hand moves, the
//  control at that point is read (Accessibility) and must say the label.
//  If it doesn't, the label is looked for in the window's controls, then in
//  a fresh read of the screen around the point; found, the hand goes there;
//  not found, it doesn't point (the voice still says it). Once there, the
//  hand is tied to the control: it follows it when it moves, and leaves when
//  the control goes or stops saying the label.
//

import AppKit
import ApplicationServices

/// Whether text on screen is what the model named. Folded as a reader would (`Folded`): case,
/// runs of white space, curly quotes and dashes don't matter. A match is the same words, or one
/// holding the other when the shorter is a real part of it (at least 3 characters and, for text
/// shorter than the label, at least half of it): "Save" names "Save…", "Share" names "Share menu".
enum CookieLabelMatch {
    static func matches(label: String, text: String) -> Bool {
        let label = Folded([label]).characters, text = Folded([text]).characters
        guard !label.isEmpty, !text.isEmpty else { return false }
        if label == text { return true }
        if label.count >= 3, text.count >= label.count, contains(text, label) { return true }
        if text.count >= 3, text.count * 2 >= label.count, contains(label, text) { return true }
        return false
    }

    private static func contains(_ haystack: [Character], _ needle: [Character]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { haystack[$0..<$0 + needle.count].elementsEqual(needle) }
    }
}

enum CookiePointTarget {
    /// Where the hand goes, or that it shouldn't.
    enum Resolution {
        /// The label is at (or was found near) the point: AppKit global, with its control when known.
        case found(CGPoint, element: AXUIElement?, how: String)
        /// Nothing to check it against (no label, no Accessibility, an app Cookie doesn't read):
        /// the model's point, as before.
        case unverified(CGPoint)
        /// The label isn't on screen any more.
        case lost
    }

    /// Checks `point` (AppKit global) against `label`, looking for the label when it isn't there.
    /// Off the main thread; a short Accessibility walk, then a fresh read of the screen nearby.
    static func resolve(_ point: CGPoint, label: String?, display: CGRect, exceptApp: pid_t?) async -> Resolution {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty, label.lowercased() != "none",
              AXIsProcessTrusted() else { return .unverified(point) }
        let mainHeight = await MainActor.run { NSScreen.screens.first?.frame.height ?? 0 }
        let refusal = await MainActor.run { CaptureGuard.refusal() }
        guard refusal == nil else { return .unverified(point) }
        let (viaAX, app) = await Task.detached(priority: .userInitiated) {
            accessibility(point, label: label, mainHeight: mainHeight, exceptApp: exceptApp)
        }.value
        // An app Cookie never reads (a password manager, banking): not read, the point as given.
        let blocked = await MainActor.run { () -> Bool in
            guard let app = app.flatMap(NSRunningApplication.init(processIdentifier:)) else { return false }
            return MacSafety.blocked(bundleID: app.bundleIdentifier, category: MacOperator.category(app))
        }
        if blocked { return .unverified(point) }
        if let viaAX { return viaAX }
        if let seen = await onScreen(point, label: label, display: display) { return .found(seen, element: nil, how: "read again on screen") }
        return .lost
    }

    // MARK: Accessibility

    /// The control under the point says the label → there; else the label in its window's controls,
    /// nearest the point → there; nil when neither (or this app can't be read).
    nonisolated private static func accessibility(_ point: CGPoint, label: String, mainHeight: CGFloat, exceptApp: pid_t?) -> (Resolution?, pid_t?) {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var hit: AXUIElement?
        let cgPoint = CGPoint(x: point.x, y: mainHeight - point.y)
        guard AXUIElementCopyElementAtPosition(system, Float(cgPoint.x), Float(cgPoint.y), &hit) == .success, let hit else { return (nil, nil) }
        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        guard pid != getpid(), pid != exceptApp else { return (nil, nil) }
        // The control itself or one of its two containers (a label inside a button, a cell in a row).
        var element: AXUIElement? = hit
        for _ in 0..<3 {
            guard let current = element else { break }
            if texts(of: current).contains(where: { CookieLabelMatch.matches(label: label, text: $0) }) {
                return (.found(point, element: current, how: "checked where it pointed"), pid)
            }
            element = MacOperator.attribute(current, kAXParentAttribute) as! AXUIElement?
        }
        // Moved: the label elsewhere in the same window.
        guard let window = MacOperator.attribute(hit, kAXWindowAttribute) as! AXUIElement? else { return (nil, pid) }
        var best: (element: AXUIElement, centre: CGPoint, distance: CGFloat)?
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        // ponytail: a 2,000-control walk; a bigger window falls back to reading the screen.
        while !queue.isEmpty, visited < 2_000 {
            let (current, depth) = queue.removeFirst()
            visited += 1
            if texts(of: current).contains(where: { CookieLabelMatch.matches(label: label, text: $0) }),
               let frame = MacOperator.frame(current), frame.width > 1, frame.height > 1, frame.width < 900, frame.height < 600 {
                let centre = CGPoint(x: frame.midX, y: mainHeight - frame.midY)
                let distance = hypot(centre.x - point.x, centre.y - point.y)
                if best == nil || distance < best!.distance { best = (current, centre, distance) }
            }
            guard depth < 40, let children = MacOperator.attribute(current, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            queue.append(contentsOf: children.prefix(300).map { ($0, depth + 1) })
        }
        guard let best else { return (nil, pid) }
        return (.found(best.centre, element: best.element, how: "found it again by its words"), pid)
    }

    /// What a control says: title, value (text), description, placeholder.
    nonisolated static func texts(of element: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
            .compactMap { name -> String? in
                guard let text = MacOperator.attribute(element, name) as? String else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty || trimmed.count > 300 ? nil : trimmed
            }
    }

    // MARK: The screen, read again

    /// The label in a fresh picture of the screen around the point (kept on this Mac, never sent),
    /// the line nearest the point; nil when it isn't there or the screen can't be read.
    private static func onScreen(_ point: CGPoint, label: String, display: CGRect) async -> CGPoint? {
        let area = CGRect(x: point.x - 300, y: point.y - 200, width: 600, height: 400).intersection(display)
        guard area.width > 8, area.height > 8, await MainActor.run(body: { CGPreflightScreenCaptureAccess() }),
              let image = try? await CompanionScreenCaptureUtility.captureRegionImage(area),
              let lines = try? await CookieVisionText.lines(in: image) else { return nil }
        let centres = lines.filter { CookieLabelMatch.matches(label: label, text: $0.text) }.map { line in
            // Normalised, bottom-left origin in the crop → AppKit global.
            CGPoint(x: area.minX + line.box.midX * area.width, y: area.minY + line.box.midY * area.height)
        }
        return centres.min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) }
    }
}

/// The hand tied to the control it points at. Accessibility tells when the control (or its window)
/// moves or is resized, its value changes or it is destroyed; a scroll moves a control without
/// telling it, so its frame is also read four times a second. Moved: `moved` gets its new centre;
/// gone, or no longer saying the label: `gone`.
@MainActor
final class CookieElementAnchor {
    private let element: AXUIElement
    private let label: String?
    private var observer: AXObserver?
    private var poll: Timer?
    private var lastCentre: CGPoint?
    /// Where the hand points relative to the control's centre (the model's point inside it).
    private var offset = CGVector.zero
    var moved: ((CGPoint) -> Void)?
    var gone: (() -> Void)?

    /// `point`: where the hand points now (AppKit global); it keeps that place on the control.
    init?(element: AXUIElement, label: String?, point: CGPoint) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        self.element = element
        self.label = label
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let anchor = Unmanaged<CookieElementAnchor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { anchor.check() }
        }
        if AXObserverCreate(pid, callback, &created) == .success, let created {
            observer = created
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for name in [kAXMovedNotification, kAXResizedNotification, kAXValueChangedNotification,
                         kAXUIElementDestroyedNotification, kAXLayoutChangedNotification] {
                AXObserverAddNotification(created, element, name as CFString, refcon)
            }
            if let window = MacOperator.attribute(element, kAXWindowAttribute) as! AXUIElement? {
                for name in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification] {
                    AXObserverAddNotification(created, window, name as CFString, refcon)
                }
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        }
        lastCentre = centre()
        if let lastCentre { offset = CGVector(dx: point.x - lastCentre.x, dy: point.y - lastCentre.y) }
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func stop() {
        poll?.invalidate()
        poll = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        moved = nil
        gone = nil
    }

    private func centre() -> CGPoint? {
        guard let frame = MacOperator.frame(element), frame.width > 0, frame.height > 0 else { return nil }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: frame.midX, y: mainHeight - frame.midY)
    }

    private func check() {
        guard let now = centre() else { return leave() }
        if let label, !CookiePointTarget.texts(of: element).isEmpty,
           !CookiePointTarget.texts(of: element).contains(where: { CookieLabelMatch.matches(label: label, text: $0) }) {
            return leave()
        }
        if let lastCentre, hypot(now.x - lastCentre.x, now.y - lastCentre.y) < 1 { return }
        lastCentre = now
        moved?(CGPoint(x: now.x + offset.dx, y: now.y + offset.dy))
    }

    private func leave() {
        let gone = self.gone
        stop()
        gone?()
    }
}
