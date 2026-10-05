import Foundation

/// A prompt sitting in a session's queue.
///
/// Verified against a live server: `message.queue.add` answers with this, not
/// with a sent message. `position` is the queue slot.
public struct KandevQueuedPrompt: Sendable, Decodable, Equatable, Identifiable {
    public var id: String
    public var content: String
    public var position: Int?
    public var queuedAt: KandevTimestamp?
    public var queuedBy: String?
    /// The server can hold a prompt for plan mode rather than sending it.
    public var planMode: Bool?
    public var model: String?
    public var sessionID: String?
    public var taskID: String?
    public var attachments: JSONValue?
    /// The caller's own id for this prompt, echoed back. Sending one makes a
    /// retry after a transport failure safe: the server can recognise the
    /// duplicate instead of queueing the prompt twice.
    public var clientQueueID: String?

    public enum CodingKeys: String, CodingKey {
        case id, content, position, model, attachments
        case queuedAt = "queued_at"
        case queuedBy = "queued_by"
        case planMode = "plan_mode"
        case sessionID = "session_id"
        case taskID = "task_id"
        case clientQueueID = "client_queue_id"
    }

    public init(
        id: String,
        content: String,
        position: Int? = nil,
        queuedAt: KandevTimestamp? = nil,
        queuedBy: String? = nil,
        planMode: Bool? = nil,
        model: String? = nil,
        sessionID: String? = nil,
        taskID: String? = nil,
        attachments: JSONValue? = nil,
        clientQueueID: String? = nil
    ) {
        self.id = id
        self.content = content
        self.position = position
        self.queuedAt = queuedAt
        self.queuedBy = queuedBy
        self.planMode = planMode
        self.model = model
        self.sessionID = sessionID
        self.taskID = taskID
        self.attachments = attachments
        self.clientQueueID = clientQueueID
    }
}

/// A session's queue, as `message.queue.get` reports it.
public struct KandevQueueSnapshot: Sendable, Decodable, Equatable {
    public var count: Int
    public var entries: [KandevQueuedPrompt]
    /// Whether the server dispatches queued prompts by itself. True on a live
    /// server, which is why a prompt sent to an idle session produced a reply
    /// with no second call.
    public var autoRun: Bool?
    public var mergeEnabled: Bool?
    /// The queue's capacity. Five on a live server.
    public var max: Int?
    public var sessionID: String?
    public var sessionIncarnationID: String?
    public var statusGeneration: Int?

    public enum CodingKeys: String, CodingKey {
        case count, entries, max
        case autoRun = "auto_run"
        case mergeEnabled = "merge_enabled"
        case sessionID = "session_id"
        case sessionIncarnationID = "session_incarnation_id"
        case statusGeneration = "status_generation"
    }

    /// Whether another prompt can be queued. The server's limit is five.
    public var isFull: Bool {
        guard let max, max > 0 else { return false }
        return count >= max
    }
}

/// What `message.queue.send_now` answers.
///
/// This action interrupts the turn that is running, which is why the result says
/// whether anything was actually dispatched and how many entries went.
public struct KandevSendNowResult: Sendable, Decodable, Equatable {
    public var sessionID: String
    public var dispatched: Bool
    public var sentCount: Int

    public enum CodingKeys: String, CodingKey {
        case dispatched
        case sessionID = "session_id"
        case sentCount = "sent_count"
    }

    public init(sessionID: String, dispatched: Bool, sentCount: Int) {
        self.sessionID = sessionID
        self.dispatched = dispatched
        self.sentCount = sentCount
    }
}

/// What a session launch reports back.
public struct KandevSessionLaunch: Sendable, Decodable, Equatable {
    public var success: Bool?
    public var sessionID: String
    public var taskID: String?
    public var agentExecutionID: String?
    public var agentProfileID: String?
    /// `STARTING` when the process is on its way up.
    public var state: String?

    public enum CodingKeys: String, CodingKey {
        case success, state
        case sessionID = "session_id"
        case taskID = "task_id"
        case agentExecutionID = "agent_execution_id"
        case agentProfileID = "agent_profile_id"
    }
}
