import Foundation
import Observation

/// Moving one task between workflow steps.
///
/// Its own model rather than a method on the conversation store, because moving
/// is about the task's position and not about its transcript: the step is the
/// process position, and the app should be able to say where a task is and change
/// it without a session existing at all.
@MainActor
@Observable
public final class TaskMoveStore {
    public enum Phase: Equatable {
        case idle
        case previewing
        case moving
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    /// What the move currently chosen would do, once asked.
    public private(set) var preview: KandevTaskMovePreview?
    /// The step being considered. Setting it is what a picker does; the preview
    /// follows.
    public var targetStepID: String? {
        didSet {
            guard targetStepID != oldValue else { return }
            preview = nil
            phase = .idle
        }
    }

    private let mover: any KandevTaskMoving
    private var taskID: String?
    private var workflowID: String?
    private var currentStepID: String?

    public init(mover: any KandevTaskMoving) {
        self.mover = mover
    }

    /// Points the store at a task.
    ///
    /// Called whenever the task is read or re-read, because a task's step is not
    /// known until it has been loaded, and a move changes it. A pending choice
    /// that is no longer a move is dropped: after a task arrives somewhere, the
    /// step it is already in is not a destination.
    public func bind(taskID: String, workflowID: String?, currentStepID: String?) {
        let changed = self.taskID != taskID || self.currentStepID != currentStepID
        self.taskID = taskID
        self.workflowID = workflowID
        self.currentStepID = currentStepID
        if changed, targetStepID == currentStepID {
            targetStepID = nil
            preview = nil
        }
    }

    /// Whether the chosen step is one the task is not already in.
    public var canMove: Bool {
        guard let targetStepID, let workflowID else { return false }
        guard phase != .moving else { return false }
        return targetStepID != currentStepID && !workflowID.isEmpty
    }

    /// One line about what the move will do, if the server has said.
    public var previewSummary: String? { preview?.summary }

    /// Asks what moving would do. A failure here is not worth interrupting for:
    /// the move itself is the action, and this is context.
    public func previewTarget() async {
        guard canMove, let taskID, let targetStepID, let workflowID else { return }
        phase = .previewing
        do {
            preview = try await mover.previewMove(
                taskID: taskID,
                toWorkflowID: workflowID,
                stepID: targetStepID
            )
            phase = .idle
        } catch {
            preview = nil
            phase = .idle
        }
    }

    /// Moves the task. Returns whether it did, so the caller can refetch.
    @discardableResult
    public func move() async -> Bool {
        guard canMove, let taskID, let targetStepID, let workflowID else { return false }
        phase = .moving
        do {
            try await mover.moveTask(
                taskID: taskID,
                toWorkflowID: workflowID,
                stepID: targetStepID
            )
            phase = .idle
            return true
        } catch {
            phase = .failed(KandevError.readableMessage(for: error))
            return false
        }
    }

    /// The failure to show, if there is one.
    public var failure: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }
}
