import Foundation
import Testing

@testable import KandevKit

/// A source with no socket behind it. Each call is recorded, so tests can assert
/// what the store asked for as well as what it produced.
actor FakeTaskSource: KandevTaskSource {
    enum Failure: Error, Equatable {
        case workspaces
        case tasks
    }

    var workspacesResult: Result<[KandevWorkspace], any Error> = .success([])
    var workflowsResult: Result<[KandevWorkflow], any Error> = .success([])
    var stepsByWorkflow: [String: [KandevWorkflowStep]] = [:]
    /// Tasks keyed by page number, so paging can be exercised.
    var tasksByPage: [Int: KandevTaskList] = [:]
    private(set) var requestedPages: [Int] = []
    private(set) var requestedQueries: [KandevTaskListQuery] = []
    private(set) var stepRequests: [String] = []

    func setWorkspaces(_ workspaces: [KandevWorkspace]) {
        workspacesResult = .success(workspaces)
    }

    func setWorkflows(_ workflows: [KandevWorkflow]) {
        workflowsResult = .success(workflows)
    }

    func setSteps(_ steps: [KandevWorkflowStep], forWorkflow id: String) {
        stepsByWorkflow[id] = steps
    }

    func setTasks(_ tasks: [KandevTask], total: Int? = nil, page: Int = 1) {
        tasksByPage[page] = KandevTaskList(tasks: tasks, total: total ?? tasks.count)
    }

    func workspaces() async throws -> [KandevWorkspace] {
        try workspacesResult.get()
    }

    func workflows(workspaceID: String) async throws -> [KandevWorkflow] {
        try workflowsResult.get()
    }

    func workflowSteps(workflowID: String) async throws -> [KandevWorkflowStep] {
        stepRequests.append(workflowID)
        return stepsByWorkflow[workflowID] ?? []
    }

    var repositoriesResult: Result<[KandevRepository], any Error> = .success([])

    func setRepositories(_ repositories: [KandevRepository]) {
        repositoriesResult = .success(repositories)
    }

    func repositories(workspaceID: String) async throws -> [KandevRepository] {
        try repositoriesResult.get()
    }

    /// Set to make the next `tasks` call fail, to exercise the store's error path.
    var tasksFailure: (any Error)?

    func failNextTasksCall(with error: any Error = Failure.tasks) {
        tasksFailure = error
    }

    func tasks(workspaceID: String, query: KandevTaskListQuery) async throws -> KandevTaskList {
        let page = query.page ?? 1
        requestedPages.append(page)
        requestedQueries.append(query)
        if let tasksFailure {
            self.tasksFailure = nil
            throw tasksFailure
        }
        guard let result = tasksByPage[page] else {
            return KandevTaskList(tasks: [], total: 0)
        }
        return result
    }
}

func makeTask(
    id: String,
    title: String,
    stepID: String?,
    state: String = "IN_PROGRESS",
    sessionState: String? = "WAITING_FOR_INPUT",
    activity: String? = "2026-10-04T18:07:04.074817797Z",
    archived: Bool = false,
    ephemeral: Bool = false,
    parentID: String? = nil,
    repositoryID: String? = nil
) -> KandevTask {
    var task = KandevTask(
        id: id,
        title: title,
        state: state,
        workflowStepID: stepID,
        isEphemeral: ephemeral,
        statusSummary: activity.map {
            KandevStatusSummary(lastActivityAt: KandevTimestamp(raw: $0))
        },
        archivedAt: archived ? KandevTimestamp(raw: "2026-10-05T00:00:00Z") : nil,
        primarySessionState: sessionState
    )
    task.parentID = parentID
    task.repositories = repositoryID.map { [KandevTaskRepository(id: "\(id)-repo", repositoryID: $0)] }
    return task
}

let workspace = KandevWorkspace(id: "w1", name: "Default Workspace", scopes: [])

@MainActor
@Suite("TaskListStore")
struct TaskListStoreTests {
    private func loadedStore(
        tasks: [KandevTask],
        steps: [KandevWorkflowStep] = [
            KandevWorkflowStep(id: "step-review", name: "Review", position: 2),
            KandevWorkflowStep(id: "step-work", name: "In Progress", position: 1),
        ],
        total: Int? = nil
    ) async -> (TaskListStore, FakeTaskSource) {
        let source = FakeTaskSource()
        await source.setWorkspaces([workspace])
        await source.setWorkflows([KandevWorkflow(id: "wf1", name: "Development")])
        await source.setSteps(steps, forWorkflow: "wf1")
        await source.setTasks(tasks, total: total)
        let store = TaskListStore(source: source, pageSize: 2)
        await store.refresh()
        return (store, source)
    }

    @Test("a cancelled refresh keeps the rows and reports nothing")
    func cancelledRefreshIsNotAFailure() async {
        let (store, source) = await loadedStore(tasks: [
            makeTask(id: "t1", title: "One", stepID: "step-review"),
        ])

        await source.failNextTasksCall(with: URLError(.cancelled))
        await store.refresh()

        #expect(store.phase == .loaded)
        #expect(store.rows.map(\.id) == ["t1"])
    }

