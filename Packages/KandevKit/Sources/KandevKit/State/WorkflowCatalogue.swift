import Foundation
import Observation

/// A workspace's workflows and their steps, read once.
///
/// Two screens need the same two reads: the step names a task row shows, and the
/// steps a new task or a move chooses from. Each was fetching and caching them on
/// its own, so the fetch-once rule lived in two places. This is the one home for it,
/// and a workspace's steps are read once however many screens ask.
///
/// Steps are grouped by the workflow they were fetched for rather than by the
/// `workflow_id` a step carries. `workflow.step.list` is asked one workflow at a
/// time and its answer need not repeat the id it was asked about, so grouping by
/// the question is the only grouping that is always right.
@MainActor
@Observable
public final class WorkflowCatalogue {
    /// The workspace's workflows, empty until `load` has read them.
    public private(set) var workflows: [KandevWorkflow] = []
    /// Every known step by id, for a caller that holds only an id.
    public private(set) var stepsByID: [String: KandevWorkflowStep] = [:]

    private var stepsByWorkflowID: [String: [KandevWorkflowStep]] = [:]
    private var loadedWorkspaceID: String?
    private let source: any KandevTaskSource

    public init(source: any KandevTaskSource) {
        self.source = source
    }

    /// Reads the workspace's workflows, then every one of their steps.
    ///
    /// The workflows are re-read only when the workspace changes, and a workflow's
    /// steps only once. Callers may call this as often as they like.
    public func load(workspaceID: String) async throws {
        if loadedWorkspaceID != workspaceID {
            workflows = try await source.workflows(workspaceID: workspaceID)
            stepsByWorkflowID = [:]
            stepsByID = [:]
            loadedWorkspaceID = workspaceID
        }
        for workflow in workflows where stepsByWorkflowID[workflow.id] == nil {
            let steps = try await source.workflowSteps(workflowID: workflow.id)
            stepsByWorkflowID[workflow.id] = steps
            for step in steps { stepsByID[step.id] = step }
        }
    }

    /// One workflow's steps, in the order the workflow puts them.
    ///
    /// Empty for a workflow this catalogue has not read, which is what a task
    /// pointing at a workflow outside the loaded workspace gets. An empty menu is
    /// then the honest answer, rather than a step from somewhere else.
    public func steps(for workflowID: String?) -> [KandevWorkflowStep] {
        guard let workflowID else { return [] }
        return (stepsByWorkflowID[workflowID] ?? []).sorted { $0.position < $1.position }
    }

    /// The step with this id, if it has been read.
    public func step(id: String?) -> KandevWorkflowStep? {
        guard let id else { return nil }
        return stepsByID[id]
    }

    /// Step ids to names, for a caller that only needs a label.
    public var stepNames: [String: String] { stepsByID.mapValues(\.name) }
}
