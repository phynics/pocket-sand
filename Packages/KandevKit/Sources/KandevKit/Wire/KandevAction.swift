import Foundation

/// The Kandev actions this client uses, and what each one demands.
///
/// Every entry was verified against a live server at
/// `KandevWireVersion.verifiedServerVersion` by sending the action and reading
/// the answer. Required fields were learned from the server's own
/// `VALIDATION_ERROR` messages, not inferred from the documentation.
///
/// Re-verify with:
///
///     make probe-v1
///
/// Kandev documents `/ws` as an internal protocol that can change without
/// notice, so treat a field name here as a fact about 0.96, not a promise.
public enum KandevAction {
    // MARK: - Reading the board

    /// Lists workspaces. Needs no payload.
    ///
    /// Response: `{ "workspaces": [...], "total": Int }`. A workspace carries
    /// `id`, `name`, and `scopes`, so permissions arrive with the list rather
    /// than as a separate call.
    public static let workspaceList = "workspace.list"

    /// Lists a workspace's workflows. **Requires `workspace_id`.**
    ///
    /// Response: `{ "workflows": [...], "total": Int }`. Warning: each workflow
    /// carries a full `prompt` string, which on a real server runs to kilobytes.
    /// Fetch this once, not per task list refresh.
    public static let workflowList = "workflow.list"

    /// Lists a workflow's steps, in order. **Requires `workflow_id`.**
    ///
    /// Response: `{ "steps": [...] }`, each with `id`, `name`, `position`. This
    /// is where a task's workflow-step name comes from: a task holds only a
    /// `workflow_step_id`.
    public static let workflowStepList = "workflow.step.list"

    /// Lists the tasks in one workflow. **Requires `workflow_id`.**
    ///
    /// Response: `{ "tasks": [...], "total": Int }`.
    ///
    /// There is no "all tasks in a workspace" *action* in 0.96, and `task.list`
    /// is not what the first-party client uses for a flat list: it uses
    /// `KandevHTTPRoute.workspaceTasks`, which paginates, searches, sorts, and
    /// spans workflows. Reach for this action when you already have a workflow
    /// in hand, not to build the task list.
    ///
    /// Each task in this response includes its full `description`, which on a
    /// real server is thousands of characters.
    public static let taskList = "task.list"

    /// Fetches one task. **Requires `id`.** The response *is* the task object.
    ///
    /// This is the single most useful call for the task detail screen: it
    /// already carries `primary_session_id`, `primary_session_state`,
    /// `session_count`, `foreground_activity`, `workflow_step_id`, `state`, and
    /// a `status_summary.last_activity_at`, so a task row needs no second
    /// request.
    public static let taskGet = "task.get"

    // MARK: - Reading a conversation

    /// Lists a session's messages. **Requires `session_id`.**
    ///
    /// Optional: `limit`, `before`, `after`, `around`, and `author_type`.
    /// Response: `{ "messages": [...], "cursor": String, "has_more": Bool }`.
    ///
    /// Cursor-paginated, and it starts at the *oldest* message. `before` is the
    /// lever for loading older turns, which is why scrolling back is a later
    /// feature and not a rewrite.
    public static let messageList = "message.list"

    /// Subscribes to a session's live conversation.
    /// **Requires `session_id` *and* `scope_id`.**
    ///
    /// This one reports failure the unusual way — see `KandevFailure`. It is the
    /// action that proved responses can carry `success: false`.
    ///
    /// **Requires `session_id`, `scope_id`, and `consumer_kind`.** `scope_id` is
    /// the subscriber's own name for itself and is echoed back on every change,
    /// so several clients can watch one session without applying each other's
    /// frames. `consumer_kind` is `core`.
    public static let sessionConversationSubscribe = "session.conversation.subscribe"

    /// Stops watching. Requires `session_id` and `scope_id`.
    public static let sessionConversationUnsubscribe = "session.conversation.unsubscribe"