    @Test("resolves every row's step name from the workflow steps")
    func resolvesStepNames() async {
        let (store, _) = await loadedStore(tasks: [
            makeTask(id: "t1", title: "One", stepID: "step-review"),
            makeTask(id: "t2", title: "Two", stepID: "step-work"),
        ])

        #expect(store.phase == .loaded)
        #expect(store.rows.map(\.stepName) == ["Review", "In Progress"])
        #expect(store.unresolvedStepCount == 0)
        #expect(store.workspaceName == "Default Workspace")
    }

    /// A blank chip is a bug the user cannot diagnose, so it is counted rather
    /// than hidden.
    @Test("counts rows whose step could not be resolved instead of hiding it")
    func countsUnresolvedSteps() async {
        let (store, _) = await loadedStore(tasks: [
            makeTask(id: "t1", title: "One", stepID: "step-missing"),
            makeTask(id: "t2", title: "Two", stepID: "step-work"),
        ])

        #expect(store.rows[0].stepName == nil)
        #expect(store.unresolvedStepCount == 1)
    }

    @Test("takes working state from the session, not the task state")
    func workingComesFromSession() async {
        let (store, _) = await loadedStore(tasks: [
            makeTask(id: "t1", title: "Running", stepID: "step-work", state: "REVIEW", sessionState: "RUNNING"),
            makeTask(id: "t2", title: "Idle", stepID: "step-work", state: "REVIEW", sessionState: "WAITING_FOR_INPUT"),
        ])

        // The task says REVIEW for both; only the session distinguishes them.
        #expect(store.rows[0].isWorking)
        #expect(store.rows[1].isWorking == false)
    }

    @Test("keeps the row's last activity as a date, not a formatted string")
    func keepsLastActivity() async {
        let (store, _) = await loadedStore(tasks: [makeTask(id: "t1", title: "One", stepID: "step-work")])

        #expect(store.rows.first?.lastActivity != nil)
    }

    @Test("asks for one page at a time and stops when the server is exhausted")
    func pagesAndStops() async {
        let (store, source) = await loadedStore(
            tasks: [makeTask(id: "t1", title: "One", stepID: "step-work"),
                    makeTask(id: "t2", title: "Two", stepID: "step-work")],
            total: 3
        )
        #expect(store.hasMore)
        #expect(store.rows.count == 2)

        await source.setTasks([makeTask(id: "t3", title: "Three", stepID: "step-work")], total: 3, page: 2)
        await store.loadMore()

        #expect(store.rows.count == 3)
        #expect(store.hasMore == false)
        var pages = await source.requestedPages
        #expect(pages == [1, 2])

        // Once exhausted, further calls must not hit the server again.
        await store.loadMore()
        pages = await source.requestedPages
        #expect(pages == [1, 2])
    }

    /// The shelf needs the chats, so the board's own request asks for them: the server leaves
    /// ephemeral tasks out unless asked.
    @Test("the board asks for the chats it shows")
    func boardAsksForChats() async {
        let (store, source) = await loadedStore(tasks: [makeTask(id: "t1", title: "One", stepID: "step-work")])

        #expect(store.query.includeEphemeral)
        let queries = await source.requestedQueries
        #expect(queries.last?.includeEphemeral == true)
    }

    /// The next page has to be the same list as the page it appends to. It used to be
    /// built from scratch, which dropped the archive flag — so paging the archive
    /// quietly fetched active work — and would have dropped the ask for chats too.
    @Test("the next page keeps the flags the first page was read with")
    func nextPageKeepsTheQuery() async {
        let (store, source) = await loadedStore(
            tasks: [makeTask(id: "t1", title: "One", stepID: "step-work")],
            total: 3
        )
        await source.setTasks([makeTask(id: "t2", title: "Two", stepID: "step-work")], total: 3, page: 2)

        await store.loadMore()

        let queries = await source.requestedQueries
        let pages = await source.requestedPages
        #expect(pages == [1, 2])
        #expect(queries.last?.page == 2)
        #expect(queries.last?.onlyEphemeral == false)
        #expect(queries.last?.archived == .active)
    }

    @Test("paging inside the archive asks for archived work again")
    func pagingTheArchiveKeepsTheMode() async {
        let (store, source) = await loadedStore(
            tasks: [makeTask(id: "t9", title: "In the archive", stepID: nil)],
            total: 3
        )
        await store.setShowingArchived(true)
        await source.setTasks([makeTask(id: "t10", title: "Also archived", stepID: nil)], total: 3, page: 2)

        await store.loadMore()

        let queries = await source.requestedQueries
        #expect(queries.last?.page == 2)
        #expect(queries.last?.archived == .onlyArchived, "the next page must stay in the archive")
    }

    @Test("fetches each workflow's steps once, not once per refresh")
    func cachesSteps() async {
        let (store, source) = await loadedStore(tasks: [makeTask(id: "t1", title: "One", stepID: "step-work")])

        await store.refresh()
        await store.refresh()

        let stepRequests = await source.stepRequests
        #expect(stepRequests == ["wf1"])
    }

