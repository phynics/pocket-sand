import Foundation
import Testing

@testable import KandevKit

/// A mover with no server behind it.
actor StubTaskMover: KandevTaskMoving {
    private(set) var moves: [(taskID: String, workflowID: String, stepID: String)] = []
    private(set) var previews = 0
    var previewResult: Result<KandevTaskMovePreview, any Error> = .success(
        KandevTaskMovePreview(taskID: "t1", workflowStepID: "s2", outcome: "reuse_current")
    )
    var moveFailure: (any Error)?

    func setPreview(_ preview: KandevTaskMovePreview) { previewResult = .success(preview) }
    func failPreview(with error: any Error) { previewResult = .failure(error) }
    func failMove(with error: any Error) { moveFailure = error }

    func previewMove(
        taskID: String,
        toWorkflowID: String,
        stepID: String
    ) async throws -> KandevTaskMovePreview {
        previews += 1
        return try previewResult.get()
    }

    func moveTask(taskID: String, toWorkflowID: String, stepID: String) async throws {
        if let moveFailure {
            self.moveFailure = nil
            throw moveFailure
        }
        moves.append((taskID: taskID, workflowID: toWorkflowID, stepID: stepID))
    }
}

@Suite("KandevTaskMovePreview")
struct KandevTaskMovePreviewTests {
    private func preview(_ json: String) throws -> KandevTaskMovePreview {
        try JSONDecoder().decode(KandevTaskMovePreview.self, from: Data(json.utf8))
    }

