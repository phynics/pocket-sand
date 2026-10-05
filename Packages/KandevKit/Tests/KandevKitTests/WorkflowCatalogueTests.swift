import Foundation
import Testing

@testable import KandevKit

/// The workspace's workflows and steps, read once however many screens ask.
///
/// The point of the module is that two screens share one read, so the tests count
/// what the source was asked for rather than only what came back.
@MainActor
@Suite("WorkflowCatalogue")
struct WorkflowCatalogueTests {
    private func source() async -> FakeTaskSource {
        let source = FakeTaskSource()
        await source.setWorkspaces([workspace])
        await source.setWorkflows([
            KandevWorkflow(id: "wf1", name: "Development"),
            KandevWorkflow(id: "wf2", name: "Plan & Build"),
        ])
        await source.setSteps(
            [
                KandevWorkflowStep(id: "s-review", name: "Review", position: 2),
                KandevWorkflowStep(id: "s-work", name: "In Progress", position: 1),
            ],
            forWorkflow: "wf1"
        )
        await source.setSteps(
            [KandevWorkflowStep(id: "s-plan", name: "Plan", position: 0)],
            forWorkflow: "wf2"
        )
        return source
    }

    @Test("reads a workflow's steps in the order the workflow puts them")
    func ordersSteps() async throws {
        let catalogue = WorkflowCatalogue(source: await source())

        try await catalogue.load(workspaceID: "w1")

        #expect(catalogue.workflows.map(\.id) == ["wf1", "wf2"])
        #expect(catalogue.steps(for: "wf1").map(\.id) == ["s-work", "s-review"])
        #expect(catalogue.steps(for: "wf2").map(\.id) == ["s-plan"])
        #expect(catalogue.step(id: "s-review")?.name == "Review")
        #expect(catalogue.stepNames["s-work"] == "In Progress")
        #expect(catalogue.steps(for: nil).isEmpty, "a task with no workflow has no destinations")
    }

    @Test("reads each workflow's steps once, however many times it is loaded")
    func readsOnce() async throws {
        let source = await source()
        let catalogue = WorkflowCatalogue(source: source)

        try await catalogue.load(workspaceID: "w1")
        try await catalogue.load(workspaceID: "w1")
        try await catalogue.load(workspaceID: "w1")

        #expect(await source.stepRequests == ["wf1", "wf2"])
    }

    /// The reason to share one: the list reads the workspace's steps, and the form
    /// that opens next does not read them again.
    @Test("a catalogue shared by two screens reads the workspace once")
    func sharingReadsOnce() async {
        let source = await source()
        let catalogue = WorkflowCatalogue(source: source)
        let list = TaskListStore(source: source, catalogue: catalogue)
        let form = NewTaskStore(
            taskSource: source,
            creator: StubTaskCreator(),
            catalogue: catalogue,
            workspaceID: "w1"
        )

        await list.refresh()
        await form.loadOptions()

        #expect(await source.stepRequests == ["wf1", "wf2"])
        #expect(form.workflows.map(\.id) == ["wf1", "wf2"])
        #expect(form.orderedSteps.map(\.id) == ["s-work", "s-review"])
    }

    @Test("changing the workspace replaces the steps it holds")
    func changingWorkspaceReloads() async throws {
        let source = await source()
        let catalogue = WorkflowCatalogue(source: source)
        try await catalogue.load(workspaceID: "w1")
        #expect(catalogue.steps(for: "wf1").count == 2)

        await source.setWorkflows([KandevWorkflow(id: "wf3", name: "Other")])
        await source.setSteps(
            [KandevWorkflowStep(id: "s-other", name: "Other", position: 0)],
            forWorkflow: "wf3"
        )
        try await catalogue.load(workspaceID: "w2")

        #expect(catalogue.workflows.map(\.id) == ["wf3"])
        #expect(catalogue.steps(for: "wf1").isEmpty, "the old workspace's steps must go")
        #expect(catalogue.step(id: "s-other")?.name == "Other")
    }
}
