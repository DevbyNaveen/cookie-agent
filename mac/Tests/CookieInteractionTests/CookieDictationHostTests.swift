import EnkeonVoiceKit
import AppKit

/// Enkeon dictation hosted in Cookie: one keyboard tap, and no memory save or voice edit while a
/// password field has focus.
@MainActor
enum CookieDictationHostTests {
    static func run() async {
        let host = CookieDictation.shared
        let manager = CompanionManager()
        precondition(manager.globalPushToTalkShortcutMonitor === host.controller.shortcuts, "one keyboard tap in the app")

        precondition(CookieDictation.refusesSecure(subrole: "AXSecureTextField"))
        precondition(!CookieDictation.refusesSecure(subrole: "AXTextField"))
        precondition(!CookieDictation.refusesSecure(subrole: nil))

        let (secure, remember, edit) = (host.focusedIsSecure, host.remember, host.edit)
        defer { host.focusedIsSecure = secure; host.remember = remember; host.edit = edit }
        var reached = 0
        host.remember = { _, _ in reached += 1; return ("kept", true) }
        host.edit = { _, _ in reached += 1; return "edited" }

        host.focusedIsSecure = { true }
        let refused = await host.controller.saveToMemory?("my password is", "Safari")
        precondition(refused?.success == false && refused?.message == CookieDictation.secureRefusal)
        do {
            _ = try await host.controller.editSelection?("hunter2", "make it shorter", "Safari")
            preconditionFailure("an edit in a password field must refuse")
        } catch {
            precondition(error.localizedDescription == CookieDictation.secureRefusal)
        }
        precondition(reached == 0, "a password field never reaches memory or the editor")

        host.focusedIsSecure = { false }
        let kept = await host.controller.saveToMemory?("ship Friday", "Notes")
        precondition(kept?.success == true)
        let edited = try? await host.controller.editSelection?("ship friday", "capitalise", "Notes")
        precondition(edited == "edited")
        precondition(reached == 2)
        print("3 dictation host checks passed.")
    }
}