    /// Shaped like the first-party client's own type for this endpoint.
    @Test("reads a preview, recipient and all")
    func decodesPreview() throws {
        let decoded = try preview(
            #"""
            {
              "task_id": "t1",
              "workflow_step_id": "s-review",
              "source_session_id": "sess-1",
              "evaluated_at": "2026-10-04T21:38:05.364674695Z",
              "outcome": "reuse_other",
              "recipient": {
                "session_id": "sess-2",
                "session_name": "reviewer",
                "profile_id": "p2",
                "profile_name": "opus",
                "agent_family": "claude"
              },
              "model": {"before": {"id": "a"}, "after": {"id": "b"}}
            }
            """#
        )

        #expect(decoded.outcome == "reuse_other")
        #expect(decoded.recipient?.sessionName == "reviewer")
        #expect(decoded.evaluatedAt?.date != nil)
        #expect(decoded.summary == "Continues in reviewer")
        #expect(decoded.startsOrContinuesWork)
    }

    @Test("describes each outcome it knows")
    func describesOutcomes() throws {
        let cases: [(String, String, String)] = [
            ("reuse_current", #"{"outcome":"reuse_current"}"#, "Continues in the current session"),
            ("reuse_other", #"{"outcome":"reuse_other"}"#, "Continues in another session on this task"),
            ("create_new", #"{"outcome":"create_new"}"#, "Starts a new session"),
            ("no_session", #"{"outcome":"no_session"}"#, "No session runs here yet"),
        ]

        for (name, json, expected) in cases {
            #expect(try preview(json).summary == expected, "\(name) produced the wrong words")
        }
    }

    @Test("names the session or the profile when the server sent one")
    func namesTheRecipient() throws {
        let withProfile = try preview(
            #"{"outcome":"create_new","recipient":{"profile_name":"deepseek"}}"#
        )
        #expect(withProfile.summary == "Starts a new session with deepseek")
    }

    /// An outcome this client has not heard of is said plainly — by saying
    /// nothing — rather than described wrongly.
    @Test("an unknown outcome is not described at all")
    func unknownOutcomeHasNoSummary() throws {
        let decoded = try preview(#"{"outcome":"something_new"}"#)

        #expect(decoded.summary == nil)
        #expect(decoded.startsOrContinuesWork == false)
    }

    @Test("a preview with no outcome at all does not fail to decode")
    func toleratesMissingOutcome() throws {
        let decoded = try preview(#"{"task_id":"t1"}"#)

        #expect(decoded.outcome == nil)
        #expect(decoded.summary == nil)
    }
}

@MainActor
@Suite("TaskMoveStore")
struct TaskMoveStoreTests {
    private func bound(
        currentStepID: String = "s1",
        workflowID: String? = "wf1"
    ) -> (TaskMoveStore, StubTaskMover) {
        let mover = StubTaskMover()
        let store = TaskMoveStore(mover: mover)
        store.bind(taskID: "t1", workflowID: workflowID, currentStepID: currentStepID)
        return (store, mover)
    }

    @Test("cannot move until a different step is chosen")
    func cannotMoveWithoutATarget() async {
        let (store, mover) = bound()

        #expect(store.canMove == false)
        #expect(await store.move() == false)
        let moves = await mover.moves
        #expect(moves.isEmpty)
    }

    /// The step a task is already in is not a destination.
    @Test("cannot move to the step the task is already in")
    func refusesTheCurrentStep() async {
        let (store, _) = bound(currentStepID: "s1")

        store.targetStepID = "s1"

        #expect(store.canMove == false)
    }

    @Test("moving sends the task, the workflow, and the step")
    func moves() async {
        let (store, mover) = bound()
        store.targetStepID = "s2"

        let moved = await store.move()

        #expect(moved)
        let moves = await mover.moves
        #expect(moves.count == 1)
        #expect(moves.first?.taskID == "t1")
        #expect(moves.first?.workflowID == "wf1")
        #expect(moves.first?.stepID == "s2")
    }

    /// A move crosses workflows as well as steps, so a task with no workflow
    /// cannot be moved at all rather than moved to the wrong place.
    @Test("cannot move a task whose workflow is unknown")
    func refusesWithoutAWorkflow() async {
        let (store, mover) = bound(workflowID: nil)
        store.targetStepID = "s2"

        #expect(store.canMove == false)
        #expect(await store.move() == false)
        let moves = await mover.moves
        #expect(moves.isEmpty)
    }

    @Test("asks the server what the move would do, and shows what it says")
    func previews() async {
        let (store, mover) = bound()
        await mover.setPreview(
            KandevTaskMovePreview(
                taskID: "t1",
                workflowStepID: "s2",
                outcome: "create_new",
                recipient: .init(sessionName: nil, profileName: "deepseek")
            )
        )
        store.targetStepID = "s2"

        await store.previewTarget()

        #expect(store.previewSummary == "Starts a new session with deepseek")
        let previews = await mover.previews
        #expect(previews == 1)
    }

    /// The preview is context, not the action: failing to get one must not stop
    /// the move from being offered.
    @Test("a failed preview leaves the move available and says nothing")
    func failedPreviewIsQuiet() async {
        let mover = StubTaskMover()
        await mover.failPreview(with: KandevError.connectionClosed)
        let store = TaskMoveStore(mover: mover)
        store.bind(taskID: "t1", workflowID: "wf1", currentStepID: "s1")
        store.targetStepID = "s2"

        await store.previewTarget()

        #expect(store.previewSummary == nil)
        #expect(store.canMove, "the move itself is still on offer")
        if case .failed = store.phase {
            Issue.record("a failed preview should not be reported as a failure")
        }
    }

    @Test("a refused move is reported and the choice survives to retry")
    func refusedMoveIsReported() async {
        let (store, mover) = bound()
        await mover.failMove(
            with: KandevError.http(status: 409, body: #"{"error":"step_changed"}"#)
        )
        store.targetStepID = "s2"

        let moved = await store.move()

        #expect(moved == false)
        #expect(store.failure != nil)
        #expect(store.targetStepID == "s2", "the choice should survive so it can be retried")
    }

    /// Choosing a different step must not leave the previous step's preview on
    /// screen describing a move that is no longer the one on offer.
    @Test("changing the target clears the previous preview")
    func changingTargetClearsThePreview() async {
        let (store, mover) = bound()
        await mover.setPreview(KandevTaskMovePreview(outcome: "reuse_current"))
        store.targetStepID = "s2"
        await store.previewTarget()
        #expect(store.previewSummary != nil)

        store.targetStepID = "s3"

        #expect(store.previewSummary == nil)
    }

    /// After a move the task is somewhere new, so the step it is in is no longer
    /// a destination and the pending choice is stale.
    @Test("rebinding to the arrived-at step drops the pending choice")
    func rebindingDropsAStaleChoice() async {
        let (store, _) = bound(currentStepID: "s1")
        store.targetStepID = "s2"

        store.bind(taskID: "t1", workflowID: "wf1", currentStepID: "s2")

        #expect(store.targetStepID == nil)
        #expect(store.canMove == false)
    }
}
