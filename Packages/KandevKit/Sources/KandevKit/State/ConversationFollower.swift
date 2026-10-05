import Foundation
import Observation

/// A subscription's own name.
///
/// The server treats this as opaque and echoes it back; the first-party client
/// uses `core:web:<uuid>`, and the shape is the only thing that matters. Naming
/// which client it is makes a server log readable when two clients watch one
/// session. Verified: a scope id of this shape is accepted.
public enum ConversationScope {
    public static func newID(client: String = "ios") -> String {
        "core:\(client):\(UUID().uuidString)"
    }
}

/// What a follower needs to watch a conversation.
public protocol KandevConversationStreaming: Sendable {
    func subscribeToConversation(
        sessionID: String,
        scopeID: String
    ) async throws -> KandevConversationSubscription
    func unsubscribeFromConversation(sessionID: String, scopeID: String) async throws
}

/// Starting an agent, which is the only way a task with no session ever gets one.
public protocol KandevSessionStarting: Sendable {
    func agentProfiles() async throws -> [KandevAgentProfile]
    func launchSession(taskID: String, agentProfileID: String) async throws -> KandevSessionLaunch
}

/// Subscribing to a conversation, plus the hub its frames arrive through.
///
/// Narrower than the whole server on purpose: following a conversation does not
/// need to be able to read tasks or send prompts, and a stub should not have to
/// pretend to be a server to be followed.
public protocol KandevLiveConversations: KandevConversationStreaming {
    /// The single reader of the notification stream, shared by every screen.
    var hub: KandevNotificationHub { get }
}

/// Everything a conversation screen needs from a server: read it, write to it,
/// and hear about changes.
public protocol KandevConversationServer: KandevTranscriptSource, KandevPromptSource,
    KandevLiveConversations, KandevSessionStarting, KandevTaskMoving, KandevTaskRemoving
{}

extension KandevClient: KandevConversationStreaming, KandevLiveConversations,
    KandevSessionStarting, KandevTaskMoving, KandevTaskRemoving,
    KandevConversationServer {}

/// Follows one session's conversation.
///
/// Owns the subscription — the handshake and the unsubscribe — and takes its
/// frames from the hub, which is the single reader of the notification stream.
public actor ConversationFollower {
    private let client: any KandevConversationStreaming
    private let hub: KandevNotificationHub
    private let sessionID: String
    public nonisolated let scopeID: String

    private var started = false

    public init(
        client: any KandevConversationStreaming,
        hub: KandevNotificationHub,
        sessionID: String,
        scopeID: String = ConversationScope.newID()
    ) {
        self.client = client
        self.hub = hub
        self.sessionID = sessionID
        self.scopeID = scopeID
    }

    /// Subscribes and returns the handshake, which says where the conversation
    /// log stands. Throws if the server refuses the subscription; a caller may
    /// treat that as non-fatal and fall back to refetching.
    public func start() async throws -> (subscription: KandevConversationSubscription, changes: AsyncStream<KandevConversationChange>) {
        guard !started else {
            throw KandevError.malformedFrame("this follower is already following")
        }
        let subscription = try await client.subscribeToConversation(
            sessionID: sessionID,
            scopeID: scopeID
        )
        started = true
        // The hub filters by session and scope, so nothing addressed to another
        // client can reach this follower.
        let stream = await hub.conversationChanges(sessionID: sessionID, scopeID: scopeID)
        return (subscription, stream)
    }

    /// Unsubscribes.
    ///
    /// Unsubscribing is the real cleanup: once the server is told, it stops
    /// sending frames for this scope. The hub's subscriber is dropped when the
    /// consuming task ends and the stream's termination handler runs.
    public func stop() async {
        guard started else { return }
        started = false
        try? await client.unsubscribeFromConversation(sessionID: sessionID, scopeID: scopeID)
    }
}