    @Test("reports a failure without discarding the rows already on screen")
    func failureKeepsRows() async {
        let (store, source) = await loadedStore(
            tasks: [
                makeTask(id: "t1", title: "One", stepID: "step-work"),
                makeTask(id: "t2", title: "Two", stepID: "step-work"),
            ],
            total: 5
        )
        #expect(store.rows.count == 2)
        #expect(store.hasMore)

        await source.failNextTasksCall()
        await store.loadMore()

        #expect(store.rows.count == 2)
        if case .failed = store.phase {} else {
            Issue.record("expected a failed phase, got \(store.phase)")
        }
    }

    @Test("a server with no workspaces fails with something readable")
    func emptyServerFailsReadably() async {
        let source = FakeTaskSource()
        await source.setWorkspaces([])
        let store = TaskListStore(source: source)

        await store.refresh()

        guard case .failed(let message) = store.phase else {
            Issue.record("expected failure, got \(store.phase)")
            return
        }
        #expect(message.contains("no workspaces"))
    }
}



@MainActor
@Suite("TaskListStore step names")
struct TaskListStepNameTests {
    @Test("exposes step ids to names, which is what the transcript header needs")
    func exposesStepNames() async {
        let source = FakeTaskSource()
        await source.setWorkspaces([workspace])
        await source.setWorkflows([KandevWorkflow(id: "wf1", name: "Development")])
        await source.setSteps(
            [
                KandevWorkflowStep(id: "step-work", name: "In Progress", position: 1, color: "bg-blue-500"),
                KandevWorkflowStep(id: "step-review", name: "Review", position: 2),
            ],
            forWorkflow: "wf1"
        )
        await source.setTasks([makeTask(id: "t1", title: "One", stepID: "step-work")])
        let store = TaskListStore(source: source)

        await store.refresh()

        #expect(store.stepNames == ["step-work": "In Progress", "step-review": "Review"])
        #expect(store.stepsByID["step-work"]?.color == "bg-blue-500")
    }

    @Test("a failed refresh recovers on the next attempt")
    func recoversAfterFailure() async {
        let source = FakeTaskSource()
        await source.setWorkspaces([])
        let store = TaskListStore(source: source)
        await store.refresh()
        if case .failed = store.phase {} else {
            Issue.record("expected the first refresh to fail")
        }

        await source.setWorkspaces([workspace])
        await source.setWorkflows([KandevWorkflow(id: "wf1", name: "Development")])
        await source.setTasks([makeTask(id: "t1", title: "One", stepID: nil)])
        await store.refresh()

        #expect(store.phase == .loaded)
        #expect(store.rows.count == 1)
    }
}

@MainActor
@Suite("TaskListStore live updates")
struct TaskListLiveUpdateTests {
    private func loaded(hub: KandevNotificationHub? = nil) async -> (TaskListStore, FakeTaskSource) {
        let source = FakeTaskSource()
        await source.setWorkspaces([workspace])
        await source.setWorkflows([KandevWorkflow(id: "wf1", name: "Development")])
        await source.setSteps(
            [KandevWorkflowStep(id: "step-work", name: "In Progress", position: 1)],
            forWorkflow: "wf1"
        )
        await source.setTasks([
            makeTask(id: "t1", title: "Implement embedded Zenoh transport", stepID: "step-work",
                     sessionState: "WAITING_FOR_INPUT"),
            makeTask(id: "t2", title: "Zenoh device driver", stepID: "step-work",
                     sessionState: "WAITING_FOR_INPUT"),
        ])
        let store = TaskListStore(source: source, hub: hub, catchUpDelay: .milliseconds(20))
        await store.refresh()
        return (store, source)
    }

    /// The spine is the primary session's condition, and that arrives as `session.state_changed`
    /// rather than as a task change — so the list has to be listening for it, not merely able to
    /// apply it.
    @Test("watching follows a session's state from the hub")
    func watchingFollowsSessionState() async {
        let stream = StubConversationStream()
        await stream.hub.start()
        let (store, _) = await loaded(hub: stream.hub)
        await store.startWatching()
        #expect(store.rows.first { $0.id == "t1" }?.isWorking == false)

        stream.pushSessionState(task: "t1", state: "RUNNING")

        let working = await waitUntil { store.rows.first { $0.id == "t1" }?.isWorking == true }
        #expect(working, "a session that started should move the row's spine")
        store.stopWatching()
    }

    /// The frame that arrives most often carries only a status summary. It must
    /// move the spinner without disturbing anything it did not mention.
    @Test("a summary update moves the spinner and leaves the title alone")
    func summaryUpdatePatchesInPlace() async {
        let (store, _) = await loaded()
        #expect(store.rows.first?.isWorking == false)

        store.apply(
            KandevTaskSignal(
                kind: .updated,
                update: KandevTaskUpdate(
                    taskID: "t1",
                    primarySessionState: "RUNNING",
                    statusSummary: KandevStatusSummary(
                        lastActivityAt: KandevTimestamp(raw: "2026-10-04T21:38:05.364674695Z")
                    )
                )
            )
        )

        #expect(store.rows.first?.isWorking == true, "the spinner should follow the session")
        #expect(store.rows.first?.title == "Implement embedded Zenoh transport")
        #expect(store.rows.first?.stepName == "In Progress", "the step chip survived the patch")
        #expect(store.rows.first?.lastActivity != nil)
        #expect(store.rows.count == 2, "no row was invented or lost")
    }

