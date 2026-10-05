import Foundation
import Testing

@testable import KandevKit

/// A transcript source with no socket behind it. Records what it was asked for,
/// so tests can assert the store's choice of session as well as its output.
actor StubTranscriptSource: KandevTranscriptSource {
    enum Failure: Error, Equatable { case unavailable }

    var taskResult: Result<KandevTask, any Error>
    var sessionsResult: Result<[KandevSession], any Error>
    var messagesBySession: [String: [KandevMessage]]
    var messagesFailure: (any Error)?

    private(set) var requestedSessions: [String] = []

    init(
        task: Result<KandevTask, any Error>,
        sessions: Result<[KandevSession], any Error>,
        messages: [String: [KandevMessage]] = [:]
    ) {
        taskResult = task
        sessionsResult = sessions
        messagesBySession = messages
    }

    func task(id: String) async throws -> KandevTask { try taskResult.get() }

    func sessions(taskID: String) async throws -> [KandevSession] { try sessionsResult.get() }

    func messages(sessionID: String, limit: Int?, before: String?) async throws -> KandevMessagePage {
        requestedSessions.append(sessionID)
        if let messagesFailure {
            self.messagesFailure = nil
            throw messagesFailure
        }
        return KandevMessagePage(messages: messagesBySession[sessionID] ?? [], cursor: nil, hasMore: false)
    }

    func failNextMessagesCall() { messagesFailure = Failure.unavailable }

    func setMessages(_ messages: [KandevMessage], forSession sessionID: String) {
        messagesBySession[sessionID] = messages
    }

    /// For tests where the server gains a session partway through, which is what
    /// starting one looks like from the client's side.
    func setSessions(_ sessions: [KandevSession]) {
        sessionsResult = .success(sessions)
    }
}

private func session(_ id: String, primary: Bool = false) -> KandevSession {
    KandevSession(id: id, taskID: "t1", name: id, state: "WAITING_FOR_INPUT", isPrimary: primary)
}

private func message(_ id: String, author: String, text: String, turn: String = "turn-1") -> KandevMessage {
    KandevMessage(
        id: id,
        authorType: author,
        type: "message",
        content: text,
        turnID: turn,
        createdAt: KandevTimestamp(raw: "2026-10-04T18:24:56.417151677Z")
    )
}

private let task = KandevTask(
    id: "t1",
    title: "Implement embedded Zenoh transport",
    state: "REVIEW",
    workflowStepID: "step-work",
    sessionCount: 2,
    primarySessionID: "s2",
    primarySessionState: "RUNNING"
)

/// The observable store the transcript screen binds to.
@MainActor
@Suite("TranscriptStore")
struct TranscriptStoreTests {
    private func loaded(
        sessions: [KandevSession],
        messages: [String: [KandevMessage]] = [:],
        stepNames: [String: String] = [:]
    ) async -> (TranscriptStore, StubTranscriptSource) {
        let source = StubTranscriptSource(
            task: .success(task),
            sessions: .success(sessions),
            messages: messages
        )
        let store = TranscriptStore(source: source, stepNames: stepNames)
        await store.load(taskID: "t1")
        return (store, source)
    }

    @Test("loads the task, its sessions, and the chosen session's transcript")
    func loadsEverything() async {
        let (store, _) = await loaded(
            sessions: [session("s1"), session("s2", primary: true)],
            messages: ["s2": [message("m1", author: "user", text: "hello")]]
        )

        #expect(store.phase == .loaded)
        #expect(store.task?.title == "Implement embedded Zenoh transport")
        #expect(store.sessions.count == 2)
        #expect(store.selectedSessionID == "s2")
        #expect(store.turns.first?.rows.first?.text == "hello")
    }

    /// Preferring the session the server calls primary keeps the app and the web
    /// UI looking at the same conversation.
    @Test("prefers the session the server marks primary")
    func prefersPrimary() async {
        let (store, _) = await loaded(
            sessions: [session("s1", primary: true), session("s2")],
            messages: ["s1": [message("m1", author: "user", text: "from s1")]]
        )

        #expect(store.selectedSessionID == "s1")
    }

    @Test("falls back to the session the task points at")
    func fallsBackToTaskPrimarySession() async {
        let (store, _) = await loaded(
            sessions: [session("s1"), session("s2")],
            messages: ["s2": [message("m1", author: "user", text: "from s2")]]
        )

        #expect(store.selectedSessionID == "s2")
    }

    @Test("falls back to the first session when nothing else points anywhere")
    func fallsBackToFirstSession() async {
        let source = StubTranscriptSource(
            task: .success(KandevTask(id: "t1", title: "No pointers")),
            sessions: .success([session("s1"), session("s2")]),
            messages: ["s1": [message("m1", author: "user", text: "from s1")]]
        )
        let store = TranscriptStore(source: source)

        await store.load(taskID: "t1")

        #expect(store.selectedSessionID == "s1")
    }

    /// Opening a task must never start an agent, so a sessionless task is a state
    /// to show, not an error to report.
    @Test("reports a task with no session as a state, not a failure")
    func noSessionIsAState() async {
        let (store, _) = await loaded(sessions: [])

        #expect(store.phase == .loaded)
        #expect(store.hasNoSession)
        #expect(store.turns.isEmpty)
        #expect(store.selectedSessionID == nil)
    }

