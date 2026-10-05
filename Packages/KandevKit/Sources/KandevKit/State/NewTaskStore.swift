import Foundation
import Observation

/// The form for creating a task.
///
/// Owns the choices as well as the text: a task needs a workflow, and the brief
/// is not a description but the session's first prompt, so both have to be
/// nothing-specific before this can offer to submit.
@MainActor
@Observable
public final class NewTaskStore {
    public enum Phase: Equatable {
        case editing
        case creating
        case failed(String)
    }

    public var title = ""
    public var brief = ""
    public var workspaceID: String?
    public var workflowID: String?
    public var stepID: String?
    public var agentProfileID: String?

    public private(set) var phase: Phase = .editing
    public private(set) var workspaces: [KandevWorkspace] = []
    public private(set) var agentProfiles: [KandevAgentProfile] = []
    public private(set) var isLoadingOptions = false
    /// The task the server created, once it has.
    public private(set) var createdTask: KandevTask?

    private let taskSource: any KandevTaskSource
    private let creator: any KandevTaskCreating
    private let profileSource: (any KandevSessionStarting)?
    /// The workspace's workflows and steps, shared with the list that has already
    /// read them. A store created without one owns its own.
    private let catalogue: WorkflowCatalogue

    public init(
        taskSource: any KandevTaskSource,
        creator: any KandevTaskCreating,
        profileSource: (any KandevSessionStarting)? = nil,
        catalogue: WorkflowCatalogue? = nil,
        workspaceID: String? = nil,
        workflowID: String? = nil
    ) {
        self.taskSource = taskSource
        self.creator = creator
        self.profileSource = profileSource
        self.catalogue = catalogue ?? WorkflowCatalogue(source: taskSource)
        self.workspaceID = workspaceID
        self.workflowID = workflowID
    }

    /// The workspace's workflows, for the picker.
    public var workflows: [KandevWorkflow] { catalogue.workflows }

    /// A title is required, and a brief is not. An empty brief would make an
    /// empty first prompt, which is worse than no prompt at all.
    public var canCreate: Bool {
        guard phase != .creating, workflowID != nil else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Steps in the order the workflow puts them, for a picker that reads like
    /// the board does.
    public var orderedSteps: [KandevWorkflowStep] {
        catalogue.steps(for: workflowID)
    }

    public func loadOptions() async {
        guard !isLoadingOptions else { return }
        isLoadingOptions = true
        defer { isLoadingOptions = false }

        do {
            workspaces = try await taskSource.workspaces()
            // A server with no workspaces cannot be created in. Saying so is
            // better than a form whose pickers are silently empty.
            guard let workspace = workspaces.first(where: { $0.id == workspaceID }) ?? workspaces.first
            else {
                phase = .failed("This server has no workspaces to create tasks in.")
                return
            }
            workspaceID = workspace.id

            try await catalogue.load(workspaceID: workspace.id)
            if workflowID == nil { workflowID = preferredWorkflow()?.id }
            if let profileSource {
                agentProfiles = (try? await profileSource.agentProfiles()) ?? []
            }
        } catch {
            phase = .failed(KandevError.readableMessage(for: error))
        }
    }

    /// Changing the workflow changes which steps exist, so the step choice is
    /// forgotten rather than left pointing at a step from another workflow. The
    /// catalogue already holds every workflow's steps, so nothing is re-read.
    public func selectWorkflow(_ id: String) {
        guard id != workflowID else { return }
        workflowID = id
        stepID = nil
    }

    /// Creates the task, and returns it.
    ///
    /// The result is the task itself, so the caller can go to it. Refetching the
    /// list to find what was just created would be slower and could miss it.
    @discardableResult
    public func create() async -> KandevTask? {
        guard let workspaceID, let workflowID, canCreate else { return nil }
        phase = .creating
        defer { if phase == .creating { phase = .editing } }

        let draft = KandevTaskDraft(
            workspaceID: workspaceID,
            workflowID: workflowID,
            stepID: stepID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            brief: brief.trimmingCharacters(in: .whitespacesAndNewlines),
            agentProfileID: agentProfileID
        )
        do {
            let task = try await creator.createTask(draft)
            createdTask = task
            phase = .editing
            return task
        } catch {
            phase = .failed(KandevError.readableMessage(for: error))
            return nil
        }
    }

    /// The workflow to preselect.
    ///
    /// The first the workspace has. A workspace names a default workflow, but this
    /// client does not read that field yet, and the choice is right there to change.
    private func preferredWorkflow() -> KandevWorkflow? {
        workflows.first
    }
}
