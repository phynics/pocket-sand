import Foundation

/// A task, as the server sends it.
///
/// Verified against a live server: `task.get` and the workspace task list return
/// the same shape, and a list row already carries everything the task list needs
/// — `state`, `workflow_step_id`, `status_summary.last_activity_at`, and
/// `primary_session_id`. Fields that only the detail call fills (`parent_id`,
/// `foreground_activity`) are optional here rather than a second type, because
/// the two responses differ by degrees and not by kind.
public struct KandevTask: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// The task's own instructions. On a real server this runs to kilobytes, and
    /// the server sends it whether we want it or not.
    public var description: String?
    public var state: String?
    public var workflowID: String?
    public var workflowStepID: String?
    public var workspaceID: String?
    public var parentID: String?
    public var externalID: String?
    public var priority: String?
    public var origin: String?
    /// Whether this task is a conversation rather than work: a quick chat or a
    /// configuration chat.
    ///
    /// The server sends these in the task list, and the first-party client filters
    /// them out of its sidebar — which is how this field was found. This client shows
    /// them instead, in a section of their own, because a chat is a task and the way
    /// to file one later is to have it in front of you.
    public var isEphemeral: Bool?
    public var autopilot: Bool?
    public var position: Int?
    public var sessionCount: Int?
    public var activeSubagentCount: Int?
    public var labels: KandevStringList?
    public var repositories: [KandevTaskRepository]?
    public var statusSummary: KandevStatusSummary?
    public var createdAt: KandevTimestamp?
    public var updatedAt: KandevTimestamp?

    /// The session a task treats as its default target.
    public var primarySessionID: String?
    public var primarySessionState: String?
    /// What the task is waiting for, when it is waiting for a person.
    ///
    /// The server sends this on the task and, separately, on its primary session;
    /// either one being set means an agent has asked for something and cannot go on
    /// without an answer.
    public var taskPendingAction: String?
    public var primarySessionPendingAction: String?
    public var primaryAgentName: String?
    public var primaryExecutorName: String?
    public var primaryExecutorType: String?
    /// Only present on `task.get`. `statusSummary` carries it for list rows.
    public var foregroundActivity: String?

    public enum CodingKeys: String, CodingKey {
        case id, title, description, state, priority, origin, autopilot, position, labels
        case isEphemeral = "is_ephemeral"
        case repositories
        case workflowID = "workflow_id"
        case workflowStepID = "workflow_step_id"
        case workspaceID = "workspace_id"
        case parentID = "parent_id"
        case externalID = "external_id"
        case sessionCount = "session_count"
        case activeSubagentCount = "active_subagent_count"
        case statusSummary = "status_summary"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case primarySessionID = "primary_session_id"
        case primarySessionState = "primary_session_state"
        case taskPendingAction = "task_pending_action"
        case primarySessionPendingAction = "primary_session_pending_action"
        case primaryAgentName = "primary_agent_name"
        case primaryExecutorName = "primary_executor_name"
        case primaryExecutorType = "primary_executor_type"
        case foregroundActivity = "foreground_activity"
    }

    /// Every field defaulted except identity, so a test, a preview, or a future
    /// create screen names only what it means.
    public init(
        id: String,
        title: String,
        description: String? = nil,
        state: String? = nil,
        workflowID: String? = nil,
        workflowStepID: String? = nil,
        workspaceID: String? = nil,
        parentID: String? = nil,
        externalID: String? = nil,
        priority: String? = nil,
        origin: String? = nil,
        isEphemeral: Bool? = nil,
        autopilot: Bool? = nil,
        position: Int? = nil,
        sessionCount: Int? = nil,
        activeSubagentCount: Int? = nil,
        labels: KandevStringList? = nil,
        repositories: [KandevTaskRepository]? = nil,
        statusSummary: KandevStatusSummary? = nil,
        createdAt: KandevTimestamp? = nil,
        updatedAt: KandevTimestamp? = nil,
        primarySessionID: String? = nil,
        primarySessionState: String? = nil,
        taskPendingAction: String? = nil,
        primarySessionPendingAction: String? = nil,
        primaryAgentName: String? = nil,
        primaryExecutorName: String? = nil,
        primaryExecutorType: String? = nil,
        foregroundActivity: String? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.state = state
        self.workflowID = workflowID
        self.workflowStepID = workflowStepID
        self.workspaceID = workspaceID
        self.parentID = parentID
        self.externalID = externalID
        self.priority = priority
        self.origin = origin
        self.isEphemeral = isEphemeral
        self.autopilot = autopilot
        self.position = position
        self.sessionCount = sessionCount
        self.activeSubagentCount = activeSubagentCount
        self.labels = labels
        self.repositories = repositories
        self.statusSummary = statusSummary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.primarySessionID = primarySessionID
        self.primarySessionState = primarySessionState
        self.taskPendingAction = taskPendingAction
        self.primarySessionPendingAction = primarySessionPendingAction
        self.primaryAgentName = primaryAgentName
        self.primaryExecutorName = primaryExecutorName
        self.primaryExecutorType = primaryExecutorType
        self.foregroundActivity = foregroundActivity
    }

    /// Whether a turn is in flight right now.
    ///
    /// `primary_session_state` is the live signal; `state` is the task's workflow
    /// position. They disagree in normal operation — a live server showed a task
    /// in `REVIEW` whose session was `WAITING_FOR_INPUT`.
    public var isWorking: Bool {
        primarySessionState == "RUNNING" || foregroundActivity == "generating"
    }

    /// Whether the ball is in a person's court.
    ///
    /// Work in flight needs nobody. A task at a review gate does, and so does a
    /// session that has finished its turn and is waiting for input — on a live
    /// server that is what an idle agent looks like between prompts.
    public var needsAttention: Bool {
        guard !isWorking else { return false }
        if state == "REVIEW" { return true }
        return primarySessionState == "WAITING_FOR_INPUT"
    }

    /// A timestamp suitable for sorting the task list.
    public var lastActivity: KandevTimestamp? {
        statusSummary?.lastActivityAt ?? updatedAt
    }
}

