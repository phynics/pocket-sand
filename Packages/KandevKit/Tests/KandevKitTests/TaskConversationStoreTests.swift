import Foundation
import Testing

@testable import KandevKit

/// The screen's model: reading a conversation and writing to it, in the right
/// order. This order is the reason the type exists — spread across a view body,
/// none of it would be testable.
@MainActor
@Suite("TaskConversationStore")
struct TaskConversationStoreTests {
    private func makeSession() -> KandevSession {
        KandevSession(
            id: "s1",
            taskID: "t1",
            name: "ocg/kandev/deepseek-v4.1-flash",
            state: "WAITING_FOR_INPUT",
            isPrimary: true,
            queueIncarnationID: "inc-1"
        )
    }

    private func loaded(
        sessions: [KandevSession],
        messages: [KandevMessage] = []
    ) async -> (TaskConversationStore, StubTranscriptSource, StubPromptSource) {
        let transcriptSource = StubTranscriptSource(
            task: .success(KandevTask(id: "t1", title: "A task", sessionCount: sessions.count)),
            sessions: .success(sessions),
            messages: ["s1": messages]
        )
        let promptSource = StubPromptSource()
        let store = TaskConversationStore(
            transcriptSource: transcriptSource,
            promptSource: promptSource
        )
        await store.load(taskID: "t1")
        return (store, transcriptSource, promptSource)
    }

    @Test("loading a task points the composer at the chosen session")
    func loadBindsComposer() async {
        let (store, _, promptSource) = await loaded(sessions: [makeSession()])

        #expect(store.composer.identity?.sessionID == "s1")
        #expect(store.composer.identity?.taskID == "t1")
        #expect(store.composer.identity?.sessionIncarnationID == "inc-1")
        let queueReads = await promptSource.queueReads
        #expect(queueReads > 0, "binding should read the queue so the composer can show it")
    }

    @Test("a task with no session leaves the composer unable to send")
    func noSessionDisablesComposer() async {
        let (store, _, _) = await loaded(sessions: [])
        store.composer.draft = "hello"

        #expect(store.transcript.hasNoSession)
        #expect(store.composer.identity == nil)
        #expect(store.composer.canSend == false)
    }

    /// Without an incarnation id a prompt cannot be addressed, so the composer is
    /// disabled rather than left to send something the server will reject.
    @Test("a session without an incarnation id disables the composer")
    func missingIncarnationDisablesComposer() async {
        let session = KandevSession(id: "s1", taskID: "t1", isPrimary: true)
        let (store, _, _) = await loaded(sessions: [session])
        store.composer.draft = "hello"

        #expect(store.composer.identity == nil)
        #expect(store.composer.canSend == false)
    }

    @Test("sending refetches the transcript so the prompt appears without a pull")
    func sendRefetchesTranscript() async {
        let (store, transcriptSource, promptSource) = await loaded(sessions: [makeSession()])
        #expect(store.transcript.turns.isEmpty)

        // The server now knows about the prompt.
        await transcriptSource.setMessages(
            [
                KandevMessage(
                    id: "m1",
                    authorType: "user",
                    type: "message",
                    content: "Reply with exactly: OK",
                    turnID: "turn-1"
                )
            ],
            forSession: "s1"
        )
        store.composer.draft = "Reply with exactly: OK"

        let sent = await store.send()

        #expect(sent)
        let prompts = await promptSource.sentPrompts
        #expect(prompts.map(\.content) == ["Reply with exactly: OK"])
        #expect(store.transcript.turns.first?.rows.first?.text == "Reply with exactly: OK")
    }

    @Test("a send the server refuses does not refetch anything")
    func refusedSendDoesNotRefetch() async {
        let (store, transcriptSource, promptSource) = await loaded(sessions: [makeSession()])
        let readsBefore = await transcriptSource.requestedSessions.count
        await promptSource.failNextSend(with: KandevError.queueFull(limit: 5))
        store.composer.draft = "hello"

        let sent = await store.send()

        #expect(sent == false)
        let readsAfter = await transcriptSource.requestedSessions.count
        #expect(readsAfter == readsBefore)
        #expect(store.composer.draft == "hello")
    }

    @Test("interrupting also refetches, because the transcript changed")
    func interruptRefetches() async {
        let (store, transcriptSource, promptSource) = await loaded(sessions: [makeSession()])
        let readsBefore = await transcriptSource.requestedSessions.count

        let sent = await store.interruptAndSend(entryID: "q1")

        #expect(sent)
        let readsAfter = await transcriptSource.requestedSessions.count
        #expect(readsAfter > readsBefore)
        let interruptions = await promptSource.interruptions
        #expect(interruptions == ["q1"])
    }

    @Test("refetching the transcript keeps the session that is open")
    func reloadKeepsSession() async {
        let (store, _, _) = await loaded(sessions: [makeSession()])

        await store.reloadTranscript()

        #expect(store.transcript.selectedSessionID == "s1")
    }

    @Test("refetching with no session open does nothing rather than guessing one")
    func reloadWithoutSessionIsANoOp() async {
        let (store, transcriptSource, _) = await loaded(sessions: [])
        let readsBefore = await transcriptSource.requestedSessions.count

        await store.reloadTranscript()

        let readsAfter = await transcriptSource.requestedSessions.count
        #expect(readsAfter == readsBefore)
    }
}
