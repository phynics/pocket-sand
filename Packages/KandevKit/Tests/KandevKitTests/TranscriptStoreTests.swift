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
    /// Pages keyed by the cursor they answer, so a test can walk a conversation backwards the way
    /// the server hands it over. The key is `before`, or empty for the newest page.
    var pages: [String: KandevMessagePage] = [:]

    private(set) var requestedSessions: [String] = []
    /// What each read asked to come before, so a test can see which cursor was used — and that a
    /// retry asked for the same one rather than skipping over a page that never arrived.
    private(set) var requestedCursors: [String?] = []

    init(
        task: Result<KandevTask, any Error>,
        sessions: Result<[KandevSession], any Error>,
        messages: [String: [KandevMessage]] = [:],
        pages: [String: KandevMessagePage] = [:]
    ) {
        taskResult = task
        sessionsResult = sessions
        messagesBySession = messages
        self.pages = pages
    }

    func task(id: String) async throws -> KandevTask { try taskResult.get() }

    func sessions(taskID: String) async throws -> [KandevSession] { try sessionsResult.get() }

    func messages(sessionID: String, limit: Int?, before: String?) async throws -> KandevMessagePage {
        requestedSessions.append(sessionID)
        requestedCursors.append(before)
        if let messagesFailure {
            self.messagesFailure = nil
            throw messagesFailure
        }
        // Paged when a test set up pages, and a single page otherwise, so the tests that are not
        // about paging do not have to describe a conversation twice.
        if !pages.isEmpty {
            return pages[before ?? ""] ?? KandevMessagePage(messages: [], cursor: nil, hasMore: false)
        }
        return KandevMessagePage(messages: messagesBySession[sessionID] ?? [], cursor: nil, hasMore: false)
    }

    func failNextMessagesCall(with error: any Error = Failure.unavailable) { messagesFailure = error }

    func setPages(_ pages: [String: KandevMessagePage]) {
        self.pages = pages
    }

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
        pages: [String: KandevMessagePage] = [:],
        stepNames: [String: String] = [:]
    ) async -> (TranscriptStore, StubTranscriptSource) {
        let source = StubTranscriptSource(
            task: .success(task),
            sessions: .success(sessions),
            messages: messages,
            pages: pages
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

    // MARK: - Reading backwards

    /// Two pages of one conversation: the newest, and the one before it, keyed by the cursor the
    /// server would have handed back for each — which is the oldest id in that page.
    private func pagedConversation() -> [String: KandevMessagePage] {
        [
            "": KandevMessagePage(
                messages: [message("m2", author: "agent", text: "the newer half")],
                cursor: "m2",
                hasMore: true
            ),
            "m2": KandevMessagePage(
                messages: [message("m1", author: "user", text: "the older half")],
                cursor: "m1",
                hasMore: false
            ),
        ]
    }

    /// The transcript holds one page and opens at its tail, so everything said before that page is
    /// not on the screen — and nothing says so, because a transcript that simply begins looks
    /// finished.
    @Test("an older page arrives in front of the one on screen")
    func loadsOlderMessages() async {
        let (store, source) = await loaded(
            sessions: [session("s1", primary: true)],
            pages: pagedConversation()
        )

        #expect(store.hasOlder)
        #expect(store.turns.first?.rows.first?.text == "the newer half")

        #expect(await store.loadOlder())

        // In front, not appended: the reader is reading backwards, and a page landing at the end
        // would be a conversation out of order.
        #expect(store.turns.first?.rows.first?.text == "the older half")
        #expect(store.turns.first?.rows.last?.text == "the newer half")
        #expect(store.hasOlder == false)
        // Asked for by the id the previous page named, which is what the server's cursor is.
        #expect(await source.requestedCursors == [nil, "m2"])
    }

    @Test("nothing is asked for once the server has said there is nothing older")
    func doesNotAskPastTheBeginning() async {
        let (store, source) = await loaded(
            sessions: [session("s1", primary: true)],
            messages: ["s1": [message("m1", author: "user", text: "only")]]
        )

        #expect(store.hasOlder == false)
        #expect(await store.loadOlder() == false)
        // The first load and nothing else: the second ask never reached the server.
        #expect(await source.requestedCursors == [nil])
    }

    /// A live frame can write a message that a later page also carries — the page is fetched from a
    /// cursor, and that cursor is older than the frame that just arrived. Merged by id, the reader
    /// sees one copy; concatenated, a conversation that grows duplicates.
    @Test("a message already on screen is not fetched into it twice")
    func doesNotDuplicateTheSeam() async {
        let (store, _) = await loaded(
            sessions: [session("s1", primary: true)],
            pages: [
                "": KandevMessagePage(
                    messages: [message("m2", author: "agent", text: "newer")],
                    cursor: "m2",
                    hasMore: true
                ),
                "m2": KandevMessagePage(
                    messages: [
                        message("m1", author: "user", text: "older"),
                        message("m2", author: "agent", text: "newer"),
                    ],
                    cursor: "m1",
                    hasMore: false
                ),
            ]
        )

        #expect(await store.loadOlder())
        #expect(store.turns.flatMap { $0.rows.map(\.text) } == ["older", "newer"])
    }

    @Test("a page that failed leaves the transcript whole and asks for the same page again")
    func failedPageKeepsTheCursor() async {
        let (store, source) = await loaded(
            sessions: [session("s1", primary: true)],
            pages: pagedConversation()
        )
        await source.failNextMessagesCall()

        #expect(await store.loadOlder() == false)
        #expect(store.turns.flatMap { $0.rows.map(\.text) } == ["the newer half"])
        // Still offered, because the page is still there to ask for.
        #expect(store.hasOlder)

        #expect(await store.loadOlder())
        #expect(store.turns.flatMap { $0.rows.map(\.text) } == ["the older half", "the newer half"])
        // The same cursor twice: a failed page must not be skipped over, or the reader loses a
        // span of the conversation with no sign that anything is missing.
        #expect(await source.requestedCursors == [nil, "m2", "m2"])
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

    /// Pulling to refresh cancels the request in it, and that is not a failure. The transcript the
    /// reader is looking at stays, and nothing about the cancellation reaches the screen.
    @Test("a cancelled reload keeps the transcript and reports nothing")
    func cancelledReloadKeepsTranscript() async {
        let (store, source) = await loaded(
            sessions: [session("s1", primary: true)],
            messages: ["s1": [message("m1", author: "user", text: "hello")]]
        )
        await source.failNextMessagesCall(with: URLError(.cancelled))

        await store.load(taskID: "t1")

        #expect(store.phase == .loaded)
        #expect(store.turns.flatMap { $0.rows.map(\.text) } == ["hello"])
        #expect(store.selectedSessionID == "s1")
        #expect(store.sessions.count == 1)
    }

    /// The same rule for the refetch after a send, which goes through `select(force:)`, and for the
    /// Swift cancellation error rather than the URL one. The history the reader asked for is kept.
    @Test("a cancelled refetch keeps the history that was loaded and reports nothing")
    func cancelledRefetchKeepsHistory() async {
        let (store, source) = await loaded(
            sessions: [session("s1", primary: true)],
            pages: pagedConversation()
        )
        #expect(await store.loadOlder())
        let before = store.turns.flatMap { $0.rows.map(\.text) }

        await source.failNextMessagesCall(with: CancellationError())
        await store.select(sessionID: "s1", force: true)

        #expect(store.phase == .loaded)
        #expect(store.turns.flatMap { $0.rows.map(\.text) } == before)
        #expect(store.hasOlder == false)
    }

    /// A screen that has never loaded must not be left looking loaded or failed by a cancelled
    /// first read. Back at idle, its `.task` loads it again when it next appears.
    @Test("a cancelled first load leaves the store idle so it can load again")
    func cancelledFirstLoadStaysIdle() async {
        let source = StubTranscriptSource(
            task: .success(task),
            sessions: .success([session("s1", primary: true)]),
            messages: ["s1": [message("m1", author: "user", text: "hello")]]
        )
        let store = TranscriptStore(source: source)
        await source.failNextMessagesCall(with: CancellationError())

        await store.load(taskID: "t1")
        #expect(store.phase == .idle)
        #expect(store.turns.isEmpty)

        await store.load(taskID: "t1")
        #expect(store.phase == .loaded)
        #expect(store.turns.flatMap { $0.rows.map(\.text) } == ["hello"])
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

/// The streaming path: the one place in this app that runs once per *token*.
///
/// Its own suite because `upsert` is what a growing reply exercises, and because the figure below
/// is the point of one of these tests rather than a pass or a fail.
@MainActor
@Suite("Streaming path")
struct StreamingPathTests {
    private func store(holding messages: [KandevMessage]) async -> TranscriptStore {
        let source = StubTranscriptSource(
            task: .success(task),
            sessions: .success([session("s1", primary: true)]),
            messages: ["s1": messages]
        )
        let store = TranscriptStore(source: source)
        await store.load(taskID: "t1")
        return store
    }

    /// `upsert` stopped regrouping the whole conversation for every streamed token, so its two
    /// paths need saying out loud: a message it already holds is replaced where it sits, and one it
    /// has never seen is added without disturbing what is there.
    @Test("a streamed update replaces its own row and leaves the rest alone")
    func upsertIsInPlace() async {
        let store = await store(holding: [
            message("m1", author: "user", text: "first", turn: "t1"),
            message("m2", author: "agent", text: "grow", turn: "t2"),
        ])

        store.upsert(message("m2", author: "agent", text: "grown longer", turn: "t2"))

        #expect(store.turns.map(\.id) == ["t1", "t2"])
        #expect(store.turns[0].rows.map(\.text) == ["first"])
        #expect(store.turns[1].rows.map(\.text) == ["grown longer"])

        // An earlier turn, not the one being written: the search walks back to find it.
        store.upsert(message("m1", author: "user", text: "first, edited", turn: "t1"))
        #expect(store.turns[0].rows.map(\.text) == ["first, edited"])
        #expect(store.turns[1].rows.map(\.text) == ["grown longer"])

        // And a message the transcript has never seen still adds a turn, in arrival order.
        store.upsert(message("m3", author: "agent", text: "third", turn: "t3"))
        #expect(store.turns.map(\.id) == ["t1", "t2", "t3"])
        #expect(store.turns[2].rows.map(\.text) == ["third"])
    }

    /// Prints a figure rather than asserting one, because a timing assertion at this scale is flaky
    /// on a loaded machine and the number is the finding.
    ///
    /// It was 3.70 seconds before the streaming update stopped regrouping the conversation, and
    /// 0.74 after. It grows with the conversation, which is the property that matters: the cost is
    /// now bounded by the turn being written rather than by how much has been said before.
    @Test("2000 streamed updates on a 500-message transcript")
    func upsertCost() async {
        let store = await store(holding: (0..<500).map {
            message("m\($0)", author: "agent", text: "line \($0)", turn: "turn-\($0 / 10)")
        })

        let elapsed = await ContinuousClock().measure {
            for i in 0..<2000 {
                store.upsert(
                    message("m\(i % 500)", author: "agent", text: "line \(i)", turn: "turn-\((i % 500) / 10)")
                )
            }
        }
        print("BENCH 2000 streamed updates on a 500-message transcript: \(elapsed)")
    }
}

/// Reading the conversation again, with history already loaded.
@MainActor
@Suite("Transcript refetch")
struct TranscriptRefetchTests {
    /// The newest page, and the one before it — keyed by the cursor the server would hand back,
    /// which is the oldest id in that page.
    private var pages: [String: KandevMessagePage] {
        [
            "": KandevMessagePage(
                messages: [message("m2", author: "agent", text: "the newer half")],
                cursor: "m2",
                hasMore: true
            ),
            "m2": KandevMessagePage(
                messages: [message("m1", author: "user", text: "the older half")],
                cursor: "m1",
                hasMore: false
            ),
        ]
    }

    /// A refetch is a read of the newest page, and the reader may be holding pages older than it.
    /// Replacing the transcript with that page threw their history away and, with it, their place:
    /// they asked for the past and the app handed them the present.
    @Test("a refetch keeps the history that was loaded")
    func refetchKeepsLoadedHistory() async {
        let source = StubTranscriptSource(
            task: .success(task),
            sessions: .success([session("s1", primary: true)]),
            pages: pages
        )
        let store = TranscriptStore(source: source)
        await store.load(taskID: "t1")

        #expect(await store.loadOlder())
        #expect(store.turns.flatMap { $0.rows.map(\.text) } == ["the older half", "the newer half"])
        #expect(store.hasOlder == false)

        // The reader sends something, or the app comes back into view: the newest page is read
        // again, and it carries a message that was not there before — and one whose text has grown.
        await source.setPages([
            "": KandevMessagePage(
                messages: [
                    message("m3", author: "agent", text: "the newest of all"),
                    message("m2", author: "agent", text: "the newer half, edited"),
                ],
                cursor: "m2",
                hasMore: true
            )
        ])
        await store.select(sessionID: "s1", force: true)

        // The history they asked for is still in front of what arrived, and the message that grew
        // was replaced where it sat rather than moved to the end.
        #expect(store.turns.flatMap { $0.rows.map(\.text) } == [
            "the older half", "the newer half, edited", "the newest of all",
        ])
        // Nothing older is claimed to exist, because everything older is already held: a page's
        // cursor and `hasMore` describe that page, not the transcript.
        #expect(store.hasOlder == false)
    }
}
