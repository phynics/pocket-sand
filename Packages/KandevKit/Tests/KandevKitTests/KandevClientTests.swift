import Foundation
import Testing

@testable import KandevKit

/// A transport that answers from a script and keeps every frame it was sent.
///
/// The point is to assert the *outgoing* payload shape. A real server taught us
/// which keys a prompt needs, so a test that pins those keys fails loudly if
/// someone later "tidies" a field name.
actor RecordingTransport: KandevTransport {
    nonisolated let notifications: AsyncStream<KandevEnvelope>

    private let continuation: AsyncStream<KandevEnvelope>.Continuation
    private var replies: [String: JSONValue]
    private(set) var sent: [KandevEnvelope] = []

    init(replies: [String: JSONValue] = [:]) {
        let (stream, continuation) = AsyncStream<KandevEnvelope>.makeStream()
        self.notifications = stream
        self.continuation = continuation
        self.replies = replies
    }

    func connect() async throws {}

    func send(_ envelope: KandevEnvelope) async throws -> KandevEnvelope {
        sent.append(envelope)
        let payload = replies[envelope.action ?? ""] ?? .object([:])
        return KandevEnvelope(
            id: envelope.id,
            type: .response,
            action: envelope.action,
            payload: payload
        )
    }

    func close() async {}

    func lastRequest() -> KandevEnvelope? { sent.last }
}

@Suite("KandevClient")
struct KandevClientTests {
    private func client(
        replies: [String: JSONValue] = [:]
    ) -> (KandevClient, RecordingTransport) {
        let transport = RecordingTransport(replies: replies)
        let client = KandevClient(
            transport: transport,
            http: KandevHTTPClient(configuration: .init(baseURL: URL(string: "http://localhost")!))
        )
        return (client, transport)
    }

    /// The exact payload a live server demanded. It named all four keys at once,
    /// so a missing one is not discoverable by iterating — only by testing.
    @Test("a prompt carries the four keys the server requires")
    func promptPayloadShape() async throws {
        let (client, transport) = client(replies: [
            KandevAction.messageQueueAdd: .object([
                "id": .string("queued-1"),
                "content": .string("hello"),
                "position": .integer(1),
                "queued_at": .string("2026-10-04T18:25:29.263302437Z"),
                "queued_by": .string("user"),
                "session_id": .string("s1"),
                "task_id": .string("t1"),
            ])
        ])

        let queued = try await client.sendPrompt(
            "hello",
            sessionID: "s1",
            taskID: "t1",
            sessionIncarnationID: "inc-1"
        )

        #expect(queued.id == "queued-1")
        #expect(queued.position == 1)
        #expect(queued.queuedBy == "user")
        #expect(queued.queuedAt?.date != nil)

        let request = try #require(await transport.lastRequest())
        #expect(request.action == "message.queue.add")
        #expect(request.type == .request)
        let payload = try #require(request.payload)
        #expect(payload["session_id"] == .string("s1"))
        #expect(payload["task_id"] == .string("t1"))
        #expect(payload["session_incarnation_id"] == .string("inc-1"))
        #expect(payload["content"] == .string("hello"))
    }

    @Test("a prompt that is rejected throws rather than reporting an empty queue entry")
    func promptRejectionThrows() async throws {
        let transport = RecordingTransport()
        await transport.setReply(
            for: KandevAction.messageQueueAdd,
            to: .object([
                "success": .bool(false),
                "error": .object([
                    "code": .string("invalid_request"),
                    "message": .string("session_incarnation_id does not match"),
                    "retryable": .bool(false),
                ]),
            ])
        )
        let client = KandevClient(
            transport: transport,
            http: KandevHTTPClient(configuration: .init(baseURL: URL(string: "http://localhost")!))
        )

        await #expect(throws: (any Error).self) {
            _ = try await client.sendPrompt(
                "hello",
                sessionID: "s1",
                taskID: "t1",
                sessionIncarnationID: "stale"
            )
        }
    }

    @Test("stopping a turn sends only the session id")
    func stopPayloadShape() async throws {
        let (client, transport) = client()

        try await client.stopTurn(sessionID: "s1")

        let request = try #require(await transport.lastRequest())
        #expect(request.action == "session.stop")
        #expect(request.payload?["session_id"] == .string("s1"))
    }

    @Test("launching a session sends the task and the profile")
    func launchPayloadShape() async throws {
        let (client, transport) = client(replies: [
            KandevAction.sessionLaunch: .object([
                "success": .bool(true),
                "session_id": .string("s9"),
                "task_id": .string("t1"),
                "state": .string("STARTING"),
            ])
        ])

        let launch = try await client.launchSession(taskID: "t1", agentProfileID: "profile-1")

        #expect(launch.sessionID == "s9")
        #expect(launch.state == "STARTING")
        let request = try #require(await transport.lastRequest())
        #expect(request.payload?["task_id"] == .string("t1"))
        #expect(request.payload?["agent_profile_id"] == .string("profile-1"))
    }
}

