import Foundation

/// What the server says this caller may do about a workspace's conversations.
///
/// These arrive with `workspace.list`, so the app already has them and should
/// act on them: offering a Send button to someone the server will refuse is a
/// worse experience than not offering it. On a single-user install every scope
/// is granted and this changes nothing — which is exactly why it would otherwise
/// go unnoticed until it mattered.
public struct ConversationPermissions: Sendable, Equatable {
    /// May send prompts.
    public var canPrompt: Bool
    /// May start and stop agent work.
    public var canControlSessions: Bool

    public init(canPrompt: Bool, canControlSessions: Bool) {
        self.canPrompt = canPrompt
        self.canControlSessions = canControlSessions
    }

    /// What a server without an authentication boundary effectively grants.
    ///
    /// Used before a workspace has been read, and deliberately separate from the
    /// scopes a server sends: a default that guessed *less* would disable the
    /// composer on the single-user installs Kandev is built for.
    public static let `default` = ConversationPermissions(
        canPrompt: true,
        canControlSessions: true
    )
}

extension KandevWorkspace {
    public var conversationPermissions: ConversationPermissions {
        ConversationPermissions(
            canPrompt: canPrompt,
            canControlSessions: canControlSessions
        )
    }
}