    /// A change to a watched conversation.
    ///
    /// Carries `epoch`, `base_revision`, `revision`, and `operations`: an ordered
    /// log of message and turn upserts. A `check: true` change with no operations
    /// is a liveness heartbeat, not a change. Verified by driving a real agent
    /// turn and reading the stream.
    public static let sessionConversationChanged = "session.conversation.changed"

    /// Stops the active turn in a session. **Requires `session_id`.**
    ///
    /// Response: `{ "success": true }`. Stopping cancels the work, not the
    /// conversation: the session and its transcript survive.
    public static let sessionStop = "session.stop"

    /// Starts an agent on a task. **Requires `task_id` and `agent_profile_id`.**
    ///
    /// With only `task_id` the server answers `INTERNAL_ERROR: task has no
    /// agent_profile_id configured`, so the profile is not optional in practice
    /// even when the task records one. Response carries `session_id`,
    /// `agent_execution_id`, `state` (`STARTING`), and `success`.
    public static let sessionLaunch = "session.launch"

    // MARK: - Sending a prompt

    /// Puts a prompt in a session's queue.
    ///
    /// **Requires `session_id`, `task_id`, `session_incarnation_id`, and
    /// `content`.** The server names all four in one `VALIDATION_ERROR`, so they
    /// cannot be discovered one at a time.
    ///
    /// `session_incarnation_id` is the session's `queue_incarnation_id` — the
    /// two names refer to one value, and the mismatch between them is the
    /// server's. It is an identity token, so the client cannot send a prompt
    /// until it holds the session record: fetch the session first.
    ///
    /// This **enqueues**. Getting the prompt in front of the agent is the
    /// queue's job, not the caller's, and on a live server `auto_run` defaulted
    /// to true, so a queued prompt on an idle session was dispatched and answered
    /// without a second call.
    public static let messageQueueAdd = "message.queue.add"

    /// Interrupts the running turn and sends a queue selection.
    ///
    /// **Requires the three ids plus `scope`** (`entry` or `all`), and `entry_id`
    /// when the scope is one entry. Answers `{session_id, dispatched, sent_count}`.
    ///
    /// Distinct from `messageQueueDrain`, which only dispatches when the session
    /// is *ready for input*. This one cancels work in progress to make room for
    /// the prompt.
    public static let messageQueueSendNow = "message.queue.send_now"

    /// Drops every pending prompt for a session. Requires the three ids.
    public static let messageQueueCancel = "message.queue.cancel"

    /// Reads a session's queue. Requires the same three ids as
    /// `messageQueueAdd`.
    ///
    /// Response carries `count`, `entries`, `max` (5 on a live server),
    /// `auto_run`, `merge_enabled`, and `status_generation`.
    public static let messageQueueGet = "message.queue.get"

    // MARK: - Creating and removing

    /// Creates a task. **Requires `workspace_id` and `workflow_id`.**
    ///
    /// `description` becomes the session's first prompt verbatim, so a task
    /// created with a one-character description produced a one-character first
    /// turn. Response adds `creation_complete` and `deduplicated`.
    public static let taskCreate = "task.create"

    /// Deletes a task. **Requires `id`.** Response: `{ "success": true }`.
    public static let taskDelete = "task.delete"

    /// A task changed. Carries the whole task, in the same shape the HTTP list
    /// returns but keyed by `task_id`.
    public static let taskUpdated = "task.updated"

    /// A task moved workflow step, or changed state. Carries the whole task plus
    /// `old_state` and `new_state`.
    public static let taskStateChanged = "task.state_changed"

    /// A session's own state changed — its lifecycle state and what the agent is
    /// doing. Carries `session_id`, `task_id`, `old_state`, `new_state`, and
    /// `foreground_activity`.
    public static let sessionStateChanged = "session.state_changed"

    /// A task appeared. Announced separately from `task.updated`, so a list that
    /// only watched updates would never notice new work.
    public static let taskCreated = "task.created"

    /// A task was removed. The row has to go, and a catch-up is how it goes.
    public static let taskDeleted = "task.deleted"

    /// A task was archived, which removes it from the default list.
    public static let taskArchived = "task.archived"

