import Foundation

/// The two kinds of chat a workspace can start.
///
/// A chat is **not a separate object on the server**. Starting one creates a task
/// and a session and hands back both ids, exactly as `task.create` does. What
/// differs is:
///
/// - the task is **not filed**: no workflow step, so it is a conversation rather
///   than a piece of tracked work;
/// - its agent profile has a different default — the workspace's
///   `default_config_agent_profile_id` for a configuration chat, and the
///   workspace's ordinary default for a quick one.
///
/// Verified against a live v0.96.0 server's own client, which posts to
/// `/api/v1/workspaces/{id}/quick-chat` and `/api/v1/workspaces/{id}/config-chat`
/// and reads `task_id`, `session_id` and `agent_profile_id` back.
public enum KandevChatKind: String, Sendable, CaseIterable {
    /// Talk to an agent now, without deciding what it is part of. Named `quick`
    /// because the point is that nothing has to be decided first.
    case quick
    /// A chat whose job is to change Kandev's own configuration — agent profiles,
    /// workflows, MCP servers. The first-party client gives it a different default
    /// profile and a set of suggested prompts, which is the whole of what makes it
    /// a different thing.
    case config

    /// The route that starts one.
    public var route: (String) -> String {
        switch self {
        case .quick: KandevHTTPRoute.quickChat
        case .config: KandevHTTPRoute.configChat
        }
    }
}

/// A chat that was just started: the task and the session behind it.
public struct KandevChat: Decodable, Sendable, Equatable {
    /// The task the server created. A chat is a task, so this can be opened,
    /// listed and — later — filed, like any other.
    public var taskID: String
    public var sessionID: String
    public var agentProfileID: String?

    public init(taskID: String, sessionID: String, agentProfileID: String? = nil) {
        self.taskID = taskID
        self.sessionID = sessionID
        self.agentProfileID = agentProfileID
    }

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case sessionID = "session_id"
        case agentProfileID = "agent_profile_id"
    }
}

/// Starting a chat.
public protocol KandevChatStarting: Sendable {
    /// Starts a chat and returns the task and session it created.
    ///
    /// - Parameters:
    ///   - title: What the task is called. A chat has no title field of its own,
    ///     so this is derived from what the person wrote, or from the agent's name.
    ///   - repositories: Repositories to attach. Empty means the workspace's own,
    ///     which is the right default on a phone.
    func startChat(
        kind: KandevChatKind,
        workspaceID: String,
        agentProfileID: String,
        title: String?,
        repositories: [String]
    ) async throws -> KandevChat
}

public extension KandevChatStarting {
    /// Starts a chat with the defaults this client uses.
    func startChat(
        kind: KandevChatKind,
        workspaceID: String,
        agentProfileID: String,
        title: String? = nil
    ) async throws -> KandevChat {
        try await startChat(
            kind: kind,
            workspaceID: workspaceID,
            agentProfileID: agentProfileID,
            title: title,
            repositories: []
        )
    }
}

public extension KandevHTTPRoute {
    /// Starts a quick chat. POST, and it answers with the task and session it made.
    static func quickChat(workspaceID: String) -> String {
        "/api/v1/workspaces/\(workspaceID)/quick-chat"
    }

    /// Starts a configuration chat. Same shape, different default profile.
    static func configChat(workspaceID: String) -> String {
        "/api/v1/workspaces/\(workspaceID)/config-chat"
    }

    /// The chats that already exist. Unused so far, and kept because the route is
    /// verified: a screen that lists chats is the obvious next thing, and a chat
    /// that is not in the task list has to be found somewhere.
    static func quickChats(workspaceID: String) -> String {
        "/api/v1/workspaces/\(workspaceID)/quick-chats"
    }
}

extension KandevClient: KandevChatStarting {}
