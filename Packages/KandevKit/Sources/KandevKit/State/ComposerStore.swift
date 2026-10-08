import Foundation
import Observation

/// What the composer needs from a server.
public protocol KandevPromptSource: Sendable {
    func sendPrompt(
        _ content: String,
        sessionID: String,
        taskID: String,
        sessionIncarnationID: String,
        clientQueueID: String?
    ) async throws -> KandevQueuedPrompt

    func queue(
        sessionID: String,
        taskID: String,
        sessionIncarnationID: String
    ) async throws -> KandevQueueSnapshot

    func sendQueuedNow(
        sessionID: String,
        taskID: String,
        sessionIncarnationID: String,
        entryID: String?
    ) async throws -> KandevSendNowResult

    func clearQueue(
        sessionID: String,
        taskID: String,
        sessionIncarnationID: String
    ) async throws

    func stopTurn(sessionID: String) async throws
}

extension KandevClient: KandevPromptSource {}

/// Writing to a conversation: a draft, a queue, and a running turn.
///
/// The composer cannot send until it holds a session's identity, because a prompt
/// needs the session's incarnation id. So this type does nothing at all until
/// something hands it one — which is why `bind` exists and why the queue cannot
/// be read before then.
@MainActor
@Observable
public final class ComposerStore {
    /// The three ids every prompt-bearing action requires.
    public struct Identity: Sendable, Equatable {
        public var taskID: String
        public var sessionID: String
        public var sessionIncarnationID: String

        public init(taskID: String, sessionID: String, sessionIncarnationID: String) {
            self.taskID = taskID
            self.sessionID = sessionID
            self.sessionIncarnationID = sessionIncarnationID
        }
    }

    public enum Phase: Equatable {
        case idle
        case sending
        case failed(String)
        /// The session's queue is at capacity. A state, not an error: it clears as
        /// the agent finishes each prompt.
        case full(limit: Int)
    }

    /// The draft, bound to the text field.
    public var draft: String = ""

    public private(set) var phase: Phase = .idle
    public private(set) var queue: KandevQueueSnapshot?
    public private(set) var identity: Identity?
    /// What the server says this caller may do. Prompting without
    /// `canPrompt` is a request the server will refuse, so it is not offered.
    public private(set) var permissions: ConversationPermissions = .default

    private let source: any KandevPromptSource
    private let makeQueueID: @Sendable () -> String

    public init(
        source: any KandevPromptSource,
        makeQueueID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.source = source
        self.makeQueueID = makeQueueID
    }

    public var queuedPrompts: [KandevQueuedPrompt] { queue?.entries ?? [] }

    public var queuedCount: Int { queue?.count ?? 0 }

    /// True when the server has said the queue is full, whether from its snapshot
    /// or from a rejected prompt.
    public var isQueueFull: Bool {
        if case .full = phase { return true }
        return queue?.isFull ?? false
    }

    /// Whether the draft has anything in it that would be sent.
    public var draftIsEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether there is anything to send, somewhere to send it, and permission
    /// to send it.
    public var canSend: Bool {
        guard identity != nil, phase != .sending, !isQueueFull else { return false }
        guard permissions.canPrompt else { return false }
        return !draftIsEmpty
    }

    /// What the one button beside the field does.
    ///
    /// Three states in one place. Two buttons competed for the width the field needs,
    /// and they asked a question with no good answer — stop the turn or send the
    /// prompt — when at any moment only one of the two is what you mean.
    public enum Action: Equatable, Sendable {
        /// Send the draft. What an idle conversation offers, and what a typed word
        /// offers while the agent works: a prompt sent during a run is queued, not
        /// refused.
        case send
        /// Stop the running turn.
        case stopTurn
        /// Interrupt the running turn and send the waiting prompt now.
        case sendQueuedNow
    }

