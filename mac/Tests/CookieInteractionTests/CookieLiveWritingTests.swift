import AppKit

@MainActor
enum CookieLiveWritingTests {
    static func run() async {
        guard let fixture = NSRunningApplication.runningApplications(withBundleIdentifier: "com.enkeon.cookie.writing-fixture").first else {
            preconditionFailure("Launch the disposable Cookie Writing Fixture first")
        }
        fixture.activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(for: .milliseconds(350))
        guard let original = CookieTextDestination.capture(), original.pid == fixture.processIdentifier,
              original.value == "Cookie writing fixture 🦊" else {
            preconditionFailure("Could not bind to the disposable fixture; no user document was changed")
        }
        let insertion = CookieTextInsertion.shared
        let result = await insertion.insert(" — verified", into: original)
        precondition(result.success, result.message)
        precondition(MacOperator.string(original.element, kAXValueAttribute) == original.value + " — verified")
        let undo = await insertion.undo()
        precondition(undo.success, undo.message)
        precondition(MacOperator.string(original.element, kAXValueAttribute) == original.value)
        print("LIVE PASS: cross-app dictation insertion and exact undo")

        var range = CFRange(location: 0, length: 6)
        precondition(AXUIElementSetAttributeValue(original.element, kAXSelectedTextRangeAttribute as CFString,
                                                  AXValueCreate(.cfRange, &range)!) == .success)
        guard let selected = CookieTextDestination.capture(), selected.pid == fixture.processIdentifier,
              selected.selected == "Cookie" else { preconditionFailure("Fixture selection was not exposed") }
        let replacement = await insertion.insert("Selected", into: selected)
        precondition(replacement.success, replacement.message)
        let restore = await insertion.undo()
        precondition(restore.success, restore.message)
        print("LIVE PASS: captured selection replacement and restoration")

        guard let stale = CookieTextDestination.capture(), stale.pid == fixture.processIdentifier else { preconditionFailure("Fixture lost focus") }
        precondition(AXUIElementSetAttributeValue(stale.element, kAXValueAttribute as CFString, "A newer user edit" as CFString) == .success)
        let rejected = await insertion.insert("must not appear", into: stale)
        precondition(!rejected.success)
        precondition(MacOperator.string(stale.element, kAXValueAttribute) == "A newer user edit")
        print("LIVE PASS: stale destination refused without changing the newer edit")
        precondition(AXUIElementSetAttributeValue(original.element, kAXValueAttribute as CFString, original.value as CFString) == .success)
        var end = CFRange(location: original.value.utf16.count, length: 0)
        precondition(AXUIElementSetAttributeValue(original.element, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &end)!) == .success)
        guard let pasteTarget = CookiePasteDestination.capture() else { preconditionFailure("Paste fixture must have a bound target") }
        let clipboard = NSPasteboard.general.string(forType: .string)
        let pasted = await insertion.insert(" pasted safely", into: pasteTarget)
        precondition(pasted.success)
        precondition(MacOperator.string(original.element, kAXValueAttribute) == original.value + " pasted safely")
        precondition(NSPasteboard.general.string(forType: .string) == clipboard)
        print("LIVE PASS: external composer paste fallback and clipboard restoration")
        print("Live writing checks passed.")
    }
}
