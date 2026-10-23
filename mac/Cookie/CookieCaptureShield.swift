import AppKit

/// "Hide from screen sharing" (`CK.Key.showInRecordings`, default true = visible), applied to every
/// Cookie window: the notch panel, the dock panel, the pop-out window, the cursor overlays, and any
/// window or panel added later. One observer covers them all, so no window has to opt in.
///
/// Best effort, on purpose and stated in Settings: macOS has no public API that keeps a window out
/// of every capture. Two asks are made:
/// 1. `NSWindow.sharingType = .none`. Apple calls it "a legacy constant that macOS no longer uses"
///    and says not to rely on it to hide content from capture
///    (https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none);
///    capture built on ScreenCaptureKit ignores it, but legacy CoreGraphics capture and some apps still respect it.
/// 2. The private `CGSSetWindowCaptureExcludeShape`, which browsers have used for screenshot
///    protection since 2024. It is resolved with dlsym, never linked: a macOS without it skips
///    this step. The shape is the window's own frame at origin zero, re-applied on resize, and a
///    NULL region clears it.
/// macOS's own screen recorders still capture Cookie. Cookie's own captures leave its windows out
/// separately (`CompanionScreenCaptureUtility`, SCContentFilter), unaffected here.
@MainActor
enum CookieCaptureShield {
    // The private declarations, in C:
    //   using CGSConnectionID = uint32_t; using CGSWindowID = NSInteger; using CGRegionRef = CFTypeRef;
    //   CG_EXTERN CGSConnectionID CGSMainConnectionID(void);
    //   CG_EXTERN CGError CGSSetWindowCaptureExcludeShape(CGSConnectionID cid, CGSWindowID wid, CGRegionRef region);
    //   CG_EXTERN CGRegionRef CGRegionCreateWithRect(CGRect rect);
    private typealias MainConnectionID = @convention(c) () -> UInt32
    private typealias SetCaptureExcludeShape = @convention(c) (UInt32, Int, CFTypeRef?) -> Int32
    private typealias RegionCreateWithRect = @convention(c) (CGRect) -> Unmanaged<CFTypeRef>?

    private struct Private {
        let connection: MainConnectionID
        let exclude: SetCaptureExcludeShape
        let region: RegionCreateWithRect
    }

    private static let api: Private? = {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let c = dlsym(handle, "CGSMainConnectionID"),
              let e = dlsym(handle, "CGSSetWindowCaptureExcludeShape"),
              let r = dlsym(handle, "CGRegionCreateWithRect") else { return nil }
        return Private(connection: unsafeBitCast(c, to: MainConnectionID.self),
                       exclude: unsafeBitCast(e, to: SetCaptureExcludeShape.self),
                       region: unsafeBitCast(r, to: RegionCreateWithRect.self))
    }()

    private static var observers: [NSObjectProtocol] = []
    private static var hidden: Bool?

    private static var wantsHidden: Bool {
        !(UserDefaults.standard.object(forKey: CK.Key.showInRecordings) as? Bool ?? true)
    }

    /// Call once at launch. Applies to open windows, then follows the setting and new/resized windows.
    static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { applyAll() }
            },
            // A window ordered on screen changes occlusion state; that is when a new panel gets its
            // window number. Resizes need a new shape (it is in window coordinates).
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { refresh(note.object as? NSWindow) }
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { refresh(note.object as? NSWindow) }
            },
        ]
        applyAll()
    }

    private static func applyAll() {
        let hide = wantsHidden
        guard hide != hidden else { return }
        hidden = hide
        NSApp.windows.forEach { apply($0, hide: hide) }
    }

    private static func refresh(_ window: NSWindow?) {
        guard let window, hidden == true else { return }
        apply(window, hide: true)
    }

    private static func apply(_ window: NSWindow, hide: Bool) {
        window.sharingType = hide ? .none : .readOnly
        guard let api, window.windowNumber > 0 else { return }
        let shape = hide ? api.region(CGRect(origin: .zero, size: window.frame.size))?.takeRetainedValue() : nil
        _ = api.exclude(api.connection(), window.windowNumber, shape)
    }
}
