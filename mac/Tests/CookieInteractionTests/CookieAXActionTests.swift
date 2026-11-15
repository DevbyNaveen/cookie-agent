import Foundation

@MainActor
enum CookieAXActionTests {
    static func run() {
        precondition(!CookieAXActionPolicy.permitsForegroundAction(lookedAtPID: nil, frontmostPID: 10, observedElementCount: 1))
        precondition(!CookieAXActionPolicy.permitsForegroundAction(lookedAtPID: 9, frontmostPID: 10, observedElementCount: 1))
        precondition(!CookieAXActionPolicy.permitsForegroundAction(lookedAtPID: 10, frontmostPID: 10, observedElementCount: 0))
        precondition(CookieAXActionPolicy.permitsForegroundAction(lookedAtPID: 10, frontmostPID: 10, observedElementCount: 1))
        precondition(CookieAXActionPolicy.mustReadAXBefore("press"))
        precondition(CookieAXActionPolicy.mustReadAXBefore("set_value"))
        precondition(!CookieAXActionPolicy.mustReadAXBefore("replace_selection"), "replace_selection must not require a prior look")
        precondition(!CookieAXActionPolicy.mustReadAXBefore("run_script"), "run_script must not require a prior look")
        precondition(CookieAXActionPolicy.containsObservedElement(4, elementIDs: [4, 8]))
        precondition(!CookieAXActionPolicy.containsObservedElement(5, elementIDs: [4, 8]))
        precondition(!CookieAXActionPolicy.permitsCanvasClick(lookedAtPID: nil, frontmostPID: 10, observedElementCount: 0, screenshotCount: 1))
        precondition(!CookieAXActionPolicy.permitsCanvasClick(lookedAtPID: 9, frontmostPID: 10, observedElementCount: 0, screenshotCount: 1))
        precondition(!CookieAXActionPolicy.permitsCanvasClick(lookedAtPID: 10, frontmostPID: 10, observedElementCount: 1, screenshotCount: 1))
        precondition(!CookieAXActionPolicy.permitsCanvasClick(lookedAtPID: 10, frontmostPID: 10, observedElementCount: 0, screenshotCount: 0))
        precondition(CookieAXActionPolicy.permitsCanvasClick(lookedAtPID: 10, frontmostPID: 10, observedElementCount: 0, screenshotCount: 1))
        precondition(CookieAXActionPolicy.modelGuidance.contains("prefer run_script for excel, word, powerpoint, numbers, keynote and pages"))
        precondition(CookieAXActionPolicy.modelGuidance.contains("press and set_value use IDs from the latest look only"))
        let startTask = MacOperator.tools.first { $0.name == "start_task" }
        precondition(startTask?.description.contains("replace_selection") == true)
        print("18 Accessibility action checks passed.")
    }
}
