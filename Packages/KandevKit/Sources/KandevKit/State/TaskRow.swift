import Foundation

/// One row of the task list, reduced to what the row actually draws.
///
/// A row is not a task. The server sends a task's whole description — kilobytes
/// of it — and none of that belongs on a row, so the store throws it away here
/// rather than letting it travel into the view and be ignored there.
public struct TaskRow: Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var title: String
    /// Resolved from `workflowStepID`. `nil` only when a step name could not be
    /// found, which `TaskListStore` reports rather than rendering as blank.
    public var stepName: String?
    /// The step's colour as the server describes it, a tailwind class such as
    /// `bg-blue-500`. Kept as the server's string: turning it into a colour is
    /// the view's job, and the mapping belongs where the palette lives.
    public var stepColor: String?
    /// Whether a turn is in flight right now. Read from the session, not the
    /// task state, because the two disagree in normal operation.
    public var isWorking: Bool
    /// Whether the ball is in a person's court.
    ///
    /// Derived here rather than in a view because it is a judgement about the
    /// domain, not a matter of taste: a task in review is waiting on a human
    /// gate, and a session waiting for input has finished its turn and is waiting
    /// for someone to say what next. A task whose agent is working needs nobody.
    public var needsAttention: Bool
    /// The server has called this task failed.
    ///
    /// A state the server names, not a judgement this client makes: `FAILED` is what
    /// it sends, and a session that failed is the task failing.
    public var isFailed: Bool
    /// An agent has asked for something and cannot go on without it.
    ///
    /// Stronger than `needsAttention`: that one means the ball is in a person's court
    /// and nothing is blocked, where this means work has stopped on the answer.
    public var isAwaitingAnswer: Bool
    /// The task this one is a subtask of, as the server sends it.
    public var parentID: String?
    /// How far in from the left this row sits: 0 for a task, 1 for a subtask.
    ///
    /// Derived by the list rather than read from the server, because whether a
    /// subtask is *shown* as one depends on whether its parent is on screen: a child
    /// whose parent is on another page is drawn as a task, since the alternative is
    /// hiding it.
    public var depth: Int
    public var lastActivity: Date?
    /// The repository this task belongs to, for grouping the list by project.
    public var repositoryID: String?
    /// The repository's name, for a row that has to say where it belongs.
    ///
    /// Filled once the repositories have been read: in a flat list the row carries its project's
    /// name because there is no section heading to say it.
    public var repositoryName: String?
    /// Whether this row is a conversation rather than work.
    public var isEphemeral: Bool

    /// Whether this task wants a person rather than an agent.
    ///
    /// Broad on purpose: a failure, a question, and a gate all want the same person, and the
    /// list's one job is to put them where the eye lands first.
    public var wantsAPerson: Bool {
        isFailed || isAwaitingAnswer || needsAttention
    }

    public init(
        id: String,
        title: String,
        stepName: String?,
        stepColor: String? = nil,
        isWorking: Bool,
        needsAttention: Bool = false,
        isFailed: Bool = false,
        isAwaitingAnswer: Bool = false,
        parentID: String? = nil,
        depth: Int = 0,
        lastActivity: Date?,
        repositoryID: String? = nil,
        repositoryName: String? = nil,
        isEphemeral: Bool = false
    ) {
        self.id = id
        self.title = title
        self.stepName = stepName
        self.stepColor = stepColor
        self.isWorking = isWorking
        self.needsAttention = needsAttention
        self.isFailed = isFailed
        self.isAwaitingAnswer = isAwaitingAnswer
        self.parentID = parentID
        self.depth = depth
        self.lastActivity = lastActivity
        self.repositoryID = repositoryID
        self.repositoryName = repositoryName
        self.isEphemeral = isEphemeral
    }
}

extension KandevTask {
    /// Whether the server has called this task, or its session, failed.
    public var isFailed: Bool {
        state?.uppercased() == "FAILED" || primarySessionState?.uppercased() == "FAILED"
    }

    /// Whether an agent is waiting on a person to answer something.
    public var isAwaitingAnswer: Bool {
        taskPendingAction?.isEmpty == false || primarySessionPendingAction?.isEmpty == false
    }
}

extension TaskRow {
    /// Builds a row from a task and the steps known so far.
    init(task: KandevTask, steps: [String: KandevWorkflowStep]) {
        let step = task.workflowStepID.flatMap { steps[$0] }
        self.init(
            id: task.id,
            title: task.title,
            stepName: step?.name,
            stepColor: step?.color,
            isWorking: task.isWorking,
            needsAttention: task.needsAttention,
            isFailed: task.isFailed,
            isAwaitingAnswer: task.isAwaitingAnswer,
            parentID: task.parentID,
            lastActivity: task.lastActivity?.date,
            // The first repository a task is attached to. A task can carry several;
            // the first is the one the first-party client shows beside it, and
            // grouping by all of them would put one task in two sections.
            repositoryID: task.repositories?.first?.repositoryID,
            isEphemeral: task.isEphemeral == true
        )
    }
}
