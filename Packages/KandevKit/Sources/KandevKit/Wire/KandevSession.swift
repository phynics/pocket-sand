import Foundation

/// A session: one agent conversation attached to a task.
///
/// Verified against a live server via `GET /api/v1/tasks/{id}/sessions`. That
/// route returned **79KB for a single session**, almost all of it `metadata` and
/// `worktrees`, so this model keeps only what a session switcher shows and
/// leaves the rest in `metadata` as an opaque value.
public struct KandevSession: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var taskID: String?
    /// Usually empty; the UI falls back to a derived title.
    public var name: String?
    public var state: String?
    public var isPrimary: Bool?
    public var agentProfileID: String?
    public var executorID: String?
    public var worktreeBranch: String?
    public var commandCount: Int?
    /// Where the reader got to. Useful for an unread divider later.
    public var lastReadMessageID: String?
    /// The identity token that queue actions require, named `session_incarnation_id`
    /// in their payloads and `queue_incarnation_id` here.
    ///
    /// The two names are the server's. This field is why a client cannot send a
    /// prompt before it has fetched the session.
    public var queueIncarnationID: String?
    public var startedAt: KandevTimestamp?
    public var updatedAt: KandevTimestamp?
    /// Opaque: ACP metadata and worktree inventories live here and are large.
    public var metadata: JSONValue?

    public enum CodingKeys: String, CodingKey {
        case id, name, state, metadata
        case taskID = "task_id"
        case isPrimary = "is_primary"
        case agentProfileID = "agent_profile_id"
        case executorID = "executor_id"
        case worktreeBranch = "worktree_branch"
        case commandCount = "command_count"
        case lastReadMessageID = "last_read_message_id"
        case queueIncarnationID = "queue_incarnation_id"
        case startedAt = "started_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String,
        taskID: String? = nil,
        name: String? = nil,
        state: String? = nil,
        isPrimary: Bool? = nil,
        agentProfileID: String? = nil,
        executorID: String? = nil,
        worktreeBranch: String? = nil,
        commandCount: Int? = nil,
        lastReadMessageID: String? = nil,
        queueIncarnationID: String? = nil,
        startedAt: KandevTimestamp? = nil,
        updatedAt: KandevTimestamp? = nil,
        metadata: JSONValue? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.name = name
        self.state = state
        self.isPrimary = isPrimary
        self.agentProfileID = agentProfileID
        self.executorID = executorID
        self.worktreeBranch = worktreeBranch
        self.commandCount = commandCount
        self.lastReadMessageID = lastReadMessageID
        self.queueIncarnationID = queueIncarnationID
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    /// A label for a session tab, falling back to the branch when the server has
    /// no name. Kandev never requires a session name, so this is the common case.
    public var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        if let branch = worktreeBranch, !branch.isEmpty { return branch }
        return String(id.prefix(8))
    }
}

/// A message in a session transcript.
///
/// Verified against a live server via `message.list`, which is cursor-paginated
/// and starts at the *oldest* message.
public struct KandevMessage: Sendable, Codable, Equatable, Identifiable {
    /// The kinds of row a transcript contains.
    ///
    /// Read off a live server that ran one real agent turn: a single turn
    /// produced a `status` notice, a `message`, four `tool_execute` calls, and
    /// four `thinking` blocks. Tool calls arrive as messages, so the UI has to
    /// branch on this rather than on `authorType` alone.
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// Text a human should read: a prompt or an agent's reply.
        case message
        /// A reasoning block. Its text lives under `metadata.thinking`.
        case thinking
        /// A tool call that ran a command.
        case toolExecute = "tool_execute"
        /// A tool call that read a file. Found on a live server while an agent
        /// worked. The family is not closed: a consumer reads the `tool_` prefix
        /// rather than this list.
        case toolRead = "tool_read"
        /// A setup or utility script the server ran.
        case scriptExecution = "script_execution"
        /// A lifecycle notice, such as "New session started".
        case status
    }

    public var id: String
    /// `user`, `agent`, or a system author.
    public var authorType: String?
    /// One of `Kind`, kept as a string so an unrecognised kind does not fail the
    /// whole page of messages.
    public var type: String?
    /// What the reader should see. The server may have rewritten this.
    public var content: String?
    /// What the agent was actually sent, including injected preamble such as
    /// `<kandev-system>` blocks. Empty when it matches `content`.
    public var rawContent: String?
    /// Groups one prompt-and-response cycle. Present on every message, which is
    /// why turn boundaries do not have to be inferred from content.
    public var turnID: String?
    public var promptIndex: Int?
    /// Present on messages delivered by a live change, absent from `message.list`.
    public var sessionID: String?
    public var taskID: String?
    public var createdAt: KandevTimestamp?
    public var metadata: JSONValue?

    public enum CodingKeys: String, CodingKey {
        case id, content, type, metadata
        case authorType = "author_type"
        case rawContent = "raw_content"
        case turnID = "turn_id"
        case promptIndex = "prompt_index"
        case sessionID = "session_id"
        case taskID = "task_id"
        case createdAt = "created_at"
    }

    public init(
        id: String,
        authorType: String? = nil,
        type: String? = nil,
        content: String? = nil,
        rawContent: String? = nil,
        turnID: String? = nil,
        promptIndex: Int? = nil,
        sessionID: String? = nil,
        taskID: String? = nil,
        createdAt: KandevTimestamp? = nil,
        metadata: JSONValue? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.taskID = taskID
        self.authorType = authorType
        self.type = type
        self.content = content
        self.rawContent = rawContent
        self.turnID = turnID
        self.promptIndex = promptIndex
        self.createdAt = createdAt
        self.metadata = metadata
    }

    public var isFromUser: Bool { authorType == "user" }

    /// The kind, or `nil` when the server sends one this client does not know.
    /// A call site should render an unrecognised kind plainly rather than drop
    /// it, because a dropping transcript lies about what happened.
    public var kind: Kind? { type.flatMap(Kind.init(rawValue:)) }
}

extension JSONValue {
    /// The string inside a `.string` case, for the few places where a value is
    /// known to be text but arrives typed as JSON.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

/// One page of a session's messages.
public struct KandevMessagePage: Sendable, Codable, Equatable {
    public var messages: [KandevMessage]
    /// Pass back as `before` to fetch the page before this one.
    public var cursor: String?
    public var hasMore: Bool

    public enum CodingKeys: String, CodingKey {
        case messages, cursor
        case hasMore = "has_more"
    }

    public init(messages: [KandevMessage], cursor: String? = nil, hasMore: Bool = false) {
        self.messages = messages
        self.cursor = cursor
        self.hasMore = hasMore
    }
}