/// A repository attached to a task.
public struct KandevTaskRepository: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var repositoryID: String?
    public var baseBranch: String?

    public enum CodingKeys: String, CodingKey {
        case id
        case repositoryID = "repository_id"
        case baseBranch = "base_branch"
    }

    public init(id: String, repositoryID: String? = nil, baseBranch: String? = nil) {
        self.id = id
        self.repositoryID = repositoryID
        self.baseBranch = baseBranch
    }
}

/// The bounded summary the server attaches to every task.
public struct KandevStatusSummary: Sendable, Codable, Equatable {
    /// Increments as the task changes, which makes it usable as a freshness
    /// check: a stored summary with a lower revision is stale.
    public var revision: Int?
    public var updatedAt: KandevTimestamp?
    public var lastActivityAt: KandevTimestamp?
    public var primarySession: PrimarySession?
    public var git: Git?

    public enum CodingKeys: String, CodingKey {
        case revision, git
        case updatedAt = "updated_at"
        case lastActivityAt = "last_activity_at"
        case primarySession = "primary_session"
    }

    public init(
        revision: Int? = nil,
        updatedAt: KandevTimestamp? = nil,
        lastActivityAt: KandevTimestamp? = nil,
        primarySession: PrimarySession? = nil,
        git: Git? = nil
    ) {
        self.revision = revision
        self.updatedAt = updatedAt
        self.lastActivityAt = lastActivityAt
        self.primarySession = primarySession
        self.git = git
    }

    public struct PrimarySession: Sendable, Codable, Equatable {
        public var id: String
        public var state: String?

        public init(id: String, state: String? = nil) {
            self.id = id
            self.state = state
        }
    }

    /// Git facts the server already computed. Present fields vary: one task
    /// carried only `behind`, another carried diff counts.
    public struct Git: Sendable, Codable, Equatable {
        public var changedFiles: Int?
        public var additions: Int?
        public var deletions: Int?
        public var behind: Int?
        public var ahead: Int?

        public enum CodingKeys: String, CodingKey {
            case additions, deletions, behind, ahead
            case changedFiles = "changed_files"
        }

        public init(
            changedFiles: Int? = nil,
            additions: Int? = nil,
            deletions: Int? = nil,
            behind: Int? = nil,
            ahead: Int? = nil
        ) {
            self.changedFiles = changedFiles
            self.additions = additions
            self.deletions = deletions
            self.behind = behind
            self.ahead = ahead
        }
    }
}
