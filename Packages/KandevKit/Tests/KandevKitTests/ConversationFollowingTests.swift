import Foundation
import Testing

@testable import KandevKit

private struct FixedNotifications: KandevNotificationHub.Source {
    let notifications: AsyncStream<KandevEnvelope>
}

/// A conversation stream with no socket behind it. Records the scope it was
/// given, so a test can push frames that look like the server's own.
final class StubConversationStream: KandevLiveConversations, @unchecked Sendable {
    let notifications: AsyncStream<KandevEnvelope>
    private let continuation: AsyncStream<KandevEnvelope>.Continuation
    /// Frames pushed here travel the same road as the server's: through the hub.
    let hub: KandevNotificationHub

    var subscription = KandevConversationSubscription(
        success: true,
        protocolVersion: 2,
        scopeID: nil,
        sessionID: "s1",
        epoch: "epoch-1",
        revision: "10"
    )
    private(set) var subscribeCount = 0
    private(set) var unsubscribeCount = 0
    private(set) var scopeIDs: [String] = []
    /// Which session each subscription was for, so a test can prove the
    /// subscription moved with the session rather than staying behind.
    private(set) var subscribedSessions: [String] = []
    var subscribeFailure: (any Error)?

    init() {
        let (stream, continuation) = AsyncStream<KandevEnvelope>.makeStream()
        notifications = stream
        self.continuation = continuation
        hub = KandevNotificationHub(source: FixedNotifications(notifications: stream))
    }

    func subscribeToConversation(
        sessionID: String,
        scopeID: String
    ) async throws -> KandevConversationSubscription {
        subscribeCount += 1
        scopeIDs.append(scopeID)
        subscribedSessions.append(sessionID)
        if let subscribeFailure {
            self.subscribeFailure = nil
            throw subscribeFailure
        }
        return subscription
    }

    func unsubscribeFromConversation(sessionID: String, scopeID: String) async throws {
        unsubscribeCount += 1
    }

    /// Delivers a change the way the server does: as a notification frame.
    ///
    /// The frame is built from primitives rather than by encoding a
    /// `KandevConversationChange`, because those types model what arrives and
    /// nothing here writes to the server. Building the shape by hand also means
    /// the test states the wire format instead of trusting the model to agree
    /// with itself.
    func push(
        scope: String,
        session: String = "s1",
        epoch: String = "epoch-1",
        base: String,
        revision: String,
        check: Bool? = nil,
        operations: [JSONValue] = []
    ) {
        var payload: [String: JSONValue] = [
            "protocol_version": .integer(2),
            "scope_id": .string(scope),
            "session_id": .string(session),
            "epoch": .string(epoch),
            "base_revision": .string(base),
            "revision": .string(revision),
            "operations": .array(operations),
        ]
        if let check { payload["check"] = .bool(check) }
        continuation.yield(
            KandevEnvelope(
                type: .notification,
                action: KandevAction.sessionConversationChanged,
                payload: .object(payload)
            )
        )
    }

    /// One `message` upsert, shaped like the frames a live server sent.
    func messageOperation(id: String, text: String, session: String = "s1") -> JSONValue {
        .object([
            "entity": .string("message"),
            "id": .string(id),
            "kind": .string("upsert"),
            "message": .object([
                "id": .string(id),
                "author_type": .string("agent"),
                "type": .string("message"),
                "content": .string(text),
                "session_id": .string(session),
                "turn_id": .string("turn-1"),
                "created_at": .string("2026-10-04T21:38:07.926964136Z"),
            ]),
        ])
    }

    /// A session's state changing, shaped like the frames a live server sent.
    func pushSessionState(
        session: String = "s1",
        task: String = "t1",
        state: String,
        activity: String? = nil,
        primary: Bool = true
    ) {
        var payload: [String: JSONValue] = [
            "session_id": .string(session),
            "task_id": .string(task),
            "new_state": .string(state),
            "is_primary": .bool(primary),
        ]
        if let activity { payload["foreground_activity"] = .string(activity) }
        continuation.yield(
            KandevEnvelope(
                type: .notification,
                action: KandevAction.sessionStateChanged,
                payload: .object(payload)
            )
        )
    }

