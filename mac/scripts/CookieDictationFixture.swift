// Disposable native editor for --verify-live-dictation. No files or network access.
import AppKit

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 120, y: 220, width: 480, height: 220),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Cookie writing verification — disposable text"
        let editor = NSTextView(frame: NSRect(x: 16, y: 16, width: 448, height: 188))
        editor.isRichText = false
        editor.font = .systemFont(ofSize: 17)
        editor.string = "Cookie writing fixture 🦊"
        window.contentView?.addSubview(editor)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
