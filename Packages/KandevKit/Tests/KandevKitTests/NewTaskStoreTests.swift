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
        #expect(store.canFile == false, "nothing is chosen yet")

        await store.loadOptions()
        #expect(store.canFile == false, "a workflow alone is not a task")

        store.brief = "   "
        #expect(store.canFile == false, "whitespace is not a title")

        store.brief = "Implement the thing"
        #expect(store.canFile)
        #expect(store.title == "Implement the thing", "the name comes from the sentence")
    }

    /// Filing is one decision, so choosing a workflow and a step together is one
    /// call — and a step from the old workflow cannot survive it.
    @Test("filing picks a workflow and a step together")
    func filingPicksBoth() async {
        let (store, _, _, _) = await store()
        await store.loadOptions()
        store.stepID = "s-work"

        store.file(workflowID: "wf2", stepID: "s-plan")
        #expect(store.stepID == "s-plan")
        #expect(store.orderedSteps.map(\.id) == ["s-plan"])

        store.file(workflowID: "wf1", stepID: nil)
        #expect(store.stepID == nil, "no step means the workflow's own start step")
        #expect(store.orderedSteps.map(\.id) == ["s-backlog", "s-work"])
    }

    @Test("creates with the choices made, and reports the task the server made")
    func creates() async {
        let (store, _, creator, _) = await store()
        await store.loadOptions()
        store.brief = "  Do exactly this.  "
        store.stepID = "s-work"
        store.agentProfileID = "p1"

        let task = await store.create()

        #expect(task?.id == "new-1")
        #expect(store.createdTask?.id == "new-1")
        let draft = await creator.lastDraft()
        #expect(draft?.title == "Do exactly this.", "named from the sentence, and trimmed")
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
        store.brief = "Do exactly this."
        await creator.failNext(
            with: KandevError.action(
                KandevActionFailure(code: "validation_error", message: "workflow_id is required")
            )
        )

        let task = await store.create()

        #expect(task == nil)
        #expect(store.createdTask == nil)
        #expect(store.title == "Do exactly this.", "losing typed text on a failure is the worst outcome here")
        #expect(store.brief == "Do exactly this.")
        #expect(store.phase == .failed("workflow_id is required"))
    }

    @Test("a failed options load is reported without losing the form")
    func failedOptionsAreReported() async {
        let creator = StubTaskCreator()
        let source = FakeTaskSource()
        await source.setWorkspaces([])
        let store = NewTaskStore(taskSource: source, creator: creator)
        store.brief = "Typed before loading finished"

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

/// A chat starter with no server behind it.
actor StubChatStarter: KandevChatStarting {
    struct Request: Sendable, Equatable {
        var kind: KandevChatKind
        var workspaceID: String
        var agentProfileID: String
        var title: String?
    }

    private(set) var requests: [Request] = []
    var result: Result<KandevChat, any Error> = .success(
        KandevChat(taskID: "chat-task", sessionID: "chat-session", agentProfileID: "p1")
    )
    var failure: (any Error)?

    func failNext(with error: any Error) { failure = error }

    func startChat(
        kind: KandevChatKind,
        workspaceID: String,
        agentProfileID: String,
        title: String?
    ) async throws -> KandevChat {
        requests.append(
            Request(
                kind: kind,
                workspaceID: workspaceID,
                agentProfileID: agentProfileID,
                title: title
            )
        )
        if let failure {
            self.failure = nil
            throw failure
        }
        return try result.get()
    }

    func lastRequest() -> Request? { requests.last }
}

@MainActor
@Suite("NewTaskStore, the three doors")
struct NewTaskDoorTests {
    /// A store with a chat starter attached, in the state a real screen starts in:
    /// options loaded, one workflow, one agent.
    private func store() async -> (NewTaskStore, StubChatStarter) {
        let source = FakeTaskSource()
        await source.setWorkspaces([
            KandevWorkspace(id: "w1", name: "Default Workspace", scopes: []),
        ])
        await source.setWorkflows([
            KandevWorkflow(id: "wf1", name: "Development", sortOrder: 0),
        ])
        await source.setSteps(
            [KandevWorkflowStep(id: "s-backlog", name: "Backlog", position: 0)],
            forWorkflow: "wf1"
        )
        let profiles = StubSessionStarter()
        await profiles.setProfiles([
            KandevAgentProfile(id: "p1", name: "worker", model: "deepseek", enabled: true),
        ])
        let chats = StubChatStarter()
        let store = NewTaskStore(
            taskSource: source,
            creator: StubTaskCreator(),
            profileSource: profiles,
            chatStarter: chats,
            workspaceID: "w1"
        )
        await store.loadOptions()
        return (store, chats)
    }

    @Test("the name is the first few words, not the whole sentence")
    func titleIsTheFirstFewWords() async {
        let (store, _) = await store()

        store.brief = "Fix the flaky test"
        #expect(store.title == "Fix the flaky test", "short enough to keep whole")

        store.brief = "Fix the flaky test in the auth suite before the release"
        #expect(store.title == "Fix the flaky test in the…", "and cut at a word")

        store.brief = "Fix the flaky test in the auth suite\nAnd add a regression test"
        #expect(store.title == "Fix the flaky test in the…", "only the first line")
    }

    @Test("and follows the sentence rather than being a second thing to fill in")
    func titleFollowsTheSentence() async {
        let (store, _) = await store()

        store.brief = "Fix the flaky test"
        #expect(store.title == "Fix the flaky test")

        store.brief = "Something else entirely"
        #expect(store.title == "Something else entirely", "there is one input, and this is it")

        store.brief = ""
        #expect(store.title.isEmpty)
    }

    @Test("a derived title drops markdown markers and cuts at a word")
    func derivedTitle() {
        #expect(NewTaskStore.derivedTitle(from: "## Fix the flaky test") == "Fix the flaky test")
        #expect(NewTaskStore.derivedTitle(from: "- Fix the flaky test") == "Fix the flaky test")
        #expect(NewTaskStore.derivedTitle(from: "\n\n  Fix it  \n") == "Fix it")
        #expect(NewTaskStore.derivedTitle(from: "") == "")

        let long = NewTaskStore.derivedTitle(
            from: "Fix the flaky test in the auth suite before the release on Friday"
        )
        #expect(long == "Fix the flaky test in the…", "a title is a name, not a sentence")
        #expect(!long.contains("  "), "and cut at a word rather than mid-word")
    }

    @Test("a chat needs an agent and a sentence, and no workflow at all")
    func askingNeedsNoWorkflow() async {
        let (store, _) = await store()
        #expect(store.canAsk == false, "nothing has been said yet")

        store.brief = "What does the retry policy do?"
        #expect(store.canAsk, "a sentence and an agent are enough")

        store.workflowID = nil
        #expect(store.canAsk, "and a chat is not filed, so it needs no workflow")
        #expect(store.canFile == false, "while filing one still does")
    }

    @Test("the agent is chosen for you rather than asked about")
    func agentIsPreselected() async {
        let (store, _) = await store()
        #expect(store.agentProfileID == "p1")
    }

    @Test("asking starts the kind of chat that was asked for")
    func startsTheRightChat() async {
        let (store, chats) = await store()
        store.brief = "What does the retry policy do?"

        let chat = await store.startChat(kind: .quick)

        #expect(chat?.taskID == "chat-task")
        #expect(store.startedChat?.sessionID == "chat-session")
        let request = await chats.lastRequest()
        #expect(request?.kind == .quick)
        #expect(request?.workspaceID == "w1")
        #expect(request?.agentProfileID == "p1")
    }

    @Test("a chat is named after the sentence, and the setup chat after its job")
    func chatTitles() async {
        let (store, chats) = await store()
        store.brief = "## What does the retry policy do?\nMore detail"

        _ = await store.startChat(kind: .quick)
        var request = await chats.lastRequest()
        #expect(request?.title == "What does the retry policy do?")

        _ = await store.startChat(kind: .config)
        request = await chats.lastRequest()
        #expect(request?.title == "Change the setup")
    }

    @Test("a chat cannot be started with nothing to say")
    func noSentenceNoChat() async {
        let (store, chats) = await store()

        let chat = await store.startChat(kind: .quick)

        #expect(chat == nil)
        #expect(await chats.requests.isEmpty, "and the server is never asked")
        #expect(store.phase == .editing, "a refusal is not a failure")
    }

    @Test("a chat that fails says why, and can be tried again")
    func failedChat() async {
        let (store, chats) = await store()
        store.brief = "What does the retry policy do?"
        await chats.failNext(with: KandevError.malformedFrame("nope"))

        #expect(await store.startChat(kind: .quick) == nil)
        guard case .failed(let message) = store.phase else {
            Issue.record("expected a failure, got \(store.phase)")
            return
        }
        #expect(!message.isEmpty)
        #expect(store.canAsk, "the sentence is still there to try again with")
    }

    @Test("no agent profiles is a state the screen can offer help in")
    func noProfiles() async {
        let source = FakeTaskSource()
        await source.setWorkspaces([
            KandevWorkspace(id: "w1", name: "Default Workspace", scopes: []),
        ])
        let profiles = StubSessionStarter()
        await profiles.setProfiles([])
        let store = NewTaskStore(
            taskSource: source,
            creator: StubTaskCreator(),
            profileSource: profiles,
            chatStarter: StubChatStarter(),
            workspaceID: "w1"
        )

        await store.loadOptions()

        #expect(store.needsAgentProfile, "which is what the setup chat is for")
        store.brief = "Do something"
        #expect(store.canAsk == false, "and neither door can open")
    }
}

@MainActor
@Suite("NewTaskStore, repositories")
struct NewTaskRepositoryTests {
    @Test("reads the workspace's repositories, and sends the one that was chosen")
    func repositoryIsChosenAndSent() async {
        let source = FakeTaskSource()
        await source.setWorkspaces([
            KandevWorkspace(id: "w1", name: "Default Workspace", scopes: []),
        ])
        await source.setWorkflows([KandevWorkflow(id: "wf1", name: "Development", sortOrder: 0)])
        await source.setSteps(
            [KandevWorkflowStep(id: "s-backlog", name: "Backlog", position: 0)],
            forWorkflow: "wf1"
        )
        await source.setRepositories([
            KandevRepository(id: "r1", name: "pocket-sand", sourceType: "local", localPath: "/dev/pocket-sand"),
            KandevRepository(id: "r2", name: "kandev", sourceType: "github", provider: "github"),
        ])
        let creator = StubTaskCreator()
        let store = NewTaskStore(taskSource: source, creator: creator, workspaceID: "w1")

        await store.loadOptions()
        #expect(store.repositories.map(\.id) == ["r1", "r2"])

        store.brief = "Fix the flaky test"
        #expect(store.repositoryID == nil, "the workspace's own is the default")

        store.repositoryID = "r2"
        await store.create()

        let draft = await creator.lastDraft()
        #expect(draft?.repositoryIDs == ["r2"])
    }

    @Test("a repository with no name is described by where it is")
    func originNamesARepository() {
        let local = KandevRepository(id: "r1", sourceType: "local", localPath: "/dev/thing")
        #expect(local.origin == "/dev/thing")

        let hosted = KandevRepository(id: "r2", sourceType: "github", provider: "github")
        #expect(hosted.origin == "github")

        let bare = KandevRepository(id: "r3")
        #expect(bare.origin == "unknown")
    }
}
