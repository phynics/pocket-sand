import Foundation
import Testing

@testable import KandevKit

/// Task notifications and the hub that fans them out.
///
/// The frames are captured from a live v0.96.0 server during a real agent turn:
/// `task.status_summary.updated` arrived thirteen times, `task.updated` five, and
/// `task.state_changed` twice.
@Suite("KandevTaskUpdate")
struct KandevTaskUpdateTests {
    private func update(_ json: String) throws -> KandevTaskUpdate {
        try JSONDecoder().decode(KandevTaskUpdate.self, from: Data(json.utf8))
    }

    /// Captured: the frequent one. Carries a status summary and nothing else.
    private let summaryFrameRaw = #"""
{"status_summary": {"git": {"additions": 9, "changed_files": 1}, "last_activity_at": "2026-10-04T21:38:05.364674695Z", "primary_session": {"id": "fc606fe7-756b-4e6d-b926-b4fa865cb915", "state": "WAITING_FOR_INPUT"}, "queued_prompt_count": 1, "revision": 14, "updated_at": "2026-10-04T21:38:05.373152766Z"}, "task_id": "96d46f82-a814-4f2e-b990-fd60ba5a2488", "workspace_id": "faf4dd26-22b5-4c6e-ae6a-d0130eb9ea10"}
"""#

    /// Captured: the whole task.
    private let fullTaskFrameRaw = #"""
{"active_subagent_count": 0, "archived_at": null, "assignee_user_id": "", "auto_start_failed": false, "autopilot": false, "created_at": "2026-10-04T21:37:38.05794755Z", "description": "Reply with exactly: READY", "foreground_activity": "generating", "interrupted": false, "is_ephemeral": false, "is_from_office": false, "is_remote_executor": false, "labels": "[]", "metadata": {"workflow_initial_session": {"agent_profile_id": "e689b9e3-89f7-4afa-919a-fb60f589e1ab", "session_id": "fc606fe7-756b-4e6d-b926-b4fa865cb915"}, "workflow_session_route": {"destination_session_id": "fc606fe7-756b-4e6d-b926-b4fa865cb915", "destination_step_id": "1600af22-3442-4f2c-b48c-9599b2c56885", "entry_identity": "entry:00000000000000001922", "operation_id": "workflow-session:96d46f82-a814-4f2e-b990-fd60ba5a2488:1600af22-3442-4f2c-b48c-9599b2c56885:entry:00000000000000001922:profile::reuse", "phase": "committed", "source_session_id": "fc606fe7-756b-4e6d-b926-b4fa865cb915", "target_kind": "profile"}}, "origin": "manual", "parked_epoch": 1790950984864128085, "parked_on_background_work": false, "parked_revision": 0, "position": 1, "primary_agent_name": "ocg/kandev/deepseek-v4.1-flash", "primary_agent_profile_id": null, "primary_executor_id": "exec-worktree", "primary_executor_name": "Worktree", "primary_executor_profile_id": null, "primary_executor_type": "worktree", "primary_session_id": "fc606fe7-756b-4e6d-b926-b4fa865cb915", "primary_session_pending_action": null, "primary_session_state": "RUNNING", "priority": "medium", "queued_at": null, "queued_for_step_id": "", "repositories": [], "runner_editable": false, "runner_ineligible_reason": "no_repository", "session_count": 1, "state": "IN_PROGRESS", "step_transition_id": 1923, "task_id": "96d46f82-a814-4f2e-b990-fd60ba5a2488", "task_pending_action": null, "title": "zz live probe", "updated_at": "2026-10-04T21:38:05.442888209Z", "wip_admitted": true, "workflow_id": "c0d5b387-6bea-4434-a5ab-839ad8240a2f", "workflow_step_id": "d31a4b49-60b8-43cc-98a7-1c37c21d8c6d", "workspace_folders": [], "workspace_id": "faf4dd26-22b5-4c6e-ae6a-d0130eb9ea10", "workspace_orphaned": false}
"""#

    @Test("reads the summary frame, which is what drives a row's spinner")
    func readsSummaryFrame() throws {
        let update = try update(summaryFrameRaw)

        #expect(!update.taskID.isEmpty)
        #expect(update.statusSummary != nil)
        #expect(update.statusSummary?.lastActivityAt?.date != nil)
        #expect(update.title == nil, "the summary frame says nothing about titles")
    }

    @Test("reads the whole-task frame")
    func readsFullTaskFrame() throws {
        let update = try update(fullTaskFrameRaw)

        #expect(!update.taskID.isEmpty)
        #expect(update.title != nil)
        #expect(update.primarySessionState != nil)
    }

    /// The reason this is a patch and not a replacement: the frequent frame has
    /// no title, and a row that lost its title because a spinner changed would be
    /// a worse bug than a stale spinner.
    @Test("a summary frame does not erase fields it did not mention")
    func summaryPatchKeepsEverythingElse() throws {
        let task = KandevTask(
            id: "t1",
            title: "Implement embedded Zenoh transport",
            state: "REVIEW",
            workflowStepID: "step-work",
            sessionCount: 2,
            primarySessionState: "WAITING_FOR_INPUT",
            primaryAgentName: "ocg/kandev/deepseek-v4.1-flash"
        )
        let update = try update(summaryFrameRaw)

        let patched = update.applied(to: task)

        #expect(patched.title == "Implement embedded Zenoh transport")
        #expect(patched.workflowStepID == "step-work")
        #expect(patched.sessionCount == 2)
        #expect(patched.primaryAgentName == "ocg/kandev/deepseek-v4.1-flash")
        #expect(patched.statusSummary != nil, "the frame's summary should have landed")
    }

    @Test("a full-task frame does replace the fields it carries")
    func fullFrameReplacesFields() throws {
        let task = KandevTask(id: "t1", title: "Old title", state: "CREATED")
        let update = try update(fullTaskFrameRaw)

        let patched = update.applied(to: task)

        #expect(patched.title == update.title)
        #expect(patched.state == update.state)
        #expect(patched.primarySessionState == update.primarySessionState)
    }
}

/// A source whose frames a test can push by hand.
final class StubSource: KandevNotificationHub.Source, @unchecked Sendable {
    let notifications: AsyncStream<KandevEnvelope>
    private let continuation: AsyncStream<KandevEnvelope>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<KandevEnvelope>.makeStream()
        notifications = stream
        self.continuation = continuation
    }

    func yield(_ action: String, _ payload: JSONValue) {
        continuation.yield(KandevEnvelope(type: .notification, action: action, payload: payload))
    }

    func finish() { continuation.finish() }
}

@Suite("KandevNotificationHub")
struct KandevNotificationHubTests {
    private func taskPayload(id: String, title: String?) -> JSONValue {
        var members: [String: JSONValue] = ["task_id": .string(id)]
        if let title { members["title"] = .string(title) }
        return .object(members)
    }

    private func changePayload(session: String, scope: String, revision: String) -> JSONValue {
        .object([
            "session_id": .string(session),
            "scope_id": .string(scope),
            "epoch": .string("e1"),
            "base_revision": .string("1"),
            "revision": .string(revision),
            "operations": .array([]),
        ])
    }

    /// The reason the hub exists: two screens cannot both read the transport
    /// stream, so both read the hub instead.
    @Test("forwards a task update to every task subscriber")
    func fansOutToEveryTaskSubscriber() async {
        let source = StubSource()
        let hub = KandevNotificationHub(source: source)
        await hub.start()

        let first = await hub.taskSignals()
        let second = await hub.taskSignals()
        var firstIterator = first.makeAsyncIterator()
        var secondIterator = second.makeAsyncIterator()

        source.yield(KandevAction.taskUpdated, taskPayload(id: "t1", title: "One"))

        #expect(await firstIterator.next()?.update.taskID == "t1")
        #expect(await secondIterator.next()?.update.taskID == "t1")
    }

    @Test("delivers a conversation change only to the session and scope it belongs to")
    func filtersConversationChanges() async {
        let source = StubSource()
        let hub = KandevNotificationHub(source: source)
        await hub.start()

        let mine = await hub.conversationChanges(sessionID: "s1", scopeID: "core:ios:mine")
        var mineIterator = mine.makeAsyncIterator()
        let theirs = await hub.conversationChanges(sessionID: "s1", scopeID: "core:web:theirs")
        var theirsIterator = theirs.makeAsyncIterator()
        let otherSession = await hub.conversationChanges(sessionID: "s2", scopeID: "core:ios:mine")
        var otherSessionIterator = otherSession.makeAsyncIterator()

        source.yield(
            KandevAction.sessionConversationChanged,
            changePayload(session: "s1", scope: "core:ios:mine", revision: "2")
        )
        source.yield(
            KandevAction.sessionConversationChanged,
            changePayload(session: "s1", scope: "core:web:theirs", revision: "3")
        )

        #expect(await mineIterator.next()?.revision == "2")
        #expect(await theirsIterator.next()?.revision == "3")
        // The frame for s1 must never reach the subscriber watching s2.
        source.yield(
            KandevAction.sessionConversationChanged,
            changePayload(session: "s2", scope: "core:ios:mine", revision: "4")
        )
        #expect(await otherSessionIterator.next()?.revision == "4")
    }

    @Test("narrows task updates to a workspace when asked")
    func filtersByWorkspace() async {
        let source = StubSource()
        let hub = KandevNotificationHub(source: source)
        await hub.start()

        let wanted = await hub.taskSignals(workspaceID: "w1")
        var wantedIterator = wanted.makeAsyncIterator()

        source.yield(
            KandevAction.taskUpdated,
            .object(["task_id": .string("other"), "workspace_id": .string("w2")])
        )
        source.yield(
            KandevAction.taskUpdated,
            .object(["task_id": .string("mine"), "workspace_id": .string("w1")])
        )

        #expect(await wantedIterator.next()?.update.taskID == "mine")
    }

    /// An unreadable frame must not stop the stream: one unknown shape would
    /// otherwise take the live updates down with it.
    @Test("survives a frame it cannot decode")
    func survivesUndecodableFrame() async {
        let source = StubSource()
        let hub = KandevNotificationHub(source: source)
        await hub.start()

        let updates = await hub.taskSignals()
        var iterator = updates.makeAsyncIterator()

        source.yield(KandevAction.taskUpdated, .string("not an object"))
        source.yield(KandevAction.taskUpdated, taskPayload(id: "after", title: nil))

        #expect(await iterator.next()?.update.taskID == "after")
    }

    @Test("ignores actions it does not read")
    func ignoresUnknownActions() async {
        let source = StubSource()
        let hub = KandevNotificationHub(source: source)
        await hub.start()

        let updates = await hub.taskSignals()
        var iterator = updates.makeAsyncIterator()

        source.yield("office.task.updated", taskPayload(id: "office", title: nil))
        source.yield(KandevAction.taskUpdated, taskPayload(id: "real", title: nil))

        #expect(await iterator.next()?.update.taskID == "real")
    }

    @Test("finishes its subscribers when it stops")
    func finishesOnStop() async {
        let source = StubSource()
        let hub = KandevNotificationHub(source: source)
        await hub.start()

        let updates = await hub.taskSignals()
        var iterator = updates.makeAsyncIterator()

        await hub.stop()

        #expect(await iterator.next() == nil)
    }
}

@Suite("KandevNotificationHub task lifecycle")
struct KandevTaskLifecycleTests {
    private func hub() async -> (KandevNotificationHub, StubSource) {
        let source = StubSource()
        let hub = KandevNotificationHub(source: source)
        await hub.start()
        return (hub, source)
    }

    /// A list that only watched `task.updated` would never notice new work: the
    /// server announces a creation with its own frame.
    @Test("a created task is delivered as an update, so the list can catch up")
    func createdTaskIsDelivered() async {
        let (hub, source) = await hub()
        let updates = await hub.taskSignals()
        var iterator = updates.makeAsyncIterator()

        source.yield(
            KandevAction.taskCreated,
            .object(["task_id": .string("brand-new"), "workspace_id": .string("w1")])
        )

        let signal = await iterator.next()
        #expect(signal?.update.taskID == "brand-new")
        #expect(signal?.kind == .created)
    }

    @Test("a deleted task is delivered too, because a row has to be able to go")
    func deletedTaskIsDelivered() async {
        let (hub, source) = await hub()
        let updates = await hub.taskSignals()
        var iterator = updates.makeAsyncIterator()

        source.yield(KandevAction.taskDeleted, .object(["task_id": .string("gone")]))

        let signal = await iterator.next()
        #expect(signal?.update.taskID == "gone")
        #expect(signal?.kind == .deleted, "a deletion must be distinguishable from an update")
    }

    @Test("an archived task is delivered, because it leaves the default list")
    func archivedTaskIsDelivered() async {
        let (hub, source) = await hub()
        let updates = await hub.taskSignals()
        var iterator = updates.makeAsyncIterator()

        source.yield(KandevAction.taskArchived, .object(["task_id": .string("archived")]))

        #expect(await iterator.next()?.kind == .archived)
    }
}

@Suite("KandevNotificationHub session state")
struct SessionStateHubTests {
    private func hub() async -> (KandevNotificationHub, StubSource) {
        let source = StubSource()
        let hub = KandevNotificationHub(source: source)
        await hub.start()
        return (hub, source)
    }

    /// Captured from a live server while an agent worked.
    @Test("delivers a session's state change")
    func deliversSessionState() async {
        let (hub, source) = await hub()
        let stream = await hub.sessionStateChanges()
        var iterator = stream.makeAsyncIterator()

        source.yield(
            KandevAction.sessionStateChanged,
            .object([
                "session_id": .string("s1"),
                "task_id": .string("t1"),
                "old_state": .string("WAITING_FOR_INPUT"),
                "new_state": .string("RUNNING"),
                "foreground_activity": .string("generating"),
                "is_primary": .bool(true),
                "updated_at": .string("2026-10-04T21:38:05.39547914Z"),
            ])
        )

        let change = await iterator.next()
        #expect(change?.sessionID == "s1")
        #expect(change?.taskID == "t1")
        #expect(change?.newState == "RUNNING")
        #expect(change?.isWorking == true)
    }

    /// The frame names its task but not its workspace, so it cannot be narrowed
    /// by workspace and is not offered as if it could.
    @Test("reaches every subscriber, whatever they are watching")
    func reachesAllSubscribers() async {
        let (hub, source) = await hub()
        let first = await hub.sessionStateChanges()
        let second = await hub.sessionStateChanges()
        var firstIterator = first.makeAsyncIterator()
        var secondIterator = second.makeAsyncIterator()

        source.yield(KandevAction.sessionStateChanged, .object(["session_id": .string("s1")]))

        #expect(await firstIterator.next()?.sessionID == "s1")
        #expect(await secondIterator.next()?.sessionID == "s1")
    }
}
