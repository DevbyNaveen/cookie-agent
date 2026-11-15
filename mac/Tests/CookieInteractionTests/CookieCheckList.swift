import Foundation

/// Named checks that report every failure in a suite before stopping, so one
/// broken rule doesn't hide the next.
@MainActor
final class CookieCheckList {
    private(set) var passed = 0
    private(set) var failed: [String] = []

    func expect(_ ok: @autoclosure () -> Bool, _ name: String) {
        if ok() { passed += 1 } else { failed.append(name); print("FAIL \(name)") }
    }

    func finish(_ suite: String) {
        precondition(failed.isEmpty, "\(suite) failed: \(failed.joined(separator: ", "))")
    }

    /// Lets main-actor tasks (mining, file loads) run until `done` or the deadline.
    static func spin(seconds: TimeInterval = 3, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
}