    @Test("an update for an unknown task is admitted rather than swallowed")
    func unknownTaskMarksTheListBehind() async {
        let (store, _) = await loaded()

        store.apply(KandevTaskSignal(kind: .created, update: KandevTaskUpdate(taskID: "a-task-created-elsewhere")))

        #expect(store.hasUnseenTasks, "the list should admit it is behind")
    }

    @Test("a burst of unknown tasks leads to one catch-up, not one per frame")
    func burstsAreCoalesced() async {
        let (store, source) = await loaded()
        let pagesBefore = await source.requestedPages.count

        for index in 0..<5 {
            store.apply(KandevTaskSignal(kind: .created, update: KandevTaskUpdate(taskID: "new-\(index)")))
        }

        let caughtUp = await waitUntil(timeout: .seconds(2)) { !store.hasUnseenTasks }
        #expect(caughtUp, "the catch-up never ran")
        let pagesAfter = await source.requestedPages.count
        #expect(pagesAfter == pagesBefore + 1, "five frames should cause one refetch, not five")
    }

    /// Found by deleting a task on a live server while the app was open: the row
    /// stayed. A deletion carries the whole task, so patching it in place leaves a
    /// row for a task that no longer exists.
    @Test("a deleted task's row disappears")
    func deletionRemovesTheRow() async {
        let (store, _) = await loaded()
        #expect(store.rows.count == 2)

        store.apply(KandevTaskSignal(kind: .deleted, update: KandevTaskUpdate(taskID: "t1")))

        #expect(store.rows.count == 1)
        #expect(store.rows.first?.id == "t2", "the wrong row went")
    }

    @Test("an archived task's row disappears too, because it left the list")
    func archivingRemovesTheRow() async {
        let (store, _) = await loaded()

        store.apply(KandevTaskSignal(kind: .archived, update: KandevTaskUpdate(taskID: "t2")))

        #expect(store.rows.count == 1)
        #expect(store.rows.first?.id == "t1")
    }

    @Test("deleting a task the list never had is not a failure")
    func deletingAnUnknownRowIsQuiet() async {
        let (store, _) = await loaded()

        store.apply(KandevTaskSignal(kind: .deleted, update: KandevTaskUpdate(taskID: "never-seen")))

        #expect(store.rows.count == 2)
        #expect(store.hasUnseenTasks == false)
    }

    @Test("an empty list, then a task mentioned by the server")
    func emptyListCatchesUp() async {
        let source = FakeTaskSource()
        await source.setWorkspaces([workspace])
        await source.setWorkflows([KandevWorkflow(id: "wf1", name: "Development")])
        await source.setTasks([])
        let store = TaskListStore(source: source, catchUpDelay: .milliseconds(20))
        await store.refresh()
        #expect(store.rows.isEmpty)

        await source.setTasks([makeTask(id: "t9", title: "Appeared", stepID: nil)])
        store.apply(KandevTaskSignal(kind: .created, update: KandevTaskUpdate(taskID: "t9")))

        let appeared = await waitUntil(timeout: .seconds(2)) { store.rows.count == 1 }
        #expect(appeared, "the new task never arrived")
        #expect(store.rows.first?.title == "Appeared")
    }
}

@MainActor
@Suite("TaskListStore session state")
struct TaskListSessionStateTests {
    private func loaded() async -> TaskListStore {
        let source = FakeTaskSource()
        await source.setWorkspaces([workspace])
        await source.setWorkflows([KandevWorkflow(id: "wf1", name: "Development")])
        await source.setTasks([
            makeTask(id: "t1", title: "One", stepID: nil, sessionState: "WAITING_FOR_INPUT"),
        ])
        let store = TaskListStore(source: source)
        await store.refresh()
        return store
    }

    /// The direct signal: a row's spinner reads the session, and this is the
    /// session saying so rather than the task summary paraphrasing it.
    @Test("a session's state moves the row's spinner")
    func sessionStateMovesTheSpinner() async {
        let store = await loaded()
        #expect(store.rows.first?.isWorking == false)

        store.apply(
            KandevSessionStateChange(
                sessionID: "s1",
                taskID: "t1",
                newState: "RUNNING",
                foregroundActivity: "generating",
                isPrimary: true
            )
        )

        #expect(store.rows.first?.isWorking == true)
        #expect(store.rows.first?.title == "One", "nothing else about the row changed")
    }

    /// A row shows the task's default session. A change to a secondary session is
    /// not the row's business, and the frame says which it is.
    @Test("a secondary session's change does not move the row")
    func secondarySessionIsIgnored() async {
        let store = await loaded()

        store.apply(
            KandevSessionStateChange(
                sessionID: "s2",
                taskID: "t1",
                newState: "RUNNING",
                isPrimary: false
            )
        )

        #expect(store.rows.first?.isWorking == false)
    }

