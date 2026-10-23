import Foundation

@MainActor
enum CookieWorkPresentationTests {
    static func run() {
        testWorkDraftSurvivesNavigationAndCreatesOnce()
        testSearchFindsPeopleAndNextStepsWithoutChangingWork()
        testDropsRejectUnknownItemsAndPreserveOtherWork()
        print("3 work presentation checks passed.")
    }

    private static func testWorkDraftSurvivesNavigationAndCreatesOnce() {
        let navigation = CookieNavigation()
        let store = WorkStore(connected: false)
        let draft = navigation.workDraft
        draft.title = " \n "
        precondition(draft.create(in: store) == nil && store.items.isEmpty)
        draft.title = "  Research the pilot\n"
        draft.nextStep = "Compare the options"
        draft.person = "A team"
        draft.outcome = "A clear decision"
        draft.hasDueDate = true
        let due = draft.dueDate
        navigation.showsWorkComposer = true
        navigation.showsWorkComposer = false
        navigation.section = .chats
        navigation.section = .board
        navigation.showsWorkComposer = true
        precondition(navigation.workDraft === draft)
        let item = draft.create(in: store)!
        precondition(item.title == "Research the pilot" && item.nextStep == "Compare the options")
        precondition(item.to == "A team" && item.outcome == "A clear decision" && item.due == due)
        precondition(!draft.hasContent && !draft.canCreate && !draft.hasDueDate)
        precondition(draft.create(in: store) == nil && store.items.count == 1)
    }

    private static func testSearchFindsPeopleAndNextStepsWithoutChangingWork() {
        let store = WorkStore(connected: false)
        let first = store.add(title: "Pilot", nextStep: "Prepare proposal", to: "Northwind")
        store.add(title: "Personal research", nextStep: "Review notes")
        precondition(CookieWorkSort.matching(store.items, query: " NORTHWIND  proposal ").map(\.id) == [first.id])
        precondition(CookieWorkSort.matching(store.items, query: "\n ").count == 2)
        precondition(CookieWorkSort.matching(store.items, query: "missing").isEmpty)
        precondition(store.items.count == 2)
    }

    private static func testDropsRejectUnknownItemsAndPreserveOtherWork() {
        let store = WorkStore(connected: false)
        let first = store.add(title: "Move me")
        let second = store.add(title: "Leave me")
        precondition(!moveDroppedWork([UUID().uuidString, "unrelated text"], store: store, column: .cookie))
        precondition(!moveDroppedWork([first.id.uuidString], store: store, column: .needsYou))
        precondition(moveDroppedWork([first.id.uuidString, first.id.uuidString, UUID().uuidString], store: store, column: .done))
        precondition(store.item(first.id)?.column == .done && store.item(second.id)?.column == .needsYou)
        precondition(store.item(first.id)?.history.count == 2)
    }
}