    /// A task's status summary changed — its activity, its session state, its
    /// diff counts. Carries only `task_id`, `workspace_id`, and `status_summary`,
    /// and arrives far more often than the other two: thirteen times to five
    /// during one live agent turn.
    public static let taskStatusSummaryUpdated = "task.status_summary.updated"

    /// Every action name that has been exercised against a live server.
    public static let verified: [String] = [
        workspaceList,
        workflowList,
        workflowStepList,
        taskList,
        taskGet,
        taskCreate,
        taskDelete,
        messageList,
        messageQueueAdd,
        messageQueueGet,
        messageQueueSendNow,
        messageQueueCancel,
        sessionConversationSubscribe,
        sessionConversationUnsubscribe,
        sessionConversationChanged,
        sessionLaunch,
        sessionStop,
        sessionStateChanged,
        taskCreated,
        taskDeleted,
        taskArchived,
        taskUpdated,
        taskStateChanged,
        taskStatusSummaryUpdated,
    ]
}

/// Endpoints that are HTTP, not WebSocket.
///
/// Correcting an assumption worth writing down: `/ws` is *most* of the API, not
/// all of it. The interesting reads are HTTP, and the flat task list is one of
/// them — the first-party web client builds its sidebar from
/// `GET /api/v1/workspaces/{id}/tasks`, not from the `task.list` action.
public enum KandevHTTPRoute {
    /// **The flat task list.** Every task in a workspace, across every workflow.
    ///
    /// This is what the first-party client uses to show open work, and it is the
    /// single call our task list wants. Verified against a live server.
    ///
    /// Query parameters, all optional:
    ///
    /// | Parameter | Effect |
    /// | --- | --- |
    /// | `page`, `page_size` | 1-based page; page size caps at **100** |
    /// | `query` | Server-side text search |
    /// | `sort` | `updated_desc` (default), `updated_asc`, `created_desc`, `created_asc`, `title_asc`, `title_desc` |
    /// | `workflow_id` | Narrow to one workflow |
    /// | `repository_id` | Narrow to one repository |
    /// | `include_archived`, `only_archived` | Archive mode |
    /// | `include_ephemeral`, `only_ephemeral` | Ephemeral tasks, such as config sessions |
    /// | `exclude_config` | Drop configuration sessions |
    ///
    /// `updated_desc` is the closest thing to sorting by last activity. It sorts
    /// on the task's `updated_at`, which on a live server tracked
    /// `status_summary.last_activity_at` closely but is not the same field.
    ///
    /// There is **no field selection**: every task arrives with its full
    /// `description`, and a real server produced 13KB for three tasks. Bound the
    /// page and filter server-side; do not expect to ask for fewer fields.
    public static func workspaceTasks(workspaceID: String) -> String {
        "/api/v1/workspaces/\(workspaceID)/tasks"
    }

    /// The sessions attached to a task. Not available as a WebSocket action in 0.96.
    public static func taskSessions(taskID: String) -> String {
        "/api/v1/tasks/\(taskID)/sessions"
    }

    /// The kanban board for one workflow: its steps and their tasks.
    ///
    /// The board view fans this out, one request per workflow, and aggregates
    /// client-side. The flat task list does *not* use it.
    public static func workflowSnapshot(workflowID: String) -> String {
        "/api/v1/workflows/\(workflowID)/snapshot"
    }

    /// Moving a task to another step. HTTP, and the first-party client uses it
    /// rather than the `task.move` action name, so this client does too.
    public static func taskMove(taskID: String) -> String {
        "/api/v1/tasks/\(taskID)/move"
    }

    /// What a move would do, without doing it.
    public static func taskMovePreview(taskID: String) -> String {
        "/api/v1/tasks/\(taskID)/move-preview"
    }

    /// The agent catalogue: every runtime and its profiles.
    public static let agents = "/api/v1/agents"

    /// Liveness, and the cheapest way to identify a server and its version.
    public static let health = "/health"

    /// Feature flags, readable without a token.
    public static let features = "/api/v1/features"
}
