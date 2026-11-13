import Combine
import AppKit
import SwiftUI

@main
struct EnkeonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Enkeon", id: "main") {
            MainView()
                .environmentObject(delegate.model)
                .onOpenURL { url in
                    delegate.model.openMeetingURL(url)
                }
        }
        .windowStyle(.hiddenTitleBar)
        // Most of the screen it opens on, centred: the dashboard needs room to read.
        .defaultWindowPlacement { _, context in
            let area = context.defaultDisplay.visibleRect
            let size = CGSize(width: min(area.width * 0.74, 1320), height: min(area.height * 0.8, 860))
            return WindowPlacement(CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2), size: size)
        }
        .windowResizability(.contentMinSize)
        // Opens at every launch, whatever window restoration remembered from a quit.
        .defaultLaunchBehavior(.presented)
        // ponytail: opens at the default placement every launch; restore the last frame once the layout settles.
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuBarContent().environmentObject(delegate.model)
        } label: {
            Image(nsImage: BrandMark.template.menuBarSized)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let showFloatingBar = true
    let model = AppModel()
    private var bar: FloatingBarPanel?
    private var cursorPreview: CursorPreviewPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Line-buffered, so the engine's log lines reach a pipe or a file as they happen.
        setvbuf(stdout, nil, _IOLBF, 0)
        model.launch()
        guard Self.showFloatingBar else { return }
        let bar = FloatingBarPanel(model: model)
        bar.place()
        bar.orderFrontRegardless()
        self.bar = bar
        cursorPreview = CursorPreviewPanel(model: model)
        // A display added, removed or rearranged: keep the bar on screen.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.bar?.place() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { model.completer.stop() }
    func application(_ application: NSApplication, open urls: [URL]) { urls.forEach(model.openMeetingURL) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.openPage(model.page) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.meetings.isActive || model.meetings.pending > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A meeting is still recording or transcribing"
        alert.informativeText = "Stop the meeting and let transcription finish before quitting."
        alert.addButton(withTitle: "Keep Enkeon open")
        alert.runModal()
        return .terminateCancel
    }

    /// Closing the window keeps dictation running; the menu bar and ⌃⌘ stay.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Enkeon") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Open Console") { model.openConsole() }
        Button(model.meetings.isActive ? "Open current meeting" : "Start meeting…") {
            openWindow(id: "main")
            model.openMeetings(setup: !model.meetings.isActive)
        }
        Divider()
        Button("Copy last result (⌃⌘C)") { model.dictation.copyLast() }
            .disabled(model.dictation.lastResultText.isEmpty || model.dictation.phase == .finishing)
        Text("Focus a field, then press ⌃⌘V to paste last")
        Divider()
        Text(model.isSetUp ? "Hold Fn or ⌃⌘ to dictate" : "Finish setup to dictate")
        Divider()
        Button("Quit Enkeon") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
