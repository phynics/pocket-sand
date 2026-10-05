import Foundation

/// What is needed to create a task.
///
/// Verified against a live v0.96.0 server: `task.create` requires `workspace_id`
/// and `workflow_id` and nothing else, and the task lands at the workflow's start
/// step unless one is named.
///
/// `brief` is not a description in the ordinary sense — the server makes it the
/// session's first prompt verbatim. A one-character brief produced a
/// one-character first turn.
public struct KandevTaskDraft: Sendable, Equatable {
    public var workspaceID: String
    public var workflowID: String
    public var stepID: String?
    public var title: String
    public var brief: String?
    /// Stored on the task so a session started later uses it. It does **not**
    /// promise an agent starts now: whether one does is the workflow step's
    /// decision, and the server makes it.
    public var agentProfileID: String?

    public init(
        workspaceID: String,
        workflowID: String,
        stepID: String? = nil,
        title: String,
        brief: String? = nil,
        agentProfileID: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.workflowID = workflowID
        self.stepID = stepID
        self.title = title
        self.brief = brief
        self.agentProfileID = agentProfileID
    }

    var payload: JSONValue {
        var members: [String: JSONValue] = [
            "workspace_id": .string(workspaceID),
            "workflow_id": .string(workflowID),
            "title": .string(title),
        ]
        if let stepID { members["workflow_step_id"] = .string(stepID) }
        if let brief, !brief.isEmpty { members["description"] = .string(brief) }
        if let agentProfileID { members["agent_profile_id"] = .string(agentProfileID) }
        return .object(members)
    }
}

/// Creating a task.
public protocol KandevTaskCreating: Sendable {
    func createTask(_ draft: KandevTaskDraft) async throws -> KandevTask
}

extension KandevClient: KandevTaskCreating {}
