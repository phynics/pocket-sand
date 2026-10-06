import Foundation
import Testing

@testable import KandevKit

/// What a row derives from a task, as opposed to what the server says outright.
@Suite("Task row")
struct TaskRowTests {
    private func task(
        id: String = "t1",
        title: String = "A task",
        state: String? = "IN_PROGRESS",
        sessionState: String? = nil,
        pendingAction: String? = nil,
        sessionPendingAction: String? = nil,
        parentID: String? = nil
    ) -> KandevTask {
        KandevTask(
            id: id,
            title: title,
            state: state,
            parentID: parentID,
            primarySessionState: sessionState,
            taskPendingAction: pendingAction,
            primarySessionPendingAction: sessionPendingAction
        )
    }

    /// `FAILED` is what the server sends, on the task or on its session. Either one is
    /// the task failing, and the row is what turns that into a red spine.
    @Test("a task the server called failed is failed")
    func failureIsReadFromTheServer() {
        #expect(task(state: "FAILED").isFailed)
        #expect(task(state: "IN_PROGRESS", sessionState: "FAILED").isFailed)
        #expect(task(state: "in_progress").isFailed == false)
        #expect(task(state: "REVIEW").isFailed == false, "waiting for a person is not failing")
        #expect(task(state: nil).isFailed == false)
    }

    /// Stronger than "needs attention": an agent that asked something has stopped, where
    /// a review gate has not.
    @Test("a pending action means an agent is waiting on an answer")
    func pendingActionMeansAnswering() {
        #expect(task(pendingAction: "review").isAwaitingAnswer)
        #expect(task(sessionPendingAction: "question").isAwaitingAnswer)
        #expect(task(pendingAction: "").isAwaitingAnswer == false, "an empty action is no action")
        #expect(task().isAwaitingAnswer == false)
    }

    /// The list needs the parent to nest a row, and the depth to indent it.
    @Test("a row carries its parent, and starts at depth zero")
    func rowCarriesItsParent() {
        let row = TaskRow(task: task(parentID: "parent-1"), steps: [:])
        #expect(row.parentID == "parent-1")
        #expect(row.depth == 0, "the list decides the depth, not the task")
    }

    /// A step the catalogue does not know leaves the row without a name rather than with
    /// a wrong one, and the store counts those to report them.
    @Test("a row resolves its step name from the catalogue")
    func stepNameComesFromTheCatalogue() {
        let steps = [
            "s1": KandevWorkflowStep(id: "s1", workflowID: "w", name: "Review", position: 1, color: "bg-yellow-500"),
        ]
        var withStep = task()
        withStep.workflowStepID = "s1"
        let row = TaskRow(task: withStep, steps: steps)

        #expect(row.stepName == "Review")
        #expect(row.stepColor == "bg-yellow-500")

        var unknown = task()
        unknown.workflowStepID = "missing"
        #expect(TaskRow(task: unknown, steps: steps).stepName == nil)
    }
}

/// The order the reader's own state implies. The server has never heard of it, so it is decided
/// here and can be asserted here.
@Suite("Rows that want reading")
struct TaskRowOrderTests {
    private func row(_ id: String, depth: Int = 0) -> TaskRow {
        TaskRow(
            id: id,
            title: id,
            stepName: nil,
            isWorking: false,
            depth: depth,
            lastActivity: .now
        )
    }

    @Test("rows that want reading come first, and keep the order they had")
    func unreadFirstIsStable() {
        let ordered = [row("a"), row("b"), row("c")]
            .unreadFirst { $0.id == "c" || $0.id == "a" }

        #expect(ordered.map(\.id) == ["a", "c", "b"])
    }

    /// A subtask sorted above its own parent would make the indent column a lie, so a task and the
    /// rows under it move together.
    @Test("a subtask moves with its parent, never above it")
    func subtasksMoveWithTheirParent() {
        let rows = [row("a"), row("a1", depth: 1), row("b"), row("b1", depth: 1)]

        let ordered = rows.unreadFirst { $0.id == "b" }

        #expect(ordered.map(\.id) == ["b", "b1", "a", "a1"])
    }

    @Test("nothing moves when nothing wants reading")
    func nothingMoves() {
        let rows = [row("a"), row("a1", depth: 1), row("b")]

        #expect(rows.unreadFirst { _ in false }.map(\.id) == ["a", "a1", "b"])
    }
}
