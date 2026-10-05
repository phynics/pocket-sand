import Foundation

/// A `KandevTransport` backed by one `URLSessionWebSocketTask`.
///
/// Kandev multiplexes every request and every notification onto a single socket,
/// so this actor owns the demultiplexer: outgoing requests are correlated by the
/// envelope `id`, and everything else is published to `notifications`.
public actor WebSocketTransport: KandevTransport {
    public struct Configuration: Sendable {
        public var baseURL: URL
        /// Personal access token. Only needed when the server has authentication
        /// enabled; a default install has no client authentication boundary.
        public var token: String?
        /// How long to wait for one response before failing that request alone.
        /// The socket stays up, because Kandev sends notifications on the same
        /// connection and one slow action should not kill live output.
        public var requestTimeout: Duration

        public init(
            baseURL: URL,
            token: String? = nil,
            requestTimeout: Duration = .seconds(20)
        ) {
            self.baseURL = baseURL
            self.token = token
            self.requestTimeout = requestTimeout
        }
    }

    public nonisolated let notifications: AsyncStream<KandevEnvelope>

    private let configuration: Configuration
    private let session: URLSession
    private let notificationsContinuation: AsyncStream<KandevEnvelope>.Continuation
    private var socket: URLSessionWebSocketTask?
    private var pump: Task<Void, Never>?

    /// Someone asked this to stop, so a reconnect must not fight them.
    private var isClosed = false
    /// How many attempts the current failure has cost, which sets the next wait.
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?

    /// Requests that have gone out and are not yet resolved.
    private var awaitingResponse: Set<String> = []
    /// Callers parked on a response.
    private var waiters: [String: CheckedContinuation<KandevEnvelope, any Error>] = [:]
    /// Responses that arrived before their caller parked. This is what makes a
    /// response landing mid-`send` safe rather than lost.
    private var unwaiters: [String: Result<KandevEnvelope, any Error>] = [:]

    public init(configuration: Configuration, session: URLSession = .shared) {
        let (stream, continuation) = AsyncStream<KandevEnvelope>.makeStream(
            bufferingPolicy: .bufferingNewest(512)
        )
        self.notifications = stream
        self.notificationsContinuation = continuation
        self.configuration = configuration
        self.session = session
    }

    public func connect() async throws {
        // An explicit connect re-arms a transport that was closed, which is what
        // re-entering a screen does.
        isClosed = false
        guard socket == nil else { return }

        let url = try KandevEndpoint.webSocketURL(
            baseURL: configuration.baseURL,
            token: configuration.token
        )
        var request = URLRequest(url: url)
        // Sent because `URLSession` is not a browser and sends none, while the
        // server's origin gate requires one whenever authentication is on. See
        // `KandevEndpoint.webSocketOrigin`.
        if let origin = KandevEndpoint.webSocketOrigin(baseURL: configuration.baseURL) {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        let task = session.webSocketTask(with: request)
        task.resume()
        socket = task
        pump = Task { [weak self] in
            await self?.receive(from: task)
        }
    }

    public func send(_ envelope: KandevEnvelope) async throws -> KandevEnvelope {
        guard let socket else { throw KandevError.notConnected }
        guard let id = envelope.id else { throw KandevError.missingRequestID }

        // The id is claimed before the frame leaves, so a response that arrives
        // while `send` is suspended lands in `unwaiters` instead of nowhere.
        awaitingResponse.insert(id)

        do {
            let data = try JSONEncoder().encode(envelope)
            try await socket.send(.data(data))
        } catch {
            awaitingResponse.remove(id)
            throw KandevError.transport(error.localizedDescription)
        }

        let timeout = configuration.requestTimeout
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expire(id, action: envelope.action ?? "")
        }
        defer { expiry.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            if let landed = unwaiters.removeValue(forKey: id) {
                continuation.resume(with: landed)
            } else {
                waiters[id] = continuation
            }
        }
    }

    public func close() async {
        isClosed = true
        reconnectTask?.cancel()
        reconnectTask = nil
        tearDown(sending: .connectionClosed, endingStream: true)
    }

    // MARK: - Receiving

    private func receive(from task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            let frame: URLSessionWebSocketTask.Message
            do {
                frame = try await task.receive()
            } catch {
                connectionDropped()
                return
            }

            guard let data = frame.jsonData else { continue }
            guard let envelope = try? JSONDecoder().decode(KandevEnvelope.self, from: data) else {
                // An unreadable frame is a protocol surprise, not a dead
                // connection: surface it and keep the socket up, because tearing
                // down live agent output over one bad frame is worse.
                notificationsContinuation.yield(
                    KandevEnvelope(
                        type: .notification,
                        action: KandevClientNotice.undecodableFrame,
                        payload: .string(String(decoding: data, as: UTF8.self))
                    )
                )
                continue
            }
            deliver(envelope)
        }
    }

    private func deliver(_ envelope: KandevEnvelope) {
        guard envelope.type == .response || envelope.type == .error,
              let id = envelope.id,
              awaitingResponse.remove(id) != nil
        else {
            // Either a push, or a late answer to a request that already timed out.
            // Nothing is parked on it, but the data is still worth seeing.
            notificationsContinuation.yield(envelope)
            return
        }
        settle(id, with: Self.outcome(for: envelope))
    }

    private static func outcome(
        for envelope: KandevEnvelope
    ) -> Result<KandevEnvelope, any Error> {
        if let failure = KandevFailure.failure(in: envelope) {
            return .failure(failure)
        }
        return .success(envelope)
    }

    // MARK: - Resolution

    private func settle(_ id: String, with outcome: Result<KandevEnvelope, any Error>) {
        guard let waiter = waiters.removeValue(forKey: id) else {
            unwaiters[id] = outcome
            return
        }
        waiter.resume(with: outcome)
    }

    private func expire(_ id: String, action: String) {
        guard awaitingResponse.remove(id) != nil else { return }
        settle(id, with: .failure(KandevError.timedOut(action: action)))
    }

    // MARK: - Reconnecting

    /// The socket went away without anyone asking.
    ///
    /// A phone loses its socket constantly — the screen locks, the network changes,
    /// the app is suspended — and a client that gives up on the first drop is dead
    /// until it is restarted. So this fails what was in flight and tries again.
    private func connectionDropped() {
        tearDown(sending: .connectionClosed, endingStream: false)
        guard !isClosed else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }

        let delay = ReconnectBackoff.delay(forAttempt: reconnectAttempt)
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.reconnect()
        }
    }

    private func reconnect() async {
        reconnectTask = nil
        guard !isClosed, socket == nil else { return }

        do {
            try await connect()
            reconnectAttempt = 0
            // Said out loud, because a socket that was down may have missed frames
            // and this client does not replay them: anything holding server state
            // has to read it again rather than trust what it has.
            notificationsContinuation.yield(
                KandevEnvelope(
                    type: .notification,
                    action: KandevClientNotice.reconnected,
                    payload: .null
                )
            )
        } catch {
            scheduleReconnect()
        }
    }

    /// Fails everything in flight, and optionally ends the notification stream.
    ///
    /// The two are separate because they belong to different events. A dropped
    /// socket fails the requests that were waiting on it; only an explicit close
    /// ends the stream, because the stream is the app's single consumer of
    /// notifications and finishing it would leave a reconnected socket with nowhere
    /// to deliver.
    private func tearDown(sending error: KandevError, endingStream: Bool) {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        pump?.cancel()
        pump = nil

        let parked = waiters.values
        waiters.removeAll()
        unwaiters.removeAll()
        awaitingResponse.removeAll()
        for waiter in parked {
            waiter.resume(throwing: error)
        }

        if endingStream { notificationsContinuation.finish() }
    }
}

/// Notices this client raises about itself, namespaced so they cannot be confused
/// with an action the server sent.
public enum KandevClientNotice {
    public static let undecodableFrame = "client.undecodableFrame"
    /// Raised by this client after a dropped socket comes back.
    public static let reconnected = "client.reconnected"
}

private extension URLSessionWebSocketTask.Message {
    /// Kandev writes JSON in text frames. Binary is accepted because the server's
    /// reader ignores the distinction, so a proxy may deliver either.
    var jsonData: Data? {
        switch self {
        case .string(let text): Data(text.utf8)
        case .data(let data): data
        @unknown default: nil
        }
    }
}
