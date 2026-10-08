import Foundation
import Synchronization
import Testing

@testable import KandevKit

/// The transport's reconnect path, over a real socket.
///
/// A socket that drops is the one thing a stub cannot do, so each test runs a WebSocket
/// server in-process and cuts the connection itself. The request timeout is short, so a
/// broken test fails in seconds instead of hanging. Nothing here waits unbounded.
@Suite("WebSocketTransport", .serialized)
struct WebSocketTransportTests {
    /// What the server saw and what the transport announced. Written from the callbacks
    /// that produce it, read by the test when it polls.
    private final class Probe: Sendable {
        let requestActions = Mutex<[String]>([])
        let notices = Mutex<[String]>([])
        let streamEnded = Mutex(false)

        func sawRequest(_ action: String) -> Bool {
            requestActions.withLock { $0.contains(action) }
        }

        func sawNotice(_ action: String) -> Bool {
            notices.withLock { $0.contains(action) }
        }
    }

    private struct Harness {
        let server: LocalWebSocketServer
        let transport: WebSocketTransport
        let probe: Probe
    }

    /// Echoes every request back as a response, except the actions it was told to
    /// ignore. A silent action is how a test holds a request open on purpose.
    private func echo(silentActions: Set<String>, probe: Probe) -> LocalWebSocketServer.Responder {
        { request in
            probe.requestActions.withLock { $0.append(request.action ?? "") }
            guard request.type == .request else { return nil }
            guard !silentActions.contains(request.action ?? "") else { return nil }
            return KandevEnvelope(
                id: request.id,
                type: .response,
                action: request.action,
                payload: .object(["ok": .bool(true)])
            )
        }
    }

    /// Starts a server and a transport against it, connects, and waits until the
    /// server has accepted the socket, so a test never drops a connection that does
    /// not exist yet. Everything is torn down afterwards, pass or fail, so a failed
    /// expectation cannot leave a reconnect loop running.
    private func withHarness(
        silentActions: Set<String> = [],
        _ body: (Harness) async throws -> Void
    ) async throws {
        let probe = Probe()
        let server = LocalWebSocketServer(responder: echo(silentActions: silentActions, probe: probe))
        let baseURL = try await server.start()
        let transport = WebSocketTransport(
            configuration: .init(baseURL: baseURL, requestTimeout: .seconds(2))
        )

        // The stream has one consumer, as the rule in AGENTS.md requires. Everything a
        // test learns about the transport's announcements comes through here.
        let consumer = Task {
            for await envelope in transport.notifications {
                probe.notices.withLock { $0.append(envelope.action ?? "") }
            }
            probe.streamEnded.withLock { $0 = true }
        }

        do {
            try await transport.connect()
            let accepted = await eventually(within: .seconds(2)) {
                await server.connectionCount() == 1
            }
            guard accepted else {
                throw Failure.neverAccepted
            }
            try await body(Harness(server: server, transport: transport, probe: probe))
        } catch {
            await teardown(transport: transport, server: server, consumer: consumer)
            throw error
        }
        await teardown(transport: transport, server: server, consumer: consumer)
    }

    private enum Failure: Error {
        case neverAccepted
    }

    private func teardown(transport: WebSocketTransport, server: LocalWebSocketServer, consumer: Task<Void, Never>) async {
        await transport.close()
        await server.stop()
        consumer.cancel()
    }