    var lastScopeID: String? { scopeIDs.last }
}

/// Polls until a condition holds, because the follower delivers on its own task
/// and there is nothing to await directly.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@MainActor
@Suite("TaskConversationStore following")
struct TaskConversationFollowingTests {
    private func makeSession() -> KandevSession {
        KandevSession(
            id: "s1",
            taskID: "t1",
            name: "worker",
            state: "RUNNING",
            isPrimary: true,
            queueIncarnationID: "inc-1"
        )
    }

    private func loaded() async -> (
        TaskConversationStore,
        StubTranscriptSource,
        StubPromptSource,
        StubConversationStream
    ) {
        let transcriptSource = StubTranscriptSource(
            task: .success(KandevTask(id: "t1", title: "A task", sessionCount: 1)),
            sessions: .success([makeSession()]),
            messages: ["s1": []]
        )
        let promptSource = StubPromptSource()
        let stream = StubConversationStream()
        // The hub is the only reader of the stream, so frames pushed by the test
        // travel nowhere until it is running.
        await stream.hub.start()
        let store = TaskConversationStore(
            transcriptSource: transcriptSource,
            promptSource: promptSource,
            conversationServer: stream
        )
        await store.load(taskID: "t1")
        return (store, transcriptSource, promptSource, stream)
    }

    @Test("loading a task starts following the open session")
    func loadStartsFollowing() async {
        let (store, _, _, stream) = await loaded()

        #expect(store.isFollowing)
        #expect(stream.subscribeCount == 1)
        #expect(stream.lastScopeID?.hasPrefix("core:ios:") == true)
    }

    /// Opening another session is one sequence: the transcript, the composer, and
    /// the subscription move together. A screen that moved two of the three left
    /// the composer speaking to the session just left.
    @Test("opening another session moves the transcript, the composer, and the subscription")
    func openingASessionMovesEverything() async {
        let transcriptSource = StubTranscriptSource(
            task: .success(
                KandevTask(id: "t1", title: "A task", sessionCount: 2, primarySessionID: "s1")
            ),
            sessions: .success([
                KandevSession(id: "s1", taskID: "t1", name: "one", isPrimary: true, queueIncarnationID: "inc-1"),
                KandevSession(id: "s2", taskID: "t1", name: "two", queueIncarnationID: "inc-2"),
            ]),
            messages: [
                "s1": [KandevMessage(id: "m1", authorType: "user", content: "first", turnID: "turn-1")],
                "s2": [KandevMessage(id: "m2", authorType: "user", content: "second", turnID: "turn-2")],
            ]
        )
        let stream = StubConversationStream()
        await stream.hub.start()
        let store = TaskConversationStore(
            transcriptSource: transcriptSource,
            promptSource: StubPromptSource(),
            conversationServer: stream
        )
        await store.load(taskID: "t1")
        #expect(store.transcript.selectedSessionID == "s1")
        #expect(store.composer.identity?.sessionID == "s1")

        await store.open(sessionID: "s2")

        #expect(store.transcript.selectedSessionID == "s2")
        #expect(store.composer.identity?.sessionID == "s2", "the composer must speak to the session now open")
        #expect(store.composer.identity?.sessionIncarnationID == "inc-2")
        #expect(stream.subscribedSessions.last == "s2", "the subscription must move with the session")
        #expect(store.isFollowing)
    }

    /// The point of the whole feature: a message the agent produces arrives on its
    /// own, without the reader doing anything.
    @Test("a live message appears in the transcript without a refetch")
    func liveMessageAppears() async {
        let (store, transcriptSource, _, stream) = await loaded()
        let readsBefore = await transcriptSource.requestedSessions.count
        let scope = try! #require(stream.lastScopeID)

        stream.push(
            scope: scope,
            base: "10",
            revision: "11",
            operations: [stream.messageOperation(id: "m-live", text: "FOLLOW OK")]
        )

        let appeared = await waitUntil {
            store.transcript.turns.contains { turn in
                turn.rows.contains { $0.text == "FOLLOW OK" }
            }
        }
        #expect(appeared, "the live message never reached the transcript")
        #expect(await transcriptSource.requestedSessions.count == readsBefore, "no refetch should be needed")
    }

