import Foundation
import Testing

@testable import KandevKit

/// A task creator with no server behind it.
actor StubTaskCreator: KandevTaskCreating {
    private(set) var drafts: [KandevTaskDraft] = []
    var result: Result<KandevTask, any Error> = .success(KandevTask(id: "new-1", title: "created"))
    var failure: (any Error)?

    func failNext(with error: any Error) { failure = error }

    func createTask(_ draft: KandevTaskDraft) async throws -> KandevTask {
        drafts.append(draft)
        if let failure {
            self.failure = nil
            throw failure
        }
        return try result.get()
    }

    func lastDraft() -> KandevTaskDraft? { drafts.last }
}

@MainActor
@Suite("NewTaskStore")
struct NewTaskStoreTests {
    private func store() async -> (NewTaskStore, FakeTaskSource, StubTaskCreator, StubSessionStarter) {
        let source = FakeTaskSource()
        await source.setWorkspaces([
            KandevWorkspace(id: "w1", name: "Default Workspace", scopes: []),
        ])
        await source.setWorkflows([
            KandevWorkflow(id: "wf1", name: "Development", sortOrder: 0),
            KandevWorkflow(id: "wf2", name: "Plan & Build", sortOrder: 1),
        ])
        await source.setSteps(
            [
                KandevWorkflowStep(id: "s-backlog", name: "Backlog", position: 0),
                KandevWorkflowStep(id: "s-work", name: "In Progress", position: 1),
            ],
            forWorkflow: "wf1"
        )
        await source.setSteps(
            [KandevWorkflowStep(id: "s-plan", name: "Plan", position: 0)],
            forWorkflow: "wf2"
        )

        let creator = StubTaskCreator()
        let profiles = StubSessionStarter()
        await profiles.setProfiles([
            KandevAgentProfile(id: "p1", name: "worker", model: "deepseek", enabled: true),
        ])
        let store = NewTaskStore(
            taskSource: source,
            creator: creator,
            profileSource: profiles,
            workspaceID: "w1"
        )
        return (store, source, creator, profiles)
    }

    @Test("loads the workspace's workflows, their steps, and the agents")
    func loadsOptions() async {
        let (store, _, _, _) = await store()

        await store.loadOptions()

        #expect(store.workspaces.map(\.id) == ["w1"])
        #expect(store.workflows.map(\.id) == ["wf1", "wf2"])
        #expect(store.workflowID == "wf1", "a workflow should be preselected")
        #expect(store.orderedSteps.map(\.id) == ["s-backlog", "s-work"])
        #expect(store.agentProfiles.map(\.id) == ["p1"])
    }

    @Test("requires a workflow and a title, and nothing else")
    func validation() async {
        let (store, _, _, _) = await store()
        #expect(store.canCreate == false, "nothing is chosen yet")

        await store.loadOptions()
        #expect(store.canCreate == false, "a workflow alone is not a task")

        store.title = "   "
        #expect(store.canCreate == false, "whitespace is not a title")

        store.title = "Implement the thing"
        #expect(store.canCreate)
        #expect(store.brief.isEmpty, "a brief is optional")
    }

    /// Changing the workflow changes which steps exist, so a step from the old
    /// workflow must not survive the change.
    @Test("changing the workflow reloads its steps and forgets the old choice")
    func changingWorkflowReloadsSteps() async {
        let (store, _, _, _) = await store()
        await store.loadOptions()
        store.stepID = "s-work"

        store.selectWorkflow("wf2")

        #expect(store.stepID == nil, "the old step belonged to another workflow")
        #expect(store.orderedSteps.map(\.id) == ["s-plan"])
    }

    @Test("creates with the choices made, and reports the task the server made")
    func creates() async {
        let (store, _, creator, _) = await store()
        await store.loadOptions()
        store.title = "  Implement the thing  "
        store.brief = "  Do exactly this.  "
        store.stepID = "s-work"
        store.agentProfileID = "p1"

        let task = await store.create()

        #expect(task?.id == "new-1")
        #expect(store.createdTask?.id == "new-1")
        let draft = await creator.lastDraft()
        #expect(draft?.title == "Implement the thing", "the title should be trimmed")
        #expect(draft?.brief == "Do exactly this.")
        #expect(draft?.workspaceID == "w1")
        #expect(draft?.workflowID == "wf1")
        #expect(draft?.stepID == "s-work")
        #expect(draft?.agentProfileID == "p1")
    }

    @Test("will not create without a title, and leaves the phase alone")
    func refusesIncompleteDrafts() async {
        let (store, _, creator, _) = await store()
        await store.loadOptions()

        let task = await store.create()

        #expect(task == nil)
        let drafts = await creator.drafts
        #expect(drafts.isEmpty)
        #expect(store.phase == .editing)
    }

    @Test("a refused creation is reported and the form keeps what was typed")
    func refusedCreationIsReported() async {
        let (store, _, creator, _) = await store()
        await store.loadOptions()
        store.title = "Implement the thing"
        store.brief = "Do exactly this."
        await creator.failNext(
            with: KandevError.action(
                KandevActionFailure(code: "validation_error", message: "workflow_id is required")
            )
        )

        let task = await store.create()

        #expect(task == nil)
        #expect(store.createdTask == nil)
        #expect(store.title == "Implement the thing", "losing typed text on a failure is the worst outcome here")
        #expect(store.brief == "Do exactly this.")
        #expect(store.phase == .failed("workflow_id is required"))
    }

    @Test("a failed options load is reported without losing the form")
    func failedOptionsAreReported() async {
        let creator = StubTaskCreator()
        let source = FakeTaskSource()
        await source.setWorkspaces([])
        let store = NewTaskStore(taskSource: source, creator: creator)
        store.title = "Typed before loading finished"

        await store.loadOptions()

        if case .failed = store.phase {} else {
            Issue.record("expected a failed phase, got \(store.phase)")
        }
        #expect(store.title == "Typed before loading finished")
    }
}

@Suite("KandevTaskDraft")
struct KandevTaskDraftTests {
    /// Read off a live server: `workspace_id` and `workflow_id` are the only
    /// requirements, and `description` is what becomes the first prompt.
    @Test("sends the two required keys and only the optional ones it has")
    func payloadShape() {
        let minimal = KandevTaskDraft(workspaceID: "w1", workflowID: "wf1", title: "T")
        #expect(minimal.payload["workspace_id"] == .string("w1"))
        #expect(minimal.payload["workflow_id"] == .string("wf1"))
        #expect(minimal.payload["title"] == .string("T"))
        #expect(minimal.payload["workflow_step_id"] == nil)
        #expect(minimal.payload["description"] == nil)
        #expect(minimal.payload["agent_profile_id"] == nil)
    }

    @Test("includes the brief, the step, and the agent when they are given")
    func payloadWithOptionals() {
        let full = KandevTaskDraft(
            workspaceID: "w1",
            workflowID: "wf1",
            stepID: "s1",
            title: "T",
            brief: "Do it",
            agentProfileID: "p1"
        )

        #expect(full.payload["workflow_step_id"] == .string("s1"))
        #expect(full.payload["description"] == .string("Do it"))
        #expect(full.payload["agent_profile_id"] == .string("p1"))
    }

    /// An empty brief would be sent as an empty first prompt, which is worse than
    /// no prompt at all.
    @Test("omits an empty brief rather than sending an empty first prompt")
    func omitsEmptyBrief() {
        let draft = KandevTaskDraft(workspaceID: "w1", workflowID: "wf1", title: "T", brief: "")

        #expect(draft.payload["description"] == nil)
    }
}
