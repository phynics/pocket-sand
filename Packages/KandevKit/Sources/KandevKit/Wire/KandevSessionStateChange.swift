import Foundation

/// A session's own state changing.
///
/// Verified against a live v0.96.0 server, captured while an agent worked:
///
///     {"session_id": "...", "task_id": "...",
///      "old_state": "WAITING_FOR_INPUT", "new_state": "RUNNING",
///      "foreground_activity": "generating", "is_primary": true,
///      "updated_at": "2026-10-04T21:38:05.39547914Z"}
///
/// Worth carrying separately from `KandevTaskUpdate` because it is the direct
/// signal: a row's "is it working" reads the session, and until now that came
/// second-hand by way of the task's status summary.
///
/// The frame names the task but not the workspace, so a subscriber matches on the
/// task it already holds rather than filtering by workspace.
public struct KandevSessionStateChange: Sendable, Decodable, Equatable {
    public var sessionID: String
    public var taskID: String?
    public var oldState: String?
    public var newState: String?
    /// What the agent is doing right now, such as `generating`.
    public var foregroundActivity: String?
    /// Whether this is the session its task treats as its default target. A row
    /// shows the primary session, so a change to a secondary one does not move
    /// the row's spinner.
    public var isPrimary: Bool?
    public var updatedAt: KandevTimestamp?

    public enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case taskID = "task_id"
        case oldState = "old_state"
        case newState = "new_state"
        case foregroundActivity = "foreground_activity"
        case isPrimary = "is_primary"
        case updatedAt = "updated_at"
    }

    public init(
        sessionID: String,
        taskID: String? = nil,
        oldState: String? = nil,
        newState: String? = nil,
        foregroundActivity: String? = nil,
        isPrimary: Bool? = nil,
        updatedAt: KandevTimestamp? = nil
    ) {
        self.sessionID = sessionID
        self.taskID = taskID
        self.oldState = oldState
        self.newState = newState
        self.foregroundActivity = foregroundActivity
        self.isPrimary = isPrimary
        self.updatedAt = updatedAt
    }

    /// Whether a turn is in flight, by the same rule the task model uses.
    public var isWorking: Bool {
        newState == "RUNNING" || foregroundActivity == "generating"
    }
}