    @Test("a change for a task the list does not hold is ignored")
    func unknownTaskIsIgnored() async {
        let store = await loaded()

        store.apply(KandevSessionStateChange(sessionID: "s9", taskID: "not-here", newState: "RUNNING"))

        #expect(store.rows.count == 1)
        #expect(store.rows.first?.isWorking == false)
    }

    /// The board and the archive are different requests to the server, and the
    /// active page does not contain the archived work at all.
    @Test("switching to the archive refetches rather than filtering what is held")
    func showingArchivedRefetches() async {
        let source = FakeTaskSource()
        await source.setWorkspaces([workspace])
        await source.setWorkflows([KandevWorkflow(id: "wf1", name: "Development")])
        await source.setTasks([makeTask(id: "t1", title: "On the board", stepID: nil)])
        let store = TaskListStore(source: source)
        await store.refresh()
        #expect(store.showingArchived == false)

        await source.setTasks([makeTask(id: "t9", title: "In the archive", stepID: nil, archived: true)])
        await store.setShowingArchived(true)

        #expect(store.showingArchived)
        #expect(store.rows.map(\.title) == ["In the archive"])
        #expect(store.query.archived == .onlyArchived)
    }

    /// The archive is a different set, whatever the server decides to return. A page
    /// that carried the board into the archive is drawn as the archive anyway — which is
    /// what the toggle promises, and the client is the one that can keep it.
    @Test("the board and the archive are sets, not a flag on the same list")
    func archiveIsASet() async {
        let source = FakeTaskSource()
        await source.setWorkspaces([workspace])
        await source.setWorkflows([KandevWorkflow(id: "wf1", name: "Development")])
        // One page holding both, which is the state this guards: the archive is drawn
        // from the archived rows in it, not from the page as it arrived.
        await source.setTasks([
            makeTask(id: "t1", title: "On the board", stepID: nil),
            makeTask(id: "t2", title: "Archived", stepID: nil, archived: true),
        ])
        let store = TaskListStore(source: source)

        await store.refresh()
        #expect(store.rows.map(\.id) == ["t1"], "an archived task must not sit on the board")

        await store.setShowingArchived(true)
        #expect(store.rows.map(\.id) == ["t2"], "the archive is the archived set, not the board again")
    }
}

@Suite("TaskRow attention")
struct TaskAttentionTests {
    private func row(state: String?, sessionState: String?, activity: String? = nil) -> TaskRow {
        let task = makeTask(
            id: "t1",
            title: "A task",
            stepID: nil,
            state: state ?? "IN_PROGRESS",
            sessionState: sessionState
        )
        var withActivity = task
        withActivity.foregroundActivity = activity
        return TaskRow(task: withActivity, steps: [:])
    }

    /// The judgement this drives the whole list's one loud signal with.
    @Test("a task at a review gate needs a person")
    func reviewNeedsAttention() {
        #expect(row(state: "REVIEW", sessionState: "WAITING_FOR_INPUT").needsAttention)
    }

    @Test("a session waiting for input needs a person, whatever the task's state says")
    func waitingForInputNeedsAttention() {
        #expect(row(state: "IN_PROGRESS", sessionState: "WAITING_FOR_INPUT").needsAttention)
    }

    /// Work in flight needs nobody, and this is the case that must not cry wolf.
    @Test("a working agent needs nobody")
    func workingNeedsNobody() {
        #expect(row(state: "REVIEW", sessionState: "RUNNING").needsAttention == false)
        #expect(row(state: "IN_PROGRESS", sessionState: "RUNNING", activity: "generating").needsAttention == false)
    }

    @Test("a task nobody has started needs nobody")
    func unstartedNeedsNobody() {
        #expect(row(state: "CREATED", sessionState: nil).needsAttention == false)
        #expect(row(state: "IN_PROGRESS", sessionState: "STARTING").needsAttention == false)
    }

    /// Broad on purpose: a failure, a question, and a gate all want the same person, which is what
    /// the list's one line counts.
    @Test("anything waiting on a person wants one")
    func anythingWaitingWantsAPerson() {
        #expect(row(state: "REVIEW", sessionState: "WAITING_FOR_INPUT").wantsAPerson)
        #expect(row(state: "FAILED", sessionState: nil).wantsAPerson)
        #expect(row(state: "IN_PROGRESS", sessionState: "RUNNING").wantsAPerson == false)
        #expect(
            TaskRow(
                id: "t1",
                title: "A task",
                stepName: nil,
                isWorking: false,
                isAwaitingAnswer: true,
                lastActivity: nil
            ).wantsAPerson
        )
    }
}

@Suite("Subtasks")
struct SubtaskArrangementTests {
    private func row(_ id: String, parent: String? = nil, title: String = "t") -> TaskRow {
        TaskRow(
            id: id,
            title: title,
            stepName: nil,
            isWorking: false,
            parentID: parent,
            lastActivity: nil
        )
    }

