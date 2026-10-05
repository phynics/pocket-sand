import Foundation
import Testing

@testable import KandevKit

/// A prompt source that records what was sent and can be made to refuse.
actor StubPromptSource: KandevPromptSource {
    private(set) var sentPrompts: [(content: String, clientQueueID: String?)] = []
    private(set) var interruptions: [String?] = []
    private(set) var clearedQueues = 0
    private(set) var stoppedTurns: [String] = []
    private(set) var queueReads = 0

    var queueSnapshot = KandevQueueSnapshot(
        count: 0,
        entries: [],
        autoRun: true,
        max: 5
    )
    var sendFailure: (any Error)?
    var queueFailure: (any Error)?

    func setQueue(_ snapshot: KandevQueueSnapshot) { queueSnapshot = snapshot }
    func failNextSend(with error: any Error) { sendFailure = error }
    func failQueueReads(with error: any Error) { queueFailure = error }

    func sendPrompt(
        _ content: String,
        sessionID: String,
        taskID: String,
        sessionIncarnationID: String,
        clientQueueID: String?
    ) async throws -> KandevQueuedPrompt {
        if let sendFailure {
            self.sendFailure = nil
            throw sendFailure
        }
        sentPrompts.append((content, clientQueueID))
        return KandevQueuedPrompt(id: "q\(sentPrompts.count)", content: content, position: sentPrompts.count)
    }

    func queue(
        sessionID: String,
        taskID: String,
        sessionIncarnationID: String
    ) async throws -> KandevQueueSnapshot {
        queueReads += 1
        if let queueFailure { throw queueFailure }
        return queueSnapshot
    }

    func sendQueuedNow(
        sessionID: String,
        taskID: String,
        sessionIncarnationID: String,
        entryID: String?
    ) async throws -> KandevSendNowResult {
        interruptions.append(entryID)
        return KandevSendNowResult(sessionID: sessionID, dispatched: true, sentCount: entryID == nil ? 2 : 1)
    }

    func clearQueue(sessionID: String, taskID: String, sessionIncarnationID: String) async throws {
        clearedQueues += 1
        queueSnapshot = KandevQueueSnapshot(count: 0, entries: [], autoRun: true, max: 5)
    }

    func stopTurn(sessionID: String) async throws {
        stoppedTurns.append(sessionID)
    }
}

private let identity = ComposerStore.Identity(
    taskID: "t1",
    sessionID: "s1",
    sessionIncarnationID: "inc-1"
)

@MainActor
@Suite("ComposerStore")
struct ComposerStoreTests {
    private func bound(
        queue: KandevQueueSnapshot = KandevQueueSnapshot(count: 0, entries: [], autoRun: true, max: 5)
    ) async -> (ComposerStore, StubPromptSource) {
        let source = StubPromptSource()
        await source.setQueue(queue)
        let store = ComposerStore(source: source, makeQueueID: { "fixed-queue-id" })
        await store.bind(identity)
        return (store, source)
    }

    /// The three states of the one button, and the order they resolve in.
    @Test("one button, three states, and the draft outranks them all")
    func buttonStates() async {
        let (store, _) = await bound()

        // Idle: nothing to stop, so it is a send button whether or not there is a draft.
        #expect(store.action(turnIsRunning: false) == .send)
        store.draft = "hello"
        #expect(store.action(turnIsRunning: false) == .send)

        // Working with an empty field: the button belongs to the turn.
        store.draft = ""
        #expect(store.action(turnIsRunning: true) == .stopTurn)

        // A word in the field takes it back, because sending is what you are doing.
        store.draft = "and another thing"
        #expect(store.action(turnIsRunning: true) == .send, "stop must not sit where send belongs")
    }

    /// "Send again" means send the one that is waiting, ahead of what the agent is
    /// doing — which is the whole reason to tap the same button twice.
    @Test("a waiting prompt turns the button into send-now")
    func queuedPromptTurnsTheButton() async {
        let source = StubPromptSource()
        await source.setQueue(
            KandevQueueSnapshot(
                count: 1,
                entries: [KandevQueuedPrompt(id: "q1", content: "waiting", position: 1)],
                autoRun: true,
                max: 5
            )
        )
        let store = ComposerStore(source: source, makeQueueID: { "fixed" })
        await store.bind(identity)

        #expect(store.action(turnIsRunning: true) == .sendQueuedNow)
        #expect(store.action(turnIsRunning: false) == .send, "nothing is running to interrupt")

        store.draft = "typed over the top"
        #expect(store.action(turnIsRunning: true) == .send, "a draft still wins")
    }

