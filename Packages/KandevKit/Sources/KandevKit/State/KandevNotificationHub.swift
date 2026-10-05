import Foundation

/// A change to a task, with the kind of change it was.
///
/// The kind is not decoration. A deletion carries the whole task, so a list that
/// only sees a payload finds the row and patches it in place — and a deleted task
/// patched in place stays on screen forever. Creation looked fine by comparison
/// only because a new task is not in the list yet.
public struct KandevTaskSignal: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The task changed and is still in the list.
        case updated
        /// A task appeared that this list may not have.
        case created
        /// The task is gone and its row must go.
        case deleted
        /// The task left the active list.
        case archived
    }

    public var kind: Kind
    public var update: KandevTaskUpdate

    public init(kind: Kind, update: KandevTaskUpdate) {
        self.kind = kind
        self.update = update
    }
}

/// The one reader of the transport's notification stream.
///
/// An `AsyncStream` hands each value to a single reader, so two screens cannot
/// both consume notifications: whichever iterates first silently takes half the
/// frames. This is the single reader, and it fans out from here.
///
/// It decodes each frame once, at the boundary, and hands subscribers typed
/// values. A subscriber that had to decode its own frames would either duplicate
/// the work or, worse, disagree about what an undecodable frame means.
public actor KandevNotificationHub {
    /// Anything that publishes the transport's notifications.
    public protocol Source: Sendable {
        var notifications: AsyncStream<KandevEnvelope> { get }
    }

    private let source: any Source
    private var pump: Task<Void, Never>?

    private struct ConversationSubscriber {
        let sessionID: String
        let scopeID: String
        let continuation: AsyncStream<KandevConversationChange>.Continuation
    }

    private struct TaskSubscriber {
        let workspaceID: String?
        let continuation: AsyncStream<KandevTaskSignal>.Continuation
    }

    private var conversationSubscribers: [UUID: ConversationSubscriber] = [:]
    private var taskSubscribers: [UUID: TaskSubscriber] = [:]
    private var sessionStateSubscribers: [UUID: AsyncStream<KandevSessionStateChange>.Continuation] = [:]
    private var reconnectSubscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(source: any Source) {
        self.source = source
    }

    /// Begins reading. Safe to call more than once; the second call does nothing,
    /// because a second pump would split the stream with the first.
    public func start() {
        guard pump == nil else { return }
        // The task inherits this actor's isolation, so these are direct calls.
        pump = Task { [source] in
            for await envelope in source.notifications {
                self.dispatch(envelope)
            }
            self.finish()
        }
    }

    public func stop() {
        pump?.cancel()
        pump = nil
        finish()
    }

    /// Changes to one session's conversation, for one subscriber's scope.
    ///
    /// The scope matters: several clients can watch a session, and the server
    /// echoes each one's own scope on the frames it sends that client. Delivering
    /// by session alone would hand a subscriber frames addressed to somebody else.
    public func conversationChanges(
        sessionID: String,
        scopeID: String
    ) -> AsyncStream<KandevConversationChange> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let id = UUID()
            conversationSubscribers[id] = ConversationSubscriber(
                sessionID: sessionID,
                scopeID: scopeID,
                continuation: continuation
            )
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeConversationSubscriber(id) }
            }
        }
    }

    /// Changes to tasks, optionally narrowed to one workspace, each tagged with
    /// what kind of change it was.
    public func taskSignals(workspaceID: String? = nil) -> AsyncStream<KandevTaskSignal> {
        AsyncStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            let id = UUID()
            taskSubscribers[id] = TaskSubscriber(
                workspaceID: workspaceID,
                continuation: continuation
            )
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeTaskSubscriber(id) }
            }
        }
    }

    /// Session state changes.
    ///
    /// Not narrowed by workspace: the frame names its task but not the workspace
    /// it belongs to, so a subscriber matches the task it already holds. Filtering
    /// on a field the frame does not carry would be a filter that never matches.
    public func sessionStateChanges() -> AsyncStream<KandevSessionStateChange> {
        AsyncStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            let id = UUID()
            sessionStateSubscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSessionStateSubscriber(id) }
            }
        }
    }

    /// Fires when the transport has come back after a drop.
    ///
    /// Nothing about the server state can be trusted across a reconnect, because
    /// this client does not replay missed frames. A subscriber's only honest
    /// response is to read again.
    public func reconnects() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            reconnectSubscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeReconnectSubscriber(id) }
            }
        }
    }

    // MARK: - Dispatch

    private func dispatch(_ envelope: KandevEnvelope) {
        // Before the guard below, which requires a payload: this notice is raised by
        // the client rather than sent by the server.
        if envelope.action == KandevClientNotice.reconnected {
            for continuation in reconnectSubscribers.values { continuation.yield(()) }
            return
        }
        guard let action = envelope.action, let payload = envelope.payload else { return }

        switch action {
        case KandevAction.sessionConversationChanged:
            guard let change = decode(payload, as: KandevConversationChange.self) else { return }
            deliver(change)
        case KandevAction.sessionStateChanged:
            guard let change = decode(payload, as: KandevSessionStateChange.self) else { return }
            deliver(change)
        case KandevAction.taskUpdated, KandevAction.taskStateChanged,
             KandevAction.taskStatusSummaryUpdated:
            guard let update = decode(payload, as: KandevTaskUpdate.self) else { return }
            deliver(KandevTaskSignal(kind: .updated, update: update))
        case KandevAction.taskCreated:
            guard let update = decode(payload, as: KandevTaskUpdate.self) else { return }
            deliver(KandevTaskSignal(kind: .created, update: update))
        case KandevAction.taskDeleted:
            guard let update = decode(payload, as: KandevTaskUpdate.self) else { return }
            deliver(KandevTaskSignal(kind: .deleted, update: update))
        case KandevAction.taskArchived:
            guard let update = decode(payload, as: KandevTaskUpdate.self) else { return }
            deliver(KandevTaskSignal(kind: .archived, update: update))
        default:
            // Everything else the server pushes — session state, office updates,
            // agent availability — is not something this app reads yet. Dropping
            // it here is deliberate and visible, rather than each screen deciding.
            return
        }
    }

    private func deliver(_ change: KandevConversationChange) {
        for (id, subscriber) in conversationSubscribers {
            guard subscriber.sessionID == change.sessionID else { continue }
            // A change with no scope is broadcast to whoever is watching; one with
            // a scope belongs to the client it names.
            if let scope = change.scopeID, scope != subscriber.scopeID {
                continue
            }
            if conversationSubscribers[id] != nil {
                subscriber.continuation.yield(change)
            }
        }
    }

    private func deliver(_ signal: KandevTaskSignal) {
        for subscriber in taskSubscribers.values {
            if let wanted = subscriber.workspaceID,
               let came = signal.update.workspaceID,
               wanted != came
            {
                continue
            }
            subscriber.continuation.yield(signal)
        }
    }

    private func deliver(_ change: KandevSessionStateChange) {
        for continuation in sessionStateSubscribers.values {
            continuation.yield(change)
        }
    }

    private func decode<T: Decodable>(_ payload: JSONValue, as type: T.Type) -> T? {
        try? payload.decoded(as: T.self)
    }

    private func removeConversationSubscriber(_ id: UUID) {
        conversationSubscribers.removeValue(forKey: id)
    }

    private func removeTaskSubscriber(_ id: UUID) {
        taskSubscribers.removeValue(forKey: id)
    }

    private func removeReconnectSubscriber(_ id: UUID) {
        reconnectSubscribers.removeValue(forKey: id)
    }

    private func removeSessionStateSubscriber(_ id: UUID) {
        sessionStateSubscribers.removeValue(forKey: id)
    }

    private func finish() {
        for subscriber in conversationSubscribers.values { subscriber.continuation.finish() }
        conversationSubscribers.removeAll()
        for subscriber in taskSubscribers.values { subscriber.continuation.finish() }
        taskSubscribers.removeAll()
        for continuation in sessionStateSubscribers.values { continuation.finish() }
        sessionStateSubscribers.removeAll()
    }
}

extension KandevClient: KandevNotificationHub.Source {}
