import Foundation

@MainActor
enum CookieTeachScheduleTests {
    static func run() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cookie-schedule-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let step = CookieTeachStep.press(app: "Notes", role: "Button", label: "New note")
            let file = try CookieSkills.save(name: "Weekly report", steps: [step], directory: root)
            let slug = file.deletingLastPathComponent().lastPathComponent
            precondition(CookieSkills.workflowSlug(named: "weekly report", in: root) == slug)
            precondition(CookieSkills.workflowText(slug: slug, in: root)?.contains("New note") == true)
            precondition(CookieSkills.workflowText(slug: "../outside", in: root) == nil)
            let routine = CookieRoutine(instruction: "Run Weekly report", cadence: .weekly(weekday: 2, hour: 9, minute: 0), skillSlug: slug)
            precondition(routine.skillSlug == slug)
            let fixture = HarnessApproval(id: "approval-1", tool: "start_task", effect: "outbound",
                                          preview: #"start_task {"plan":"Review report","apps":"Notes"}"#, reason: "")
            precondition(CookieBackgroundRuns.approvalQuestion(fixture).contains("Let Cookie do this"))
        } catch { preconditionFailure("schedule workflow fixture failed: \(error)") }
        print("5 taught workflow scheduling checks passed.")
    }
}