    /// A streaming message arrives more than once under one id as its text grows.
    /// Appending would show the conversation growing duplicates instead of
    /// sentences.
    @Test("a repeated upsert replaces the message rather than duplicating it")
    func upsertReplaces() async {
        let (store, _, _, stream) = await loaded()
        let scope = try! #require(stream.lastScopeID)

        stream.push(
            scope: scope,
            base: "10",
            revision: "11",
            operations: [stream.messageOperation(id: "m1", text: "FOLL")]
        )
        _ = await waitUntil { !store.transcript.turns.isEmpty }

        stream.push(
            scope: scope,
            base: "11",
            revision: "12",
            operations: [stream.messageOperation(id: "m1", text: "FOLLOW OK")]
        )
        let updated = await waitUntil {
            store.transcript.turns.first?.rows.first?.text == "FOLLOW OK"
        }

        #expect(updated)
        let rows = store.transcript.turns.flatMap(\.rows)
        #expect(rows.count == 1, "the message should be replaced, not appended")
    }

    @Test("a message for another session is not applied")
    func ignoresOtherSession() async {
        let (store, _, _, stream) = await loaded()
        let scope = try! #require(stream.lastScopeID)

        stream.push(
            scope: scope,
            base: "10",
            revision: "11",
            operations: [stream.messageOperation(id: "m-other", text: "not mine", session: "s9")]
        )
        _ = await waitUntil(timeout: .milliseconds(200)) { false }

        #expect(store.transcript.turns.isEmpty)
    }

    /// A missed revision means the conversation has a hole. Refetching is the only
    /// honest response.
    @Test("a gap refetches the conversation and resubscribes")
    func gapRefetchesAndResubscribes() async {
        let (store, transcriptSource, _, stream) = await loaded()
        let readsBefore = await transcriptSource.requestedSessions.count
        let scope = try! #require(stream.lastScopeID)

        stream.push(
            scope: scope,
            base: "3",
            revision: "12",
            operations: [stream.messageOperation(id: "m-gap", text: "from nowhere")]
        )

        let refetched = await waitUntil {
            await transcriptSource.requestedSessions.count > readsBefore
        }
        #expect(refetched)
        let resubscribed = await waitUntil { stream.subscribeCount == 2 }
        #expect(resubscribed, "a gap should re-establish the subscription, not just refetch")
    }

    @Test("an unknown operation refetches rather than guessing")
    func unknownOperationRefetches() async {
        let (store, transcriptSource, _, stream) = await loaded()
        let readsBefore = await transcriptSource.requestedSessions.count
        let scope = try! #require(stream.lastScopeID)

        stream.push(
            scope: scope,
            base: "10",
            revision: "11",
            operations: [.object(["entity": .string("widget"), "id": .string("w1"), "kind": .string("upsert")])]
        )

        let refetched = await waitUntil { await transcriptSource.requestedSessions.count > readsBefore }
        #expect(refetched)
    }

    /// A subscription is an enhancement to a working screen. Failing to start one
    /// must not put an error in front of someone who just opened a task.
    @Test("a refused subscription leaves the screen working")
    func refusedSubscriptionIsSilent() async {
        let transcriptSource = StubTranscriptSource(
            task: .success(KandevTask(id: "t1", title: "A task", sessionCount: 1)),
            sessions: .success([makeSession()]),
            messages: ["s1": [KandevMessage(id: "m1", authorType: "user", content: "existing")]]
        )
        let stream = StubConversationStream()
        stream.subscribeFailure = KandevError.connectionClosed
        await stream.hub.start()
        let store = TaskConversationStore(
            transcriptSource: transcriptSource,
            promptSource: StubPromptSource(),
            conversationServer: stream
        )

        await store.load(taskID: "t1")

        #expect(store.isFollowing == false)
        #expect(store.transcript.phase == .loaded)
        #expect(store.transcript.turns.count == 1)
        if case .failed = store.transcript.phase {
            Issue.record("a failed subscription should not fail the screen")
        }
    }

    @Test("stopping unsubscribes")
    func stoppingUnsubscribes() async {
        let (store, _, _, stream) = await loaded()

        await store.stopFollowing()

        #expect(store.isFollowing == false)
        #expect(stream.unsubscribeCount == 1)
    }