extension RecordingTransport {
    func setReply(for action: String, to payload: JSONValue) {
        replies[action] = payload
    }
}

@Suite("KandevTaskListQuery")
struct KandevTaskListQueryTests {
    private func value(_ items: [URLQueryItem], _ name: String) -> String? {
        items.first { $0.name == name }?.value
    }

    @Test("clamps page size to the server's maximum instead of letting it be rejected")
    func clampsPageSize() {
        let items = KandevTaskListQuery(pageSize: 5000).queryItems

        #expect(value(items, "page_size") == "100")
    }

    @Test("omits parameters it was not given rather than sending empty ones")
    func omitsEmptyParameters() {
        let items = KandevTaskListQuery().queryItems

        #expect(value(items, "page") == nil)
        #expect(value(items, "query") == nil)
        #expect(value(items, "workflow_id") == nil)
        // exclude_config defaults to on, so it is always present by design.
        #expect(value(items, "exclude_config") == "true")
    }

    @Test("maps archive modes onto the server's pair of flags")
    func archiveModes() {
        let active = KandevTaskListQuery(archived: .active).queryItems.map(\.name)
        #expect(!active.contains("include_archived"))
        #expect(!active.contains("only_archived"))

        #expect(value(KandevTaskListQuery(archived: .includingArchived).queryItems, "include_archived") == "true")
        #expect(value(KandevTaskListQuery(archived: .onlyArchived).queryItems, "only_archived") == "true")
    }

    @Test("sends the sort the server actually recognises")
    func sortValues() {
        for sort in KandevTaskSort.allCases {
            let items = KandevTaskListQuery(sort: sort).queryItems
            #expect(value(items, "sort") == sort.rawValue)
        }
    }

    /// The server hides ephemeral tasks unless asked, and a chat is ephemeral.
    @Test("asks for ephemeral tasks only when told to")
    func ephemeralTasks() {
        let without = KandevTaskListQuery().queryItems.map(\.name)
        #expect(!without.contains("include_ephemeral"))

        let asked = KandevTaskListQuery(includeEphemeral: true).queryItems
        #expect(value(asked, "include_ephemeral") == "true")
    }
}

@Suite("KandevClient payloads")
struct KandevClientPayloadTests {
    private func client(
        replies: [String: JSONValue] = [:]
    ) -> (KandevClient, RecordingTransport) {
        let transport = RecordingTransport(replies: replies)
        return (
            KandevClient(
                transport: transport,
                http: KandevHTTPClient(configuration: .init(baseURL: URL(string: "http://localhost")!))
            ),
            transport
        )
    }

    @Test("listing messages sends only the parameters it was given")
    func messagesPayloadShape() async throws {
        let (client, transport) = client(replies: [
            KandevAction.messageList: .object(["messages": .array([]), "has_more": .bool(false)])
        ])

        _ = try await client.messages(sessionID: "s1")

        let bare = try #require(await transport.lastRequest())
        #expect(bare.payload?["session_id"] == .string("s1"))
        #expect(bare.payload?["limit"] == nil)
        #expect(bare.payload?["before"] == nil)

        _ = try await client.messages(sessionID: "s1", limit: 50, before: "cursor-1")

        let paged = try #require(await transport.lastRequest())
        #expect(paged.payload?["limit"] == .integer(50))
        #expect(paged.payload?["before"] == .string("cursor-1"))
    }

    @Test("reading the queue sends the same three ids a prompt needs")
    func queuePayloadShape() async throws {
        let (client, transport) = client(replies: [
            KandevAction.messageQueueGet: .object([
                "count": .integer(1),
                "entries": .array([]),
                "auto_run": .bool(true),
                "max": .integer(5),
            ])
        ])

        let snapshot = try await client.queue(
            sessionID: "s1",
            taskID: "t1",
            sessionIncarnationID: "inc-1"
        )

        #expect(snapshot.count == 1)
        #expect(snapshot.autoRun == true)
        #expect(snapshot.max == 5)

        let request = try #require(await transport.lastRequest())
        #expect(request.payload?["session_id"] == .string("s1"))
        #expect(request.payload?["task_id"] == .string("t1"))
        #expect(request.payload?["session_incarnation_id"] == .string("inc-1"))
    }
}