    @Test("resolves the task's step name for the header")
    func resolvesStepName() async {
        let (store, _) = await loaded(sessions: [session("s1")], stepNames: ["step-work": "In Progress"])

        #expect(store.stepName == "In Progress")
    }

    @Test("switching sessions loads that session's transcript")
    func switchingSessions() async {
        let (store, source) = await loaded(
            sessions: [session("s1", primary: true), session("s2")],
            messages: [
                "s1": [message("m1", author: "user", text: "from s1")],
                "s2": [message("m2", author: "user", text: "from s2")],
            ]
        )

        await store.select(sessionID: "s2")

        #expect(store.selectedSessionID == "s2")
        #expect(store.turns.first?.rows.first?.text == "from s2")
        let requested = await source.requestedSessions
        #expect(requested == ["s1", "s2"])
    }

    @Test("switching to the session already open does not refetch it")
    func switchingToSameSessionIsFree() async {
        let (store, source) = await loaded(
            sessions: [session("s1", primary: true)],
            messages: ["s1": [message("m1", author: "user", text: "from s1")]]
        )

        await store.select(sessionID: "s1")

        let requested = await source.requestedSessions
        #expect(requested == ["s1"])
    }

    @Test("a failed load reports a message and leaves the store usable")
    func failureIsReported() async {
        let source = StubTranscriptSource(task: .failure(StubTranscriptSource.Failure.unavailable), sessions: .success([]))
        let store = TranscriptStore(source: source)

        await store.load(taskID: "t1")

        guard case .failed(let message) = store.phase else {
            Issue.record("expected a failed phase, got \(store.phase)")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test("a failed transcript fetch is reported without losing the sessions")
    func transcriptFailureKeepsSessions() async {
        let source = StubTranscriptSource(
            task: .success(task),
            sessions: .success([session("s1", primary: true)])
        )
        let store = TranscriptStore(source: source)
        await source.failNextMessagesCall()

        await store.load(taskID: "t1")

        #expect(store.sessions.count == 1)
        if case .failed = store.phase {} else {
            Issue.record("expected a failed phase, got \(store.phase)")
        }
    }

    @Test("groups several sessions' worth of turns in the order the server sent them")
    func groupsTurnsInOrder() async {
        let (store, _) = await loaded(
            sessions: [session("s1", primary: true)],
            messages: [
                "s1": [
                    message("m1", author: "user", text: "first", turn: "a"),
                    message("m2", author: "agent", text: "reply", turn: "a"),
                    message("m3", author: "user", text: "second", turn: "b"),
                ]
            ]
        )

        #expect(store.turns.map(\.id) == ["a", "b"])
        #expect(store.turns[0].rows.map(\.text) == ["first", "reply"])
    }
}

@MainActor
@Suite("TranscriptStore condensing")
struct TranscriptCondensingStoreTests {
    private func loaded(turns count: Int) async -> TranscriptStore {
        var messages: [KandevMessage] = []
        for index in 0..<count {
            messages.append(
                KandevMessage(
                    id: "u\(index)",
                    authorType: "user",
                    type: "message",
                    content: "ask \(index)",
                    turnID: "turn-\(index)"
                )
            )
            messages.append(
                KandevMessage(
                    id: "a\(index)",
                    authorType: "agent",
                    type: "message",
                    content: "answer \(index)",
                    turnID: "turn-\(index)"
                )
            )
        }
        let source = StubTranscriptSource(
            task: .success(KandevTask(id: "t1", title: "A task")),
            sessions: .success([KandevSession(id: "s1", taskID: "t1", isPrimary: true)]),
            messages: ["s1": messages]
        )
        let store = TranscriptStore(source: source)
        await store.load(taskID: "t1")
        return store
    }

    /// Everything but the turn being written, because the work you are following is the
    /// work happening now.
    @Test("condenses every turn but the one being written")
    func condensesAllButTheWorkingTurn() async {
        let store = await loaded(turns: 3)

        #expect(store.isCondensedByDefault(turnID: "turn-0", working: true))
        #expect(store.isCondensedByDefault(turnID: "turn-1", working: true))
        #expect(store.isCondensedByDefault(turnID: "turn-2", working: true) == false)
    }

    /// A finished turn folds as soon as its work stops — the newest included, which is the
    /// one a person is most likely to be looking at.
    @Test("a finished turn folds, even the newest")
    func finishedTurnFolds() async {
        let store = await loaded(turns: 1)

        #expect(store.isCondensedByDefault(turnID: "turn-0", working: false))
    }

    /// A turn arriving live becomes the one being written, so the one that was open
    /// folds.
    @Test("the turn being written folds the one before it")
    func condensingFollowsTheWorkingTurn() async {
        let store = await loaded(turns: 1)
        #expect(store.isCondensedByDefault(turnID: "turn-0", working: true) == false)

        store.upsert(
            KandevMessage(id: "u9", authorType: "user", type: "message", content: "next", turnID: "turn-9")
        )

        #expect(store.isCondensedByDefault(turnID: "turn-0", working: true))
        #expect(store.isCondensedByDefault(turnID: "turn-9", working: true) == false)
    }
}
