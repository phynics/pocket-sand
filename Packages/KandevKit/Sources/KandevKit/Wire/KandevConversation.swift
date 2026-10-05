import Foundation

/// The answer to `session.conversation.subscribe`.
///
/// A handshake, not just an acknowledgement: it names the conversation log
/// (`epoch`) and where the log had got to (`revision`). Every later change says
/// which revision it builds on, which is how a gap is detected instead of
/// silently rendering a conversation with a hole in it.
public struct KandevConversationSubscription: Sendable, Decodable, Equatable {
    public var success: Bool?
    public var protocolVersion: Int?
    public var scopeID: String?
    public var sessionID: String?
    public var epoch: String?
    public var revision: String?

    public enum CodingKeys: String, CodingKey {
        case success, epoch, revision
        case protocolVersion = "protocol_version"
        case scopeID = "scope_id"
        case sessionID = "session_id"
    }

    public init(
        success: Bool?,
        protocolVersion: Int?,
        scopeID: String?,
        sessionID: String?,
        epoch: String?,
        revision: String?
    ) {
        self.success = success
        self.protocolVersion = protocolVersion
        self.scopeID = scopeID
        self.sessionID = sessionID
        self.epoch = epoch
        self.revision = revision
    }
}

/// One change to a conversation.
///
/// Verified against a live v0.96.0 server by subscribing to a session and driving
/// a real agent turn. The whole turn arrived as one change per message:
///
///     revision 9  turn upsert      (started)
///     revision 10 message upsert   (the prompt)
///     revision 11 message upsert   (agent thinking, content still empty)
///     revision 12 message upsert   (the reply)
///     revision 13 turn upsert      (completed, had_output)
///     revision 13 check, no ops    (heartbeat, every ~5s)
public struct KandevConversationChange: Sendable, Decodable, Equatable {
    public var protocolVersion: Int?
    public var scopeID: String?
    public var sessionID: String?
    public var epoch: String?
    /// The revision this change expects the reader to already hold.
    public var baseRevision: String?
    /// The revision the reader holds once the operations are applied.
    public var revision: String?
    /// A liveness probe. Carries no operations and proves only that the
    /// subscription is still alive, so it must not be mistaken for a change.
    public var check: Bool?
    public var operations: [KandevConversationOperation]

    public enum CodingKeys: String, CodingKey {
        case epoch, revision, check, operations
        case protocolVersion = "protocol_version"
        case scopeID = "scope_id"
        case sessionID = "session_id"
        case baseRevision = "base_revision"
    }

    public init(
        protocolVersion: Int? = nil,
        scopeID: String? = nil,
        sessionID: String? = nil,
        epoch: String? = nil,
        baseRevision: String? = nil,
        revision: String? = nil,
        check: Bool? = nil,
        operations: [KandevConversationOperation] = []
    ) {
        self.protocolVersion = protocolVersion
        self.scopeID = scopeID
        self.sessionID = sessionID
        self.epoch = epoch
        self.baseRevision = baseRevision
        self.revision = revision
        self.check = check
        self.operations = operations
    }
}

/// One operation in a change: an upsert of a message or a turn.
public struct KandevConversationOperation: Sendable, Decodable, Equatable {
    public enum Entity: String, Sendable, Decodable {
        case message
        case turn
    }

    /// `message` or `turn`. Kept as a string so an entity this client does not
    /// know is a value to handle, not a decode failure.
    public var entity: String
    public var id: String
    /// `upsert` in every operation observed on a live server.
    public var kind: String
    public var message: KandevMessage?
    public var turn: KandevTurn?

    public var knownEntity: Entity? { Entity(rawValue: entity) }

    public init(
        entity: String,
        id: String,
        kind: String,
        message: KandevMessage? = nil,
        turn: KandevTurn? = nil
    ) {
        self.entity = entity
        self.id = id
        self.kind = kind
        self.message = message
        self.turn = turn
    }
}

/// A turn, as the conversation log reports it.
public struct KandevTurn: Sendable, Decodable, Equatable, Identifiable {
    public var id: String
    public var startedAt: KandevTimestamp?
    public var completedAt: KandevTimestamp?
    /// Whether the turn produced anything. A completed turn without output is
    /// not a failure, and the two must not be conflated.
    public var hadOutput: Bool?
    /// Opaque: runtime configuration snapshots live here and are large.
    public var metadata: JSONValue?

    public enum CodingKeys: String, CodingKey {
        case id, metadata
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case hadOutput = "had_output"
    }
}

/// What to do with an arriving change.
public enum KandevConversationChangeDecision: Sendable, Equatable {
    /// A heartbeat, another session's change, or another client's. Do nothing.
    case ignore
    /// Apply these operations, then hold this revision.
    case apply(operations: [KandevConversationOperation], revision: String)
    /// The stream cannot be trusted: refetch the conversation.
    case refetch(reason: String)
}

extension KandevConversationChange {
    /// Decides the fate of a change, given where the reader had got to.
    ///
    /// The rules, in order, and each one earns its place:
    ///
    /// - Not this session, or not this subscription: ignore. Several clients can
    ///   watch one session and the server sends each its own scope.
    /// - A heartbeat: ignore. It carries `check: true` and no operations.
    /// - A different epoch: the conversation log was replaced, so nothing held is
    ///   valid any more.
    /// - A base revision the reader has not reached: a change was missed, and
    ///   applying this one would leave a silent hole.
    /// - An unknown entity or kind: refetch rather than guess.
    public func decision(
        expectedScopeID: String,
        expectedSessionID: String,
        appliedEpoch: String?,
        appliedRevision: String?
    ) -> KandevConversationChangeDecision {
        if let scopeID, scopeID != expectedScopeID {
            return .ignore
        }
        if let sessionID, sessionID != expectedSessionID {
            return .ignore
        }
        if check == true && operations.isEmpty {
            return .ignore
        }
        guard let revision, !revision.isEmpty else {
            return .refetch(reason: "a change arrived without a revision")
        }
        if let epoch, let appliedEpoch, epoch != appliedEpoch {
            return .refetch(reason: "the conversation log was replaced")
        }
        // The reader holds nothing yet only before its first handshake; a change
        // that arrives first is applied from wherever the server says it starts.
        if let appliedRevision, let baseRevision, baseRevision != appliedRevision {
            return .refetch(reason: "a change was missed")
        }
        for operation in operations {
            guard operation.knownEntity != nil, operation.kind == "upsert" else {
                return .refetch(reason: "an operation of a kind this client does not know")
            }
        }
        return .apply(operations: operations, revision: revision)
    }
}
