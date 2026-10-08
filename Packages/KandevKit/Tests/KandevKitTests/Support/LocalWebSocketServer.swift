import Foundation
import Network
import Synchronization

@testable import KandevKit

/// A WebSocket server inside the test process. Only loopback peers are served; see
/// `isLoopback` for why the listener is not bound to `127.0.0.1` directly.
///
/// Most of the transport can be tested against a stub. The reconnect path cannot: it
/// is about a socket that really drops, a server that really goes away, and a port
/// that really comes back, and only a real socket does all three.
///
/// Every piece of mutable state is confined to `queue`. Network.framework calls back on
/// that queue and each public method hops onto it, so there is no lock to get wrong.
final class LocalWebSocketServer: @unchecked Sendable {
    /// Answers one request frame, or returns nil to stay silent about it.
    typealias Responder = @Sendable (KandevEnvelope) -> KandevEnvelope?

    enum Failure: Error {
        case listenerFailed(String)
        case neverStarted
    }

    private let queue = DispatchQueue(label: "LocalWebSocketServer")
    private let responder: Responder
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    /// Every connection ever accepted, so a test can see that a reconnect happened.
    private var accepted = 0
    /// The port the first listen bound, so `restart` can come back on the same one.
    private var port: NWEndpoint.Port?

    init(responder: @escaping Responder) {
        self.responder = responder
    }

    /// Binds an ephemeral port and returns the base URL a transport should be given.
    func start() async throws -> URL {
        try await listen(on: nil)
    }

    /// Cuts every live connection without stopping the listener, which is what a
    /// network blip looks like from the client.
    func dropAllConnections() async {
        await onQueue {
            for connection in self.connections { connection.cancel() }
            self.connections.removeAll()
        }
    }

    /// Stops listening and cuts every connection: the server is gone.
    func stop() async {
        await onQueue {
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections { connection.cancel() }
            self.connections.removeAll()
        }
    }

    /// Listens again on the port the server first bound, so a reconnect can reach it.
    func restart() async throws {
        guard let port = await onQueue({ self.port }) else { throw Failure.neverStarted }
        _ = try await listen(on: port)
    }

    /// How many connections have been accepted over the server's whole life.
    func connectionCount() async -> Int {
        await onQueue { self.accepted }
    }

    // MARK: - Listening

    @discardableResult
    private func listen(on requested: NWEndpoint.Port?) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
            queue.async {
                let parameters = NWParameters.tcp
                let websocket = NWProtocolWebSocket.Options()
                websocket.autoReplyPing = true
                parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
                parameters.allowLocalEndpointReuse = true

                let listener: NWListener
                do {
                    listener = try NWListener(using: parameters, on: requested ?? .any)
                } catch {
                    continuation.resume(throwing: Failure.listenerFailed(error.localizedDescription))
                    return
                }

                // The listener may report `.ready` and later `.failed`, but the continuation
                // resumes once. This flag is claimed by whichever outcome arrives first.
                let settled = OneShot()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard settled.claim() else { return }
                        guard let bound = listener.port else {
                            continuation.resume(throwing: Failure.listenerFailed("no port bound"))
                            return
                        }
                        self.port = bound
                        continuation.resume(returning: URL(string: "http://127.0.0.1:\(bound.rawValue)")!)
                    case .failed(let error):
                        guard settled.claim() else { return }
                        continuation.resume(throwing: Failure.listenerFailed(error.localizedDescription))
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { connection in
                    guard Self.isLoopback(connection.endpoint) else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection)
                }
                self.listener = listener
                listener.start(queue: self.queue)
            }
        }
    }

    // MARK: - Connections

    /// Network.framework refuses a required local endpoint on a fixed port, and
    /// restarting on the same port is the point of `restart`. So the listener binds
    /// every interface and refuses any peer that is not on loopback, which keeps the
    /// server reachable only from this machine.
    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        default: return false
        }
    }

    private func accept(_ connection: NWConnection) {
        accepted += 1
        connections.append(connection)
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                self.connections.removeAll { $0 === connection }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    /// Reads one message at a time and answers it, until the connection ends.
    private func receive(on connection: NWConnection) {
        connection.receiveMessage { content, context, _, error in
            // An error is how a closed connection ends its own receive loop.
            guard error == nil else { return }
            if let metadata = context?.protocolMetadata(
                definition: NWProtocolWebSocket.definition
            ) as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .close:
                    return
                case .text, .binary:
                    if let content { self.answer(content, on: connection) }
                default:
                    break
                }
            }
            self.receive(on: connection)
        }
    }

    private func answer(_ content: Data, on connection: NWConnection) {
        guard let request = try? JSONDecoder().decode(KandevEnvelope.self, from: content),
              let reply = responder(request),
              let data = try? JSONEncoder().encode(reply)
        else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "reply", metadata: [metadata])
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .idempotent
        )
    }

    // MARK: - Hopping onto the queue

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

/// Answers `true` exactly once. A listener can report `.ready` and later `.failed`, and a
/// checked continuation may resume only once, so the first outcome to arrive claims it.
private final class OneShot: Sendable {
    private let taken = Mutex(false)

    func claim() -> Bool {
        taken.withLock { done -> Bool in
            if done { return false }
            done = true
            return true
        }
    }
}
