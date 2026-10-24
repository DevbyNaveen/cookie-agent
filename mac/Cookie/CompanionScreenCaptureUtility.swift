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
    /// Face detection failed on this picture: its text was checked, faces weren't blurred.
    var facesUnchecked = false
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
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

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            // Cookie itself and every blocked app (password managers…) are cut out of the picture.
            let filter = SCContentFilter(display: display, excludingApplications: excludedApplications(content),
                                         exceptingWindows: [])

            let configuration = SCStreamConfiguration()
            let maxDimension = 1280
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            let redacted = try await encodeRedactedJPEG(cgImage, quality: 0.8)
            try Task.checkCancellation()

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: redacted.data,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height,
                hiddenItems: redacted.hiddenItems,
                facesUnchecked: redacted.facesUnchecked
            ))
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
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
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
        let scale = min(screen.backingScaleFactor, 1600 / max(rect.width, rect.height))
        configuration.width = Int(rect.width * scale)
        configuration.height = Int(rect.height * scale)

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return try await encodeRedactedJPEG(cgImage, quality: 0.85)
    }

    typealias RedactedJPEG = (data: Data, hiddenItems: Int, facesUnchecked: Bool)

    /// Vision OCR and JPEG encoding are synchronous CPU work; never run them on the UI/event-tap thread.
    /// Throws `Redactor.Unchecked` when the picture couldn't be checked: it is never sent unchecked.
    nonisolated private static func encodeRedactedJPEG(_ image: CGImage, quality: Double) async throws -> RedactedJPEG {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let redacted = try Redactor.redact(image)
            try Task.checkCancellation()
            guard let data = NSBitmapImageRep(cgImage: redacted.image)
                .representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
                throw NSError(domain: "CompanionScreenCapture", code: -3)
            }
            return (data: data, hiddenItems: redacted.hiddenText + redacted.blurredFaces, facesUnchecked: redacted.facesUnchecked)
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