    @Test("a server that cannot stream still loads the conversation")
    func worksWithoutAConversationSource() async {
        let transcriptSource = StubTranscriptSource(
            task: .success(KandevTask(id: "t1", title: "A task", sessionCount: 1)),
            sessions: .success([makeSession()]),
            messages: ["s1": [KandevMessage(id: "m1", authorType: "user", content: "existing")]]
        )
        let store = TaskConversationStore(
            transcriptSource: transcriptSource,
            promptSource: StubPromptSource()
        )

        await store.load(taskID: "t1")

        #expect(store.isFollowing == false)
        #expect(store.transcript.turns.count == 1)
    }

    /// The direct signal: an agent started from this screen changes nothing about the
    /// task that was read when the screen opened, so the state has to come from the
    /// session itself.
    @Test("a session state change marks the open session as working")
    func sessionStateMarksWorking() async {
        let (store, _, _, stream) = await loaded()
        #expect(store.isWorking == false)

        stream.pushSessionState(state: "RUNNING", activity: "generating")

        let working = await waitUntil { store.isWorking }
        #expect(working, "the session's own state should reach the screen")
    }

    /// The screen shows one session, and a frame for another is not its business.
    @Test("a session state change for another session is ignored")
    func otherSessionsStateIsIgnored() async {
        let (store, _, _, stream) = await loaded()

        stream.pushSessionState(session: "s2", state: "RUNNING", activity: "generating")
        _ = await waitUntil(timeout: .milliseconds(200)) { false }

        #expect(store.isWorking == false)
    }

    /// The stream reports changes, not the state itself, so the read at open is the
    /// starting point: a running task must not look idle just because no change has
    /// arrived yet.
    @Test("a task already running when opened is working from the start")
    func runningTaskSeedsWorking() async {
        let transcriptSource = StubTranscriptSource(
            task: .success(
                KandevTask(
                    id: "t1",
                    title: "A task",
                    sessionCount: 1,
                    primarySessionState: "RUNNING",
                    foregroundActivity: "generating"
                )
            ),
            sessions: .success([makeSession()]),
            messages: ["s1": []]
        )
        let stream = StubConversationStream()
        await stream.hub.start()
        let store = TaskConversationStore(
            transcriptSource: transcriptSource,
            promptSource: StubPromptSource(),
            conversationServer: stream
        )

        await store.load(taskID: "t1")

        #expect(store.isWorking, "the read at open is the starting point")
    }
}

@MainActor
@Suite("TranscriptStore upsert")
struct TranscriptUpsertTests {
    @Test("replaces a message with the same id and appends a new one")
    func replacesAndAppends() async {
        let source = StubTranscriptSource(
            task: .success(KandevTask(id: "t1", title: "A task")),
            sessions: .success([KandevSession(id: "s1", taskID: "t1", isPrimary: true)]),
            messages: ["s1": [KandevMessage(id: "m1", authorType: "agent", content: "first", turnID: "a")]]
        )
        let store = TranscriptStore(source: source)
        await store.load(taskID: "t1")
        #expect(store.turns.first?.rows.first?.text == "first")

        store.upsert(KandevMessage(id: "m1", authorType: "agent", content: "revised", turnID: "a"))
        #expect(store.turns.first?.rows.first?.text == "revised")

        store.upsert(KandevMessage(id: "m2", authorType: "user", content: "second", turnID: "b"))
        #expect(store.turns.count == 2)
    }

    @Test("refuses a message belonging to another session")
    func refusesOtherSession() async {
        let source = StubTranscriptSource(
            task: .success(KandevTask(id: "t1", title: "A task")),
            sessions: .success([KandevSession(id: "s1", taskID: "t1", isPrimary: true)]),
            messages: ["s1": []]
        )
        let store = TranscriptStore(source: source)
        await store.load(taskID: "t1")

        let applied = store.upsert(
            KandevMessage(id: "m9", authorType: "agent", content: "not mine", sessionID: "s9")
        )

        #expect(applied == false)
        #expect(store.turns.isEmpty)
    }
}