    /// The hierarchy the server sends, drawn: a subtask follows its parent.
    @Test("a subtask sits under the task it belongs to")
    func childFollowsParent() {
        let arranged = TaskListStore.nested([
            row("a", title: "Parent"),
            row("b", title: "Another task"),
            row("c", parent: "a", title: "Child"),
        ])

        #expect(arranged.map(\.id) == ["a", "c", "b"], "the child moved up under its parent")
        #expect(arranged.first { $0.id == "a" }?.depth == 0)
        #expect(arranged.first { $0.id == "c" }?.depth == 1)
    }

    /// A page boundary or an archived parent must not hide a task. The server's own
    /// client keeps an orphan at the top level, and this agrees with it.
    @Test("a subtask whose parent is not loaded stays a task")
    func orphanStaysTopLevel() {
        let arranged = TaskListStore.nested([
            row("b", title: "Another task"),
            row("c", parent: "missing", title: "Orphan"),
        ])

        #expect(arranged.map(\.id) == ["b", "c"])
        #expect(arranged.allSatisfy { $0.depth == 0 })
    }

    /// An indent with no end runs off the side of a phone. The depth stops at one, but
    /// the row must not stop existing — a task that vanishes is worse than one indented
    /// one level too little.
    @Test("a subtask of a subtask is drawn once, one level in")
    func oneLevelOnly() {
        let arranged = TaskListStore.nested([
            row("a"),
            row("c", parent: "a"),
            row("d", parent: "c"),
        ])

        #expect(arranged.map(\.id) == ["a", "c", "d"], "nothing is dropped")
        #expect(arranged.first { $0.id == "d" }?.depth == 1)
    }

    /// Not something the server should send, and not something that gets to hang the
    /// list either.
    @Test("a parent chain that loops back does not recurse forever")
    func cyclesTerminate() {
        let arranged = TaskListStore.nested([
            row("a", parent: "b"),
            row("b", parent: "a"),
        ])

        #expect(arranged.count == 2)
        #expect(Set(arranged.map(\.id)) == ["a", "b"])
    }

    @Test("tasks with no parent keep the server's order")
    func orderIsPreserved() {
        let arranged = TaskListStore.nested([row("a"), row("b"), row("c")])
        #expect(arranged.map(\.id) == ["a", "b", "c"])
    }
}

@MainActor
@Suite("Task list, grouped")
struct TaskListGroupingTests {
    private func store() async -> (TaskListStore, FakeTaskSource) {
        let source = FakeTaskSource()
        await source.setWorkspaces([KandevWorkspace(id: "w1", name: "Default", scopes: [])])
        await source.setRepositories([
            KandevRepository(id: "r1", name: "pocket-sand", sourceType: "local"),
            KandevRepository(id: "r2", name: "kandev", sourceType: "github"),
        ])
        // The workspace is resolved from the server, not passed in.
        let store = TaskListStore(source: source)
        return (store, source)
    }

    private func task(
        _ id: String,
        _ title: String,
        repository: String? = nil,
        parent: String? = nil,
        ephemeral: Bool = false
    ) -> KandevTask {
        KandevTask(
            id: id,
            title: title,
            parentID: parent,
            isEphemeral: ephemeral,
            repositories: repository.map { [KandevTaskRepository(id: "link-\(id)", repositoryID: $0)] }
        )
    }

    @Test("chats first, then a section per repository, in the order they appear")
    func groupsByRepository() async {
        let (store, source) = await store()
        await source.setTasks([
            task("t1", "Fix the parser", repository: "r2"),
            task("t2", "Ask about retries", ephemeral: true),
            task("t3", "Nested work", repository: "r1"),
            task("t4", "Tidy the docs", repository: "r1"),
            task("t5", "Fix the lexer", repository: "r2"),
        ])

        await store.refresh()

        let sections = store.sections(.byRepository)
        #expect(sections.map(\.id) == ["chats", "r2", "r1"])
        #expect(sections.map(\.title) == ["Quick Chats", "kandev", "pocket-sand"])
        #expect(sections[0].isChats)
        #expect(sections[1].rows.map(\.id) == ["t1", "t5"], "the server's order, not ours")
        #expect(sections[2].rows.map(\.id) == ["t3", "t4"])
    }

    /// One list, with the project on the row instead of in a heading. The chats keep their own
    /// section: they are not filed anywhere, so no arrangement of the work can hold them.
    @Test("the flat listing is one section, and chats stay apart")
    func flatListing() async {
        let (store, source) = await store()
        await source.setTasks([
            task("t1", "Fix the parser", repository: "r2"),
            task("t2", "Ask about retries", ephemeral: true),
            task("t3", "Nested work", repository: "r1"),
        ])
        await store.refresh()

        let sections = store.sections(.flat)
        #expect(sections.map(\.id) == ["chats", "all"])
        #expect(sections[1].title == nil)
        #expect(sections[1].rows.map(\.id) == ["t1", "t3"], "the server's order")
    }