    /// Which of the three, given whether a turn is running.
    ///
    /// A draft outranks everything: with words in the field, the thing you are doing is
    /// sending them, and a stop button in their place is a button that cancels work
    /// when you meant to answer it. Then the queue, because a prompt already waiting
    /// is what "send again" means — one tap to put it ahead of the turn instead of the
    /// agent's current work.
    public func action(turnIsRunning: Bool) -> Action {
        if !draftIsEmpty { return .send }
        if turnIsRunning, !queuedPrompts.isEmpty { return .sendQueuedNow }
        if turnIsRunning, canStopTurn { return .stopTurn }
        return .send
    }

    /// Whether stopping is on offer. Cancelling agent work is a stronger right
    /// than prompting, and the server reports it separately.
    public var canStopTurn: Bool {
        identity != nil && permissions.canControlSessions
    }

    /// Points the composer at a session and reads that session's queue.
    public func bind(
        _ identity: Identity?,
        permissions: ConversationPermissions = .default
    ) async {
        self.permissions = permissions
        guard self.identity != identity else { return }
        self.identity = identity
        queue = nil
        phase = .idle
        await refreshQueue()
    }

    /// Sends the draft.
    ///
    /// Enqueues: with the server's default auto-run an idle session is dispatched
    /// immediately, but the promise is only that the prompt was accepted.
    /// Returns whether it was, so a caller can decide to refetch.
    @discardableResult
    public func send() async -> Bool {
        guard let identity, canSend else { return false }
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .sending
        do {
            _ = try await source.sendPrompt(
                content,
                sessionID: identity.sessionID,
                taskID: identity.taskID,
                sessionIncarnationID: identity.sessionIncarnationID,
                clientQueueID: makeQueueID()
            )
            // Cleared only after the server accepts it: losing what someone typed
            // because a request failed is the worst outcome here.
            draft = ""
            phase = .idle
            await refreshQueue()
            return true
        } catch let error as KandevError {
            if case .queueFull(let limit) = error {
                phase = .full(limit: limit)
            } else {
                phase = .failed(KandevError.readableMessage(for: error))
            }
            return false
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }
    }

    /// Interrupts the running turn and sends a queued prompt.
    ///
    /// `entryID` names one; passing `nil` sends every queued prompt. This cancels
    /// the agent's current work, which is why it is not what `send` does.
    @discardableResult
    public func interruptAndSend(entryID: String? = nil) async -> Bool {
        guard let identity else { return false }
        phase = .sending
        do {
            _ = try await source.sendQueuedNow(
                sessionID: identity.sessionID,
                taskID: identity.taskID,
                sessionIncarnationID: identity.sessionIncarnationID,
                entryID: entryID
            )
            phase = .idle
            await refreshQueue()
            return true
        } catch let error as KandevError {
            phase = .failed(KandevError.readableMessage(for: error))
            return false
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }
    }

    /// Drops every queued prompt.
    @discardableResult
    public func clearQueue() async -> Bool {
        guard let identity else { return false }
        do {
            try await source.clearQueue(
                sessionID: identity.sessionID,
                taskID: identity.taskID,
                sessionIncarnationID: identity.sessionIncarnationID
            )
            await refreshQueue()
            return true
        } catch {
            phase = .failed(KandevError.readableMessage(for: error))
            return false
        }
    }

    /// Stops the running turn. The conversation survives; the work does not.
    @discardableResult
    public func stopTurn() async -> Bool {
        guard let identity else { return false }
        do {
            try await source.stopTurn(sessionID: identity.sessionID)
            return true
        } catch {
            phase = .failed(KandevError.readableMessage(for: error))
            return false
        }
    }

    /// Reads the queue. A failure here is not worth interrupting the user over:
    /// the queue is context, and the next attempt will pick it up.
    public func refreshQueue() async {
        guard let identity else { return }
        queue = try? await source.queue(
            sessionID: identity.sessionID,
            taskID: identity.taskID,
            sessionIncarnationID: identity.sessionIncarnationID
        )
        if queue?.isFull == true, let limit = queue?.max {
            phase = .full(limit: limit)
        } else if case .full = phase {
            // Room again, so stop explaining the limit.
            phase = .idle
        }
    }
}
