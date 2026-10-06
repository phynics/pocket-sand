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

        let only = KandevTaskListQuery(onlyEphemeral: true).queryItems
        #expect(value(only, "only_ephemeral") == "true")
        #expect(value(only, "include_ephemeral") == nil, "only is asked for, not both")
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
        #expect(bare.payload?["sort"] == .string("desc"), "the newest page is the one a chat needs")

        _ = try await client.messages(sessionID: "s1", limit: 50, before: "cursor-1")

        let paged = try #require(await transport.lastRequest())
        #expect(paged.payload?["limit"] == .integer(50))
        #expect(paged.payload?["before"] == .string("cursor-1"))
    }

    /// The wire hands a descending page back newest-first, and everything above the client reads
    /// a conversation oldest-first. The turn happens here so nobody else has to know about it —
    /// and so a session longer than one page shows its tail rather than its head.
    @Test("a page is asked for newest-first and handed back in reading order")
    func messagesPageIsReversed() async throws {
        func message(_ id: String) -> JSONValue {
            .object([
                "id": .string(id),
                "type": .string("message"),
                "author_type": .string("agent"),
                "content": .string(id),
            ])
        }
        let (client, _) = client(replies: [
            KandevAction.messageList: .object([
                "messages": .array([message("m3"), message("m2"), message("m1")]),
                "has_more": .bool(true),
            ])
        ])

        let page = try await client.messages(sessionID: "s1", limit: 50)

        #expect(page.messages.map(\.id) == ["m1", "m2", "m3"])
        #expect(page.hasMore)
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

    /// The pinned release line's preflight decodes with `DisallowUnknownFields` and knows two
    /// fields. A body carrying `discard_worktree_changes: false` was refused as an invalid request,
    /// and since the ticket that preflight answers with is what the delete route demands, that
    /// refusal was a failed delete of *every* task on a v0.96.0 server. Verified against the live
    /// one: `{"error":"invalid task delete preflight request"}`.
    @Test("the delete preflight sends only the fields the pinned server knows")
    func deletePreflightPayloadShape() {
        let asking = KandevClient.deletePreflightPayload(
            taskIDs: ["t1", "t2"],
            cascadeSubTasks: true,
            discardWorktreeChanges: false
        )
        #expect(asking["task_ids"] == .array([.string("t1"), .string("t2")]))
        #expect(asking["cascade"] == .bool(true))
        #expect(asking["discard_worktree_changes"] == nil)

        // And it is not dropped altogether: a server that can answer the question is still asked
        // it, because discarding uncommitted work is the one thing that needs consent.
        let discarding = KandevClient.deletePreflightPayload(
            taskIDs: ["t1"],
            cascadeSubTasks: false,
            discardWorktreeChanges: true
        )
        #expect(discarding["discard_worktree_changes"] == .bool(true))
    }
}