    /// Stopping is a right the server grants separately, so a caller without it must not
    /// be offered a stop button that would be refused.
    @Test("offers no stop to someone who may not control sessions")
    func noStopWithoutPermission() async {
        let source = StubPromptSource()
        let store = ComposerStore(source: source)
        await store.bind(
            identity,
            permissions: ConversationPermissions(canPrompt: true, canControlSessions: false)
        )

        #expect(store.action(turnIsRunning: true) == .send)
    }

    @Test("cannot send before it knows which session to speak to")
    func cannotSendWithoutIdentity() async {
        let source = StubPromptSource()
        let store = ComposerStore(source: source)
        store.draft = "hello"

        #expect(store.canSend == false)
        #expect(await store.send() == false)

        let sent = await source.sentPrompts
        #expect(sent.isEmpty)
    }

    @Test("cannot send an empty or whitespace-only draft")
    func cannotSendBlank() async {
        let (store, _) = await bound()

        #expect(store.canSend == false)
        store.draft = "   \n "
        #expect(store.canSend == false)
        store.draft = "something"
        #expect(store.canSend)
    }

    @Test("sends the trimmed draft with a stable id for safe retries")
    func sendsTrimmedDraftWithQueueID() async throws {
        let (store, source) = await bound()
        store.draft = "  Reply with exactly: OK  \n"

        let sent = await store.send()

        #expect(sent)
        let prompts = await source.sentPrompts
        #expect(prompts.count == 1)
        #expect(prompts.first?.content == "Reply with exactly: OK")
        #expect(prompts.first?.clientQueueID == "fixed-queue-id")
    }

    @Test("clears the draft only after the server accepts it")
    func clearsDraftOnSuccess() async {
        let (store, _) = await bound()
        store.draft = "hello"

        await store.send()

        #expect(store.draft.isEmpty)
        #expect(store.phase == .idle)
    }

    /// Losing what someone typed because a request failed is the worst outcome
    /// available here, so a failure must keep it.
    @Test("keeps the draft when sending fails")
    func keepsDraftOnFailure() async {
        let (store, source) = await bound()
        await source.failNextSend(
            with: KandevError.action(
                KandevActionFailure(code: "queue_session_unavailable", message: "session is busy")
            )
        )
        store.draft = "hello"

        let sent = await store.send()

        #expect(sent == false)
        #expect(store.draft == "hello")
        if case .failed(let message) = store.phase {
            #expect(message == "session is busy")
        } else {
            Issue.record("expected a failed phase, got \(store.phase)")
        }
    }

    @Test("a full queue is a state the composer can explain, not a failure")
    func fullQueueIsAState() async {
        let (store, source) = await bound()
        await source.failNextSend(
            with: KandevError.queueFull(limit: 5)
        )
        store.draft = "hello"

        await store.send()

        #expect(store.phase == .full(limit: 5))
        #expect(store.isQueueFull)
        #expect(store.canSend == false, "send should be disabled while the queue is full")
        #expect(store.draft == "hello")
    }

    @Test("reads the queue's limit from the snapshot, not from prose")
    func fullQueueFromSnapshot() async {
        let full = KandevQueueSnapshot(
            count: 5,
            entries: [KandevQueuedPrompt(id: "q1", content: "one")],
            autoRun: true,
            max: 5
        )
        let (store, _) = await bound(queue: full)

        #expect(store.isQueueFull)
        #expect(store.queuedCount == 5)
        #expect(store.queuedPrompts.map(\.id) == ["q1"])
    }

    @Test("a queue with room is not full even when it has entries")
    func partialQueueIsNotFull() async {
        let partial = KandevQueueSnapshot(
            count: 2,
            entries: [],
            autoRun: true,
            max: 5
        )
        let (store, _) = await bound(queue: partial)

        #expect(store.isQueueFull == false)
        store.draft = "hello"
        #expect(store.canSend)
    }