    /// A flat row has to say which project it belongs to, because no heading says it for the row.
    @Test("a row carries its repository's name")
    func rowNamesItsRepository() async {
        let (store, source) = await store()
        await source.setTasks([task("t1", "Fix the parser", repository: "r2")])
        await store.refresh()

        #expect(store.rows.first?.repositoryName == "kandev")
    }

    @Test("a list with nothing to group by is a list, not a section with a heading")
    func ungroupedStaysFlat() async {
        let (store, source) = await store()
        await source.setTasks([task("t1", "One"), task("t2", "Two")])

        await store.refresh()

        #expect(store.sections(.byRepository).count == 1)
        #expect(store.sections(.byRepository)[0].title == nil, "a heading over the only section says nothing")
        #expect(store.sections(.byRepository)[0].rows.map(\.id) == ["t1", "t2"])
    }

    @Test("tasks with no repository are kept, and named when something else is there")
    func unassignedTasksAreKept() async {
        let (store, source) = await store()
        await source.setTasks([
            task("t1", "Belongs to one", repository: "r1"),
            task("t2", "Belongs to none"),
        ])

        await store.refresh()

        #expect(store.sections(.byRepository).map(\.id) == ["r1", "none"])
        #expect(store.sections(.byRepository).last?.title == "No project")
        #expect(store.sections(.byRepository).last?.rows.map(\.id) == ["t2"])
    }

    @Test("a subtask stays under its parent, inside its own section")
    func subtasksStayUnderParents() async {
        let (store, source) = await store()
        await source.setTasks([
            task("t1", "Parent", repository: "r1"),
            task("t2", "Child", repository: "r1", parent: "t1"),
            task("t3", "Other project", repository: "r2"),
        ])

        await store.refresh()

        let pocket = store.sections(.byRepository).first { $0.id == "r1" }
        #expect(pocket?.rows.map(\.id) == ["t1", "t2"])
        #expect(pocket?.rows.map(\.depth) == [0, 1])
    }

    @Test("a repository with no name is headed by where it is")
    func headingsFallBack() async {
        let (store, source) = await store()
        await source.setRepositories([KandevRepository(id: "r1", sourceType: "local", localPath: "/dev/x")])
        await source.setTasks([task("t1", "One", repository: "r1")])

        await store.refresh()

        #expect(store.sections(.byRepository).first?.title == "/dev/x")
    }
}

@MainActor
@Suite("TaskListStore search")
struct TaskListSearchTests {
    /// Titles, parents, projects and chats are the whole of what a search can see, so each
    /// test states the ones it depends on.
    private func loaded(
        tasks: [KandevTask],
        total: Int? = nil,
        pageSize: Int = 50
    ) async -> (TaskListStore, FakeTaskSource) {
        let source = FakeTaskSource()
        await source.setWorkspaces([workspace])
        await source.setWorkflows([KandevWorkflow(id: "wf1", name: "Development")])
        await source.setSteps(
            [KandevWorkflowStep(id: "step-work", name: "In Progress", position: 1)],
            forWorkflow: "wf1"
        )
        await source.setRepositories([
            KandevRepository(id: "r1", name: "pocket-sand", sourceType: "local"),
            KandevRepository(id: "r2", name: "kandev", sourceType: "github"),
        ])
        await source.setTasks(tasks, total: total)
        let store = TaskListStore(source: source, pageSize: pageSize)
        await store.refresh()
        return (store, source)
    }

    private func ids(_ store: TaskListStore, _ listing: TaskListStore.Listing = .flat) -> [String] {
        store.sections(listing).flatMap(\.rows).map(\.id)
    }

    @Test("matches the title case- and diacritic-insensitively")
    func matchesTitles() async {
        let (store, _) = await loaded(tasks: [
            makeTask(id: "t1", title: "Fix the Café login", stepID: "step-work"),
            makeTask(id: "t2", title: "Rename the parser", stepID: "step-work"),
        ])

        store.searchText = "cafe"
        #expect(ids(store) == ["t1"])

        store.searchText = "CAFÉ"
        #expect(ids(store) == ["t1"])

        store.searchText = "  parse  "
        #expect(ids(store) == ["t2"], "surrounding spaces are not part of the search")
    }

    /// An empty search is the list as it was before search existed, and so is one that is only
    /// spaces, which is what a cleared field can leave behind.
    @Test("an empty search returns exactly what it did before")
    func emptySearchChangesNothing() async {
        let (store, _) = await loaded(tasks: [
            makeTask(id: "t1", title: "One", stepID: "step-work", ephemeral: true),
            makeTask(id: "t2", title: "Two", stepID: "step-work", repositoryID: "r1"),
            makeTask(id: "t3", title: "Three", stepID: "step-work", repositoryID: "r2"),
        ])
        let before = store.sections(.byRepository)

        store.searchText = "   "
        #expect(store.sections(.byRepository) == before)
        #expect(store.searchMatchesNothing == false)

        store.searchText = ""
        #expect(store.sections(.byRepository) == before)
    }

