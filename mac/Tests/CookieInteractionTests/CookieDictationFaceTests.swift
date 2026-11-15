import EnkeonVoiceKit
import AppKit

/// Your words in the notch: the fluid orb and a label while you dictate, Cookie's face when Cookie
/// talks, and a recovery notice that never times out.
@MainActor
enum CookieDictationFaceTests {
    static func run() {
        typealias F = NotchVoiceFace
        precondition(F.face(phase: .listening(handsFree: false), editScope: nil, toMemory: false, cookieActive: false) == .words(label: "Listening"))
        precondition(F.face(phase: .listening(handsFree: false), editScope: nil, toMemory: true, cookieActive: false) == .words(label: "To memory"))
        precondition(F.face(phase: .listening(handsFree: false), editScope: "Editing selection", toMemory: false, cookieActive: false) == .words(label: "Editing selection"))
        precondition(F.face(phase: .finishing, editScope: nil, toMemory: false, cookieActive: false) == .words(label: "Writing"))
        precondition(F.face(phase: .idle, editScope: nil, toMemory: false, cookieActive: true) == .cookie)
        precondition(F.face(phase: .listening(handsFree: false), editScope: nil, toMemory: false, cookieActive: true) == .words(label: "Listening"), "your words win: the keys can't start both")
        precondition(F.face(phase: .idle, editScope: nil, toMemory: false, cookieActive: false) == .none)
        precondition(F.face(phase: .done(message: "Inserted", success: true), editScope: nil, toMemory: false, cookieActive: false) == .none)

        // Where no caret is reported (terminals, Electron), the words still show: their tail, in the notch.
        precondition(NotchVoiceFace.tail("", limit: 10) == "")
        precondition(NotchVoiceFace.tail("short", limit: 10) == "short")
        precondition(NotchVoiceFace.tail("one two three four five", limit: 10) == "…four five")

        // A dictation that couldn't be confirmed stays until Copy or Dismiss: no timer closes it.
        let recovery = NotchNotice.recovery("ship it Friday")
        precondition(recovery.copyText == "ship it Friday" && recovery.keepsUntilActed)
        precondition(!NotchNotice.closesOnItsOwn(recovery, shownFor: 600), "still there after ten minutes")
        let reply = NotchNotice(threadID: UUID(), title: "Cookie", message: "Done", failed: false)
        precondition(!reply.keepsUntilActed && NotchNotice.closesOnItsOwn(reply, shownFor: 7))
        print("4 dictation face checks passed.")
    }
}
