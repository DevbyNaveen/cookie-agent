import Foundation

@MainActor
enum CookieMemoryHandshakePlanTests {
    static func run() {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let planURL = repositoryRoot.appendingPathComponent("docs/plans/memory-handshake.md")
        guard let plan = try? String(contentsOf: planURL, encoding: .utf8) else {
            preconditionFailure("Memory handshake plan is missing")
        }
        precondition(plan.contains("POST /v1/public-cells"))
        precondition(plan.contains("QR code") && plan.contains("share link"))
        precondition(plan.contains("Selection starts empty"))
        precondition(plan.contains("DELETE /v1/public-cells/{share_id}"))
        precondition(plan.contains("Revocation stops future access") && plan.contains("not implement this sharing flow yet"))
        print("5 memory handshake plan checks passed.")
    }
}
