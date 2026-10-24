//
//  CompanionScreenCaptureUtility.swift
//  Cookie
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    /// Private items blacked out or blurred on this Mac before upload.
    let hiddenItems: Int
    /// How long checking it for private details took (`CookieTurnTiming`).
    var redactionSeconds = 0.0
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// What ScreenCaptureKit can see, kept between looks: listing it is most of a one-shot
    /// capture's time. Only the displays and the running apps matter here (a display filter
    /// excludes apps, not windows), so it is refetched when an app launches or quits, the
    /// displays change, at key-down (`prefetch`), and after 30 s at most.
    private static var cachedContent: (content: SCShareableContent, at: CFTimeInterval)?
    private static var watchingForChanges = false

    static func shareableContent() async throws -> SCShareableContent {
        startWatchingForChanges()
        if let cachedContent, CACurrentMediaTime() - cachedContent.at < 30 { return cachedContent.content }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedContent = (content, CACurrentMediaTime())
        return content
    }

    /// A look may be coming (the talk key went down): list what can be captured now.
    static func prefetch() {
        cachedContent = nil
        Task { _ = try? await shareableContent() }
    }

    private static func startWatchingForChanges() {
        guard !watchingForChanges else { return }
        watchingForChanges = true
        let forget: (Notification) -> Void = { _ in MainActor.assumeIsolated { cachedContent = nil } }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main, using: forget)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: forget)
    }

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors. Displays are taken and checked
    /// at the same time, the cursor's first in the list.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        try Task.checkCancellation()
        let content = try await shareableContent()
        try Task.checkCancellation()

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        // Cookie itself and every blocked app (password managers…) are cut out of the picture.
        let excluded = excludedApplications(content)
        let jobs = sortedDisplays.enumerated().map { displayIndex, display in
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

            // Exactly the size the model processes, at the display's own aspect: no server resize
            // (which would move every coordinate it gives back) and no stretch.
            let configuration = SCStreamConfiguration()
            let size = CookieImageSize.screenshot(displayWidth: Double(displayFrame.width), displayHeight: Double(displayFrame.height),
                                                  backingScale: Double(nsScreenByDisplayID[display.displayID]?.backingScaleFactor ?? 1))
            configuration.width = size.width
            configuration.height = size.height
            print("🖼 screen \(displayIndex + 1): \(size.width)×\(size.height) px for \(Int(displayFrame.width))×\(Int(displayFrame.height)) pt at (\(Int(displayFrame.minX)), \(Int(displayFrame.minY))), backing ×\(nsScreenByDisplayID[display.displayID]?.backingScaleFactor ?? 0)")

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }
            return (index: displayIndex, filter: filter, configuration: configuration, label: screenLabel,
                    isCursorScreen: isCursorScreen, displayFrame: displayFrame)
        }

        // Every display at once: each is captured and redacted on its own; one that can't be
        // checked fails the whole look (its error is thrown), as before.
        let capturedScreens = try await withThrowingTaskGroup(of: (Int, CompanionScreenCapture).self) { group in
            for job in jobs {
                group.addTask {
                    let cgImage = try await SCScreenshotManager.captureImage(contentFilter: job.filter, configuration: job.configuration)
                    let redacted = try await encodeRedactedJPEG(cgImage, quality: 0.8)
                    try Task.checkCancellation()
                    return (job.index, CompanionScreenCapture(
                        imageData: redacted.data,
                        label: job.label,
                        isCursorScreen: job.isCursorScreen,
                        displayWidthInPoints: Int(job.displayFrame.width),
                        displayHeightInPoints: Int(job.displayFrame.height),
                        displayFrame: job.displayFrame,
                        screenshotWidthInPixels: job.configuration.width,
                        screenshotHeightInPixels: job.configuration.height,
                        hiddenItems: redacted.hiddenItems,
                        redactionSeconds: redacted.seconds
                    ))
                }
            }
            var done: [(Int, CompanionScreenCapture)] = []
            for try await capture in group { done.append(capture) }
            return done.sorted { $0.0 < $1.0 }.map(\.1)
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    /// Captures one rectangle of the screen (global AppKit coordinates, the
    /// area the user circled) as JPEG. Cookie's own windows are left out, so
    /// the magic trail never shows up in the picture. Kept in memory only.
    static func captureRegionAsJPEG(_ globalRect: CGRect) async throws -> RedactedJPEG? {
        try Task.checkCancellation()
        let content = try await shareableContent()
        try Task.checkCancellation()
        let center = CGPoint(x: globalRect.midX, y: globalRect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }

        let rect = globalRect.intersection(screen.frame)
        guard rect.width >= 4, rect.height >= 4 else { return nil }

        let filter = SCContentFilter(display: display, excludingApplications: excludedApplications(content),
                                     exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        // Display-local points, top-left origin.
        configuration.sourceRect = CGRect(x: rect.minX - screen.frame.minX,
                                          y: screen.frame.maxY - rect.maxY,
                                          width: rect.width, height: rect.height)
        // Full detail, up to what the model takes without resizing it.
        let size = CookieImageSize.processed(width: Int(rect.width * screen.backingScaleFactor), height: Int(rect.height * screen.backingScaleFactor))
        configuration.width = size.width
        configuration.height = size.height

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return try await encodeRedactedJPEG(cgImage, quality: 0.85)
    }

    typealias RedactedJPEG = (data: Data, hiddenItems: Int, seconds: Double)

    /// Vision OCR and JPEG encoding are synchronous CPU work; never run them on the UI/event-tap thread.
    /// Throws `Redactor.Unchecked` when the picture couldn't be checked: it is never sent unchecked.
    nonisolated private static func encodeRedactedJPEG(_ image: CGImage, quality: Double) async throws -> RedactedJPEG {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let started = CACurrentMediaTime()
            let redacted = try await Redactor.redact(image)
            let seconds = CACurrentMediaTime() - started
            try Task.checkCancellation()
            guard let data = NSBitmapImageRep(cgImage: redacted.image)
                .representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
                throw NSError(domain: "CompanionScreenCapture", code: -3)
            }
            return (data: data, hiddenItems: redacted.hiddenText + redacted.blurredFaces, seconds: seconds)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Cookie and every app on the blocked list never appear in a capture.
    private static func excludedApplications(_ content: SCShareableContent) -> [SCRunningApplication] {
        let blocked = CaptureGuard.blockedBundleIDs.union([Bundle.main.bundleIdentifier ?? ""])
        return content.applications.filter { blocked.contains($0.bundleIdentifier) }
    }
}

/// The size Claude actually reads an image at (Anthropic's reference resize, vision-coordinates):
/// the largest aspect-preserving size with neither padded side over the edge limit and at most
/// `⌈w/28⌉·⌈h/28⌉` visual tokens. Standard-tier limits (1,568 px, 1,568 tokens) fit every model;
/// a high-resolution-tier model reads such an image unchanged too. Images Cookie sends are made
/// this size, so the server never resizes them and the model's pixels are the image's pixels.
enum CookieImageSize {
    static let maxEdge = 1568
    static let maxTokens = 1568
    /// The long edge Cookie captures a screen at: legible, and ~1,300 tokens for 16:10.
    static let screenLongEdge = 1280

    static func tokens(width: Int, height: Int) -> Int {
        ((width + 27) / 28) * ((height + 27) / 28)
    }

    static func processed(width: Int, height: Int, maxEdge: Int = maxEdge, maxTokens: Int = maxTokens) -> (width: Int, height: Int) {
        let width = max(1, width), height = max(1, height)
        func fits(_ w: Int, _ h: Int) -> Bool {
            (w + 27) / 28 * 28 <= maxEdge && (h + 27) / 28 * 28 <= maxEdge && tokens(width: w, height: h) <= maxTokens
        }
        if fits(width, height) { return (width, height) }
        if height > width {
            let rotated = processed(width: height, height: width, maxEdge: maxEdge, maxTokens: maxTokens)
            return (rotated.height, rotated.width)
        }
        let aspect = Double(width) / Double(height)
        var low = 1, high = width
        while low + 1 < high {
            let middle = (low + high) / 2
            if fits(middle, shortEdge(middle, aspect)) { low = middle } else { high = middle }
        }
        return (low, shortEdge(low, aspect))
    }

    /// A display captured with its long edge at `screenLongEdge` (never up-scaled past the display
    /// itself), its short edge rounded as the API rounds, then fitted.
    static func screenshot(displayWidth: Double, displayHeight: Double, backingScale: Double = 2) -> (width: Int, height: Int) {
        let longest = max(displayWidth, displayHeight)
        let long = min(Double(screenLongEdge), longest * max(1, backingScale))
        let aspect = displayWidth / max(1, displayHeight)
        let size = displayWidth >= displayHeight
            ? (Int(long), shortEdge(Int(long), aspect))
            : (shortEdge(Int(long), 1 / aspect), Int(long))
        return processed(width: size.0, height: size.1)
    }

    /// The short edge for a long edge at `aspect` (long ÷ short), rounded half to even like the API.
    private static func shortEdge(_ long: Int, _ aspect: Double) -> Int {
        max(1, Int((Double(long) / aspect).rounded(.toNearestOrEven)))
    }
}