    /// Polls until the condition holds or the deadline passes. The return value is the
    /// outcome, so a timeout reads as a failed expectation rather than a hang.
    private func eventually(
        within timeout: Duration,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    // MARK: - Round trip

    @Test("a request is answered by the response carrying its id")
    func roundTrip() async throws {
        try await withHarness { harness in
            let request = KandevEnvelope.request(action: "task.get", payload: .object(["id": .string("t1")]))
            let response = try await harness.transport.send(request)

            #expect(response.type == .response)
            #expect(response.id == request.id)
            #expect(response.action == "task.get")
            #expect(response.payload == .object(["ok": .bool(true)]))
        }
    }

    // MARK: - A drop fails what was waiting

    /// A socket that drops with a request parked on it must fail that request now, not
    /// leave it to the timeout. `connectionClosed` is what the caller can act on.
    @Test("a dropped socket fails the request that was waiting")
    func dropFailsParkedRequest() async throws {
        try await withHarness(silentActions: ["slow.action"]) { harness in
            let request = KandevEnvelope.request(action: "slow.action")
            let pending = Task { try await harness.transport.send(request) }

            // Only drop once the server has the request, so the request is genuinely in
            // flight and not refused for having been sent on a dead socket.
            let arrived = await eventually(within: .seconds(2)) {
                harness.probe.sawRequest("slow.action")
            }
            #expect(arrived, "the request never reached the server")

            await harness.server.dropAllConnections()

            await #expect(throws: KandevError.connectionClosed) {
                _ = try await pending.value
            }
        }
    }

    // MARK: - Reconnecting

    /// After a drop the transport retries on its own, and says so once a ping has
    /// proved the new socket reaches a server. A fresh request then round-trips on it.
    @Test("a dropped socket reconnects and says so")
    func reconnectAnnounces() async throws {
        try await withHarness { harness in
            await harness.server.dropAllConnections()

            let announced = await eventually(within: .seconds(3)) {
                harness.probe.sawNotice(KandevClientNotice.reconnected)
            }
            #expect(announced, "no reconnect notice within the first backoff window")
            #expect(await harness.server.connectionCount() == 2)

            let request = KandevEnvelope.request(action: "task.get")
            let response = try await harness.transport.send(request)
            #expect(response.id == request.id)
        }
    }

    /// A reconnect that cannot reach the server must stay quiet. The old failure mode was a
    /// "reconnected" on every attempt, which told subscribers to refetch from a server that
    /// was not there. The notice is therefore asserted absent during the outage, then present
    /// once the server returns.
    @Test("a reconnect to a server that is down does not announce itself")
    func downServerIsNotAnnounced() async throws {
        try await withHarness { harness in
            // `stop` cuts the live socket too, so this is both the drop and the outage.
            await harness.server.stop()

            // Long enough for the 0.5s and 1s attempts to fail while the server is down.
            try await Task.sleep(for: .milliseconds(1800))
            #expect(!harness.probe.sawNotice(KandevClientNotice.reconnected),
                    "a reconnect was announced while the server was down")

            try await harness.server.restart()

            // The next attempt lands at about 3.5s cumulative, so about 1.7s after the
            // restart. Nine seconds allows the one after it as well.
            let announced = await eventually(within: .seconds(9)) {
                harness.probe.sawNotice(KandevClientNotice.reconnected)
            }
            #expect(announced, "the transport never came back once the server returned")
        }
    }

    /// After `close`, the stream ends and no reconnect is scheduled. A reconnect that
    /// survived close would show up as a socket the server accepted after it.
    @Test("close ends the stream and stops reconnecting")
    func closeStopsEverything() async throws {
        try await withHarness { harness in
            await harness.server.dropAllConnections()
            let announced = await eventually(within: .seconds(3)) {
                harness.probe.sawNotice(KandevClientNotice.reconnected)
            }
            #expect(announced)
            #expect(await harness.server.connectionCount() == 2)

            // Drop the live socket and close straight away. Whichever the transport sees
            // first, the retry must not happen.
            await harness.server.dropAllConnections()
            await harness.transport.close()

            let ended = await eventually(within: .seconds(2)) {
                harness.probe.streamEnded.withLock { $0 }
            }
            #expect(ended, "the notifications stream did not finish after close")

            try await Task.sleep(for: .milliseconds(1500))
            #expect(await harness.server.connectionCount() == 2,
                    "the transport reconnected after it was closed")
        }
    }
}