    @Test("interrupting sends a named entry, or everything when none is named")
    func interruptionScopes() async {
        let (store, source) = await bound()

        await store.interruptAndSend(entryID: "q1")
        await store.interruptAndSend(entryID: nil)

        let interruptions = await source.interruptions
        #expect(interruptions.count == 2)
        #expect(interruptions[0] == "q1")
        #expect(interruptions[1] == nil)
    }

    @Test("stopping a turn is separate from sending and leaves the draft alone")
    func stoppingIsSeparate() async {
        let (store, source) = await bound()
        store.draft = "not yet sent"

        await store.stopTurn()

        let stopped = await source.stoppedTurns
        #expect(stopped == ["s1"])
        #expect(store.draft == "not yet sent")
    }

    @Test("clearing the queue empties it")
    func clearingQueue() async {
        let (store, source) = await bound(
            queue: KandevQueueSnapshot(count: 3, entries: [], autoRun: true, max: 5)
        )
        #expect(store.queuedCount == 3)

        await store.clearQueue()

        #expect(store.queuedCount == 0)
        #expect(await source.clearedQueues == 1)
    }

    @Test("binding to the same session again does not refetch the queue")
    func bindingIsIdempotent() async {
        let (store, source) = await bound()

        await store.bind(identity)

        let reads = await source.queueReads
        #expect(reads == 1, "the second bind is the same identity and should be a no-op")
    }

    @Test("binding to a different session refetches the queue")
    func rebindingRefetches() async {
        let (store, source) = await bound()

        await store.bind(
            ComposerStore.Identity(taskID: "t1", sessionID: "s2", sessionIncarnationID: "inc-2")
        )

        let reads = await source.queueReads
        #expect(reads == 2)
    }

    /// The queue is context, not the point of the screen: failing to read it
    /// should not put an error in front of someone who just opened a task.
    @Test("a failed queue read leaves the composer usable")
    func failedQueueReadIsQuiet() async {
        let source = StubPromptSource()
        await source.failQueueReads(with: KandevError.connectionClosed)
        let store = ComposerStore(source: source)

        await store.bind(identity)

        #expect(store.phase == .idle)
        store.draft = "hello"
        #expect(store.canSend)
    }
}

@MainActor
@Suite("ComposerStore permissions")
struct ComposerPermissionsTests {
    private func bound(
        canPrompt: Bool,
        canControlSessions: Bool
    ) async -> ComposerStore {
        let store = ComposerStore(source: StubPromptSource())
        await store.bind(
            identity,
            permissions: ConversationPermissions(
                canPrompt: canPrompt,
                canControlSessions: canControlSessions
            )
        )
        return store
    }

    /// Offering a Send button the server will refuse is a worse experience than
    /// not offering it, and the scopes arrive with the workspace.
    @Test("will not offer to send without permission to prompt")
    func refusesWithoutPromptScope() async {
        let store = await bound(canPrompt: false, canControlSessions: true)
        store.draft = "hello"

        #expect(store.canSend == false)
        #expect(await store.send() == false)
    }

    @Test("offers to send when the server grants the scope")
    func sendsWithPromptScope() async {
        let store = await bound(canPrompt: true, canControlSessions: false)
        store.draft = "hello"

        #expect(store.canSend)
    }

    /// Cancelling agent work is a stronger right than prompting, and the server
    /// reports it separately for a reason.
    @Test("will not offer to stop without permission to control sessions")
    func refusesToStopWithoutScope() async {
        let promptingOnly = await bound(canPrompt: true, canControlSessions: false)
        #expect(promptingOnly.canStopTurn == false)

        let controlling = await bound(canPrompt: false, canControlSessions: true)
        #expect(controlling.canStopTurn)
    }

    @Test("a default install has no scopes to read, so nothing is disabled")
    func defaultsArePermissive() {
        #expect(ConversationPermissions.default.canPrompt)
        #expect(ConversationPermissions.default.canControlSessions)
    }

    @Test("workspace scopes translate into permissions")
    func workspaceScopesTranslate() {
        let readOnly = KandevWorkspace(id: "w", name: "W", scopes: ["workspace.read"])
        #expect(readOnly.conversationPermissions.canPrompt == false)
        #expect(readOnly.conversationPermissions.canControlSessions == false)

        let owner = KandevWorkspace(
            id: "w",
            name: "W",
            scopes: ["session.prompt", "session.control"]
        )
        #expect(owner.conversationPermissions.canPrompt)
        #expect(owner.conversationPermissions.canControlSessions)
    }
}
