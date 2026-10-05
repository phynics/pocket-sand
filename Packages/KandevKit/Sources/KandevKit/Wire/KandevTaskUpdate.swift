import Foundation

/// A change to a task, as delivered by the notification stream.
///
/// Three frames feed this, and one type reads all of them because every field
/// except the id is optional and unknown keys are ignored:
///
/// | Frame | What it carries |
/// | --- | --- |
/// | `task.updated` | the whole task, the same shape the HTTP list returns |
/// | `task.state_changed` | the whole task, plus `old_state` and `new_state` |
/// | `task.status_summary.updated` | only `task_id`, `workspace_id`, `status_summary` |
///
/// Verified against a live v0.96.0 server during a real agent turn, where the
/// summary frame arrived thirteen times and the full one five.
///
/// Note the identity key is `task_id`, not `id` — the notifications and the HTTP
/// list spell the same object differently, which is why this is its own type
/// rather than a reuse of `KandevTask`.
public struct KandevTaskUpdate: Sendable, Decodable, Equatable {
    public var taskID: String
    public var workspaceID: String?
    public var title: String?
    public var state: String?
    public var workflowID: String?
    public var workflowStepID: String?
    public var primarySessionID: String?
    public var primarySessionState: String?
    public var primaryAgentName: String?
    public var foregroundActivity: String?
    public var sessionCount: Int?
    public var priority: String?
    public var updatedAt: KandevTimestamp?
    public var statusSummary: KandevStatusSummary?

    public enum CodingKeys: String, CodingKey {
        case title, state, priority
        case foregroundActivity = "foreground_activity"
        case taskID = "task_id"
        case workspaceID = "workspace_id"
        case workflowID = "workflow_id"
        case workflowStepID = "workflow_step_id"
        case primarySessionID = "primary_session_id"
        case primarySessionState = "primary_session_state"
        case primaryAgentName = "primary_agent_name"
        case sessionCount = "session_count"
        case updatedAt = "updated_at"
        case statusSummary = "status_summary"
    }

    public init(
        taskID: String,
        workspaceID: String? = nil,
        title: String? = nil,
        state: String? = nil,
        primarySessionState: String? = nil,
        statusSummary: KandevStatusSummary? = nil
    ) {
        self.taskID = taskID
        self.workspaceID = workspaceID
        self.title = title
        self.state = state
        self.primarySessionState = primarySessionState
        self.statusSummary = statusSummary
    }

    /// The task's state after the change, if the frame said.
    public var newState: String? { state }

    /// Applies what the frame carried, leaving everything it did not mention.
    ///
    /// An update is a patch, not a replacement: the summary frame says nothing
    /// about a task's title, and a row that lost its title because a spinner
    /// changed would be a worse bug than a stale spinner.
    public func applied(to task: KandevTask) -> KandevTask {
        var updated = task
        if let title { updated.title = title }
        if let state { updated.state = state }
        if let workflowID { updated.workflowID = workflowID }
        if let workflowStepID { updated.workflowStepID = workflowStepID }
        if let primarySessionID { updated.primarySessionID = primarySessionID }
        if let primarySessionState { updated.primarySessionState = primarySessionState }
        if let primaryAgentName { updated.primaryAgentName = primaryAgentName }
        if let foregroundActivity { updated.foregroundActivity = foregroundActivity }
        if let sessionCount { updated.sessionCount = sessionCount }
        if let priority { updated.priority = priority }
        if let updatedAt { updated.updatedAt = updatedAt }
        if let statusSummary { updated.statusSummary = statusSummary }
        return updated
    }
}