    @Test("a search that matches nothing says so, and an empty workspace is not that")
    func reportsNoMatch() async {
        let (store, _) = await loaded(tasks: [makeTask(id: "t1", title: "One", stepID: "step-work")])

        store.searchText = "zzz"
        #expect(store.searchMatchesNothing)
        #expect(store.sections(.flat).isEmpty)

        let (empty, _) = await loaded(tasks: [])
        empty.searchText = "zzz"
        #expect(empty.searchMatchesNothing == false, "no tasks at all is the empty list, not a search")
    }

    @Test("drops a project's section when the search leaves it empty")
    func dropsEmptySections() async {
        let (store, _) = await loaded(tasks: [
            makeTask(id: "t1", title: "Fix the login", stepID: "step-work", repositoryID: "r1"),
            makeTask(id: "t2", title: "Parser cleanup", stepID: "step-work", repositoryID: "r2"),
        ])
        #expect(store.sections(.byRepository).map(\.title) == ["pocket-sand", "kandev"])

        store.searchText = "login"

        #expect(store.sections(.byRepository).map(\.title) == ["pocket-sand"])
        #expect(store.sections(.byRepository).flatMap(\.rows).map(\.id) == ["t1"])
    }

    /// A subtask is a row like any other, so a match on it shows. Its parent is not drawn
    /// above it, so it is drawn as a task rather than indented under nothing.
    @Test("a matching subtask shows without its parent, drawn as a task")
    func subtaskWithoutParent() async {
        let (store, _) = await loaded(tasks: [
            makeTask(id: "p1", title: "Refactor the store", stepID: "step-work"),
            makeTask(id: "c1", title: "Retry the upload", stepID: "step-work", parentID: "p1"),
        ])
        #expect(store.rows.first { $0.id == "c1" }?.depth == 1)

        store.searchText = "retry"

        let rows = store.sections(.flat).flatMap(\.rows)
        #expect(rows.map(\.id) == ["c1"])
        #expect(rows.first?.depth == 0)
    }

    @Test("a matching parent keeps its matching subtask indented under it")
    func matchingParentKeepsChildren() async {
        let (store, _) = await loaded(tasks: [
            makeTask(id: "p1", title: "Upload the photos", stepID: "step-work"),
            makeTask(id: "c1", title: "Retry the upload", stepID: "step-work", parentID: "p1"),
            makeTask(id: "c2", title: "Name the album", stepID: "step-work", parentID: "p1"),
        ])

        store.searchText = "upload"

        let rows = store.sections(.flat).flatMap(\.rows)
        #expect(rows.map(\.id) == ["p1", "c1"], "a subtask that does not match is not shown")
        #expect(rows.last?.depth == 1, "a subtask whose parent matches stays under it")
    }

    /// Chats are tasks too, so they are searched like the work — and a search with no chats in
    /// it does not leave an empty shelf.
    @Test("chats are searched like the work")
    func chatsAreFiltered() async {
        let (store, _) = await loaded(tasks: [
            makeTask(id: "chat", title: "Quick question about login", stepID: nil, ephemeral: true),
            makeTask(id: "t1", title: "Login page", stepID: "step-work"),
        ])

        store.searchText = "login"
        #expect(store.sections(.flat).map(\.id) == ["chats", "all"])

        store.searchText = "page"
        #expect(store.sections(.flat).map(\.id) == ["all"])
        #expect(ids(store) == ["t1"])
    }

    /// A filter over the pages already held would miss a match on a page nobody has loaded.
    /// Searching reads the rest of the workspace instead.
    @Test("a search reads the older pages until it has them all")
    func searchReadsOlderPages() async {
        let (store, source) = await loaded(
            tasks: [makeTask(id: "t1", title: "One", stepID: "step-work")],
            total: 3,
            pageSize: 1
        )
        await source.setTasks([makeTask(id: "t2", title: "Two", stepID: "step-work")], total: 3, page: 2)
        await source.setTasks([makeTask(id: "t3", title: "Target on the last page", stepID: "step-work")], total: 3, page: 3)
        #expect(store.hasMore)

        store.searchText = "target"

        let read = await waitUntil { store.hasMore == false }
        #expect(read, "every page should have been read")
        #expect(ids(store) == ["t3"])
        let pages = await source.requestedPages
        #expect(pages == [1, 2, 3])
    }

    /// A failed page ends the search and keeps what is held. Without the stop, the loop would
    /// retry the same page for as long as the search was typed.
    @Test("a failed page stops the search and keeps the rows on screen")
    func failureStopsSearch() async {
        let (store, source) = await loaded(
            tasks: [makeTask(id: "t1", title: "One", stepID: "step-work")],
            total: 3,
            pageSize: 1
        )
        await source.setTasks([makeTask(id: "t2", title: "Two", stepID: "step-work")], total: 3, page: 2)
        await source.failNextTasksCall()

        store.searchText = "two"

        let failed = await waitUntil {
            if case .failed = store.phase { return true }
            return false
        }
        #expect(failed)
        #expect(store.rows.map(\.id) == ["t1"])
        #expect(store.hasMore)
        let pages = await source.requestedPages
        #expect(pages == [1, 2], "the failed page is not asked for again by the search")
    }
}
