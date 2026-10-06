import Foundation

/// What a move would do, before committing to it.
///
/// From `POST /api/v1/tasks/{id}/move-preview`, read off the first-party client's
/// own types rather than probed live: the paths and field names below are that
/// client's, and the server is expected to agree.
///
/// The answer is worth asking for. A move is not just a position change — it can
/// hand the work to a different agent, reuse the session already running, or
/// start a new one, and the preview says which.
public struct KandevTaskMovePreview: Sendable, Decodable, Equatable {
    public var taskID: String?
    public var workflowStepID: String?
    /// The session the work is coming from.
    public var sourceSessionID: String?
    public var evaluatedAt: KandevTimestamp?
    /// Kept as a string so an outcome this client has not heard of is a value to
    /// render plainly, not a decode failure that loses the whole preview.
    public var outcome: String?
    public var recipient: Recipient?
    public var model: ModelChange?

    public enum CodingKeys: String, CodingKey {
        case outcome, recipient, model
        case taskID = "task_id"
        case workflowStepID = "workflow_step_id"
        case sourceSessionID = "source_session_id"
        case evaluatedAt = "evaluated_at"
    }

    /// Where the work will land.
    public struct Recipient: Sendable, Decodable, Equatable {
        public var sessionID: String?
        public var sessionName: String?
        public var profileID: String?
        public var profileName: String?
        public var agentFamily: String?

        public enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case sessionName = "session_name"
            case profileID = "profile_id"
            case profileName = "profile_name"
            case agentFamily = "agent_family"
        }
    }

    /// The model before and after. The values are objects whose shape this client
    /// does not model, because nothing yet reads more than their name.
    public struct ModelChange: Sendable, Decodable, Equatable {
        public var before: JSONValue?
        public var after: JSONValue?
    }

    /// What the move will do, in words.
    ///
    /// Returns `nil` when the server used an outcome this client does not know:
    /// better to say nothing than to describe a move wrongly.
    public var summary: String? {
        let who = recipient?.sessionName ?? recipient?.profileName ?? recipient?.agentFamily

        switch outcome {
        case "reuse_current":
            return who.map { "Continues in \($0)" } ?? "Continues in the current session"
        case "reuse_other":
            return who.map { "Continues in \($0)" } ?? "Continues in another session on this task"
        case "create_new":
            return who.map { "Starts a new session with \($0)" } ?? "Starts a new session"
        case "no_session":
            return "No session runs here yet"
        default:
            return nil
        }
    }

    /// Whether the move will leave the work in the hands of a running agent.
    public var startsOrContinuesWork: Bool {
        switch outcome {
        case "reuse_current", "reuse_other", "create_new": true
        default: false
        }
    }
}

/// Moving a task between workflow steps.
public protocol KandevTaskMoving: Sendable {
    /// What a move would do, for showing before it is committed.
    func previewMove(
        taskID: String,
        toWorkflowID: String,
        stepID: String
    ) async throws -> KandevTaskMovePreview

    /// Moves the task.
    func moveTask(taskID: String, toWorkflowID: String, stepID: String) async throws
}


/// Removing a task from the active board, or for good.
///
/// Both are HTTP, like moving: the first-party client posts to
/// `/api/v1/tasks/{id}/archive` and deletes `/api/v1/tasks/{id}`, rather than
/// using the `task.archive` and `task.delete` action names.
public protocol KandevTaskRemoving: Sendable {
    /// Takes the task off the active board. Reversible, and subtasks can come
    /// along or stay.
    func archiveTask(id: String, cascadeSubTasks: Bool) async throws

    /// Puts an archived task back on the board.
    ///
    /// Answers with the ids that came back, which can be more than one when
    /// subtasks were archived together. The answer is not read: what the board
    /// looks like afterwards is the server's to say, so the caller refetches.
    func unarchiveTask(id: String) async throws

    /// Asks what deleting this task would need, and gets the ticket the delete route requires.
    ///
    /// Every delete starts here. The answer says whether a worktree holds uncommitted work — the
    /// heavier question — and carries the confirmation id the delete must send back.
    func taskDeletePreflight(
        taskIDs: [String],
        cascadeSubTasks: Bool,
        discardWorktreeChanges: Bool
    ) async throws -> KandevTaskDeletePreflight

    /// Deletes the task. Not reversible.
    ///
    /// `confirmation` is the ticket a `taskDeletePreflight` for exactly this delete answered with.
    /// The route refuses without one, so there is no delete that skips the question.
    func deleteTask(
        id: String,
        cascadeSubTasks: Bool,
        discardWorktreeChanges: Bool,
        confirmation: String
    ) async throws
}

/// The server's consent ticket for deleting a task.
///
/// Short-lived, and bound to the person who asked, the cascade flag, and whether uncommitted work
/// may be discarded — so it is issued for one exact delete and cannot be kept and reused.
public struct KandevTaskDeletePreflight: Sendable, Decodable, Equatable {
    /// Whether a worktree holds uncommitted work that this delete would remove.
    public var requiresDiscardConsent: Bool
    public var confirmationID: String

    public init(requiresDiscardConsent: Bool = false, confirmationID: String) {
        self.requiresDiscardConsent = requiresDiscardConsent
        self.confirmationID = confirmationID
    }

    enum CodingKeys: String, CodingKey {
        case requiresDiscardConsent = "requires_discard_consent"
        case confirmationID = "confirmation_id"
    }
}

extension KandevHTTPRoute {
    /// Takes a task off the active board. Whether subtasks come too is a query
    /// flag, not part of the path, so it is the caller's to add.
    public static func taskArchive(taskID: String) -> String {
        "/api/v1/tasks/\(taskID)/archive"
    }

    /// Puts an archived task back on the board.
    public static func taskUnarchive(taskID: String) -> String {
        "/api/v1/tasks/\(taskID)/unarchive"
    }

    /// Deletes a task.
    public static func taskDelete(taskID: String) -> String {
        "/api/v1/tasks/\(taskID)"
    }

    /// The delete preflight: the task ids and the flags a delete would use, answered with a ticket
    /// for exactly that delete.
    public static let taskDeletePreflight = "/api/v1/tasks/delete-preflight"
}

/// The server's code for refusing to delete a task whose worktree is dirty.
public enum KandevTaskRemovalError {
    public static let dirtyWorktree = "task_delete_dirty_worktree"
}
