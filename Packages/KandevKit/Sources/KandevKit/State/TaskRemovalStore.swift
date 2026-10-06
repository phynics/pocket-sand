import Foundation
import Observation

/// Taking a task off the board, or off the server.
///
/// Removal is destructive and, in the delete case, final — so this model's job is
/// as much to hold a pending decision as to perform one. Nothing happens until
/// something is confirmed.
@MainActor
@Observable
public final class TaskRemovalStore {
    /// What is being asked about, and how far the answer goes.
    public enum Action: Equatable {
        /// Off the active board. Reversible.
        case archive
        /// Gone for good.
        case delete
        /// Gone for good, with the uncommitted work in its worktree discarded.
        /// Only reached after the server refused the plain delete.
        case discardAndDelete
    }

    public struct Pending: Equatable {
        public var action: Action
        public var taskID: String
        public var title: String
    }

    /// The decision waiting to be made, if any.
    public private(set) var pending: Pending?
    public private(set) var isWorking = false
    public private(set) var failure: String?
    /// Tasks whose subtasks should come along. On by default: a subtask whose
    /// parent is gone is an orphan, and archiving the parent is usually the
    /// intent.
    public var includesSubTasks = true

    private let remover: any KandevTaskRemoving

    public init(remover: any KandevTaskRemoving) {
        self.remover = remover
    }

    /// Asks before doing. Every removal goes through here: there is no path that
    /// goes straight from a tap to a deletion.
    public func ask(_ action: Action, taskID: String, title: String) {
        failure = nil
        pending = Pending(action: action, taskID: taskID, title: title)
    }

    public func cancel() {
        pending = nil
        failure = nil
    }

    /// Puts an archived task back on the board.
    ///
    /// No confirmation, deliberately. Every other action here asks first because
    /// it destroys something; this one restores, and asking "are you sure you
    /// want this back?" would be ceremony. The asymmetry is the point.
    @discardableResult
    public func unarchive(taskID: String) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do {
            try await remover.unarchiveTask(id: taskID)
            failure = nil
            return true
        } catch {
            failure = KandevError.readableMessage(for: error)
            return false
        }
    }

    /// Carries out the pending decision.
    ///
    /// Returns the task id when the removal succeeded, so the caller can take the
    /// row away. A delete refused because the worktree holds uncommitted work
    /// becomes a new question — `discardAndDelete` — rather than an error, because
    /// the user asked for something reasonable and the server is asking which
    /// thing they meant.
    @discardableResult
    public func confirm() async -> String? {
        guard let pending, !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }

        do {
            switch pending.action {
            case .archive:
                try await remover.archiveTask(id: pending.taskID, cascadeSubTasks: includesSubTasks)

            case .delete, .discardAndDelete:
                let discard = pending.action == .discardAndDelete
                // The route refuses a delete without a ticket, and a ticket is issued for one
                // exact delete — these flags, this person — so it is asked for here rather than
                // kept. The preflight is also where a dirty worktree is reported, which is why it
                // comes before the delete rather than after it failed.
                let preflight = try await remover.taskDeletePreflight(
                    taskIDs: [pending.taskID],
                    cascadeSubTasks: includesSubTasks,
                    discardWorktreeChanges: discard
                )
                if preflight.requiresDiscardConsent, !discard {
                    // Not a failure: a question with a heavier answer. The user asked for
                    // something reasonable and the server is asking which thing they meant.
                    self.pending = Pending(
                        action: .discardAndDelete,
                        taskID: pending.taskID,
                        title: pending.title
                    )
                    failure = nil
                    return nil
                }
                try await remover.deleteTask(
                    id: pending.taskID,
                    cascadeSubTasks: includesSubTasks,
                    discardWorktreeChanges: discard,
                    confirmation: preflight.confirmationID
                )
            }
            self.pending = nil
            failure = nil
            return pending.taskID
        } catch let error as KandevError {
            // The preflight is the ordinary way this question is asked; a delete that refused on
            // its own is the same question arriving late.
            if pending.action == .delete, error.httpErrorCode == KandevTaskRemovalError.dirtyWorktree {
                self.pending = Pending(
                    action: .discardAndDelete,
                    taskID: pending.taskID,
                    title: pending.title
                )
                failure = nil
                return nil
            }
            failure = KandevError.readableMessage(for: error)
            return nil
        } catch {
            failure = KandevError.readableMessage(for: error)
            return nil
        }
    }

    /// The failure to show, if there is one.
    public var failureMessage: String? { failure }
}
