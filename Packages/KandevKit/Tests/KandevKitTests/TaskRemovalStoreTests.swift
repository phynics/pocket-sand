import Foundation
import Testing

@testable import KandevKit

/// A remover with no server behind it.
actor StubTaskRemover: KandevTaskRemoving {
    struct Call: Equatable {
        var kind: String
        var id: String
        var cascade: Bool
        var discard: Bool
        /// The ticket a delete carried, when it was one.
        var confirmation: String? = nil
    }

    private(set) var calls: [Call] = []
    var archiveFailure: (any Error)?
    var deleteFailure: (any Error)?
    var unarchiveFailure: (any Error)?
    /// What the preflight answers with. A dirty worktree is a field on it, not a failure.
    var preflight = KandevTaskDeletePreflight(confirmationID: "ticket-1")
    var preflightFailure: (any Error)?

    func failArchive(with error: any Error) { archiveFailure = error }
    func failDelete(with error: any Error) { deleteFailure = error }
    func failUnarchive(with error: any Error) { unarchiveFailure = error }
    func failPreflight(with error: any Error) { preflightFailure = error }

    func setPreflight(requiresDiscardConsent: Bool, confirmationID: String = "ticket-1") {
        preflight = KandevTaskDeletePreflight(
            requiresDiscardConsent: requiresDiscardConsent,
            confirmationID: confirmationID
        )
    }

    func unarchiveTask(id: String) async throws {
        calls.append(Call(kind: "unarchive", id: id, cascade: false, discard: false))
        if let unarchiveFailure {
            self.unarchiveFailure = nil
            throw unarchiveFailure
        }
    }

    func archiveTask(id: String, cascadeSubTasks: Bool) async throws {
        calls.append(Call(kind: "archive", id: id, cascade: cascadeSubTasks, discard: false))
        if let archiveFailure {
            self.archiveFailure = nil
            throw archiveFailure
        }
    }

    func taskDeletePreflight(
        taskIDs: [String],
        cascadeSubTasks: Bool,
        discardWorktreeChanges: Bool
    ) async throws -> KandevTaskDeletePreflight {
        calls.append(
            Call(
                kind: "preflight",
                id: taskIDs.first ?? "",
                cascade: cascadeSubTasks,
                discard: discardWorktreeChanges
            )
        )
        if let preflightFailure {
            self.preflightFailure = nil
            throw preflightFailure
        }
        return preflight
    }

    func deleteTask(
        id: String,
        cascadeSubTasks: Bool,
        discardWorktreeChanges: Bool,
        confirmation: String?
    ) async throws {
        calls.append(
            Call(
                kind: "delete",
                id: id,
                cascade: cascadeSubTasks,
                discard: discardWorktreeChanges,
                confirmation: confirmation
            )
        )
        if let deleteFailure {
            self.deleteFailure = nil
            throw deleteFailure
        }
    }
}

@Suite("KandevError.httpErrorCode")
struct HTTPErrorCodeTests {
    /// The envelope is the server's business, so all the plausible shapes are
    /// read. A shape that is not recognised yields nothing rather than a guess.
    @Test("finds the code in each shape the server might use")
    func readsKnownShapes() {
        let shapes = [
            #"{"code":"task_delete_dirty_worktree"}"#,
            #"{"error":"task_delete_dirty_worktree"}"#,
            #"{"error":{"code":"task_delete_dirty_worktree"}}"#,
            #"{"error":{"code":"task_delete_dirty_worktree","message":"dirty"}}"#,
        ]

        for body in shapes {
            let error = KandevError.http(status: 409, body: body)
            #expect(error.httpErrorCode == "task_delete_dirty_worktree", "missed \(body)")
        }
    }

    @Test("says nothing rather than guessing")
    func refusesToGuess() {
        #expect(KandevError.http(status: 500, body: "not json").httpErrorCode == nil)
        #expect(KandevError.http(status: 500, body: nil).httpErrorCode == nil)
        #expect(KandevError.http(status: 500, body: #"{"message":"no code here"}"#).httpErrorCode == nil)
        #expect(KandevError.connectionClosed.httpErrorCode == nil)
    }
}

@MainActor
@Suite("TaskRemovalStore")
struct TaskRemovalStoreTests {
    private func store() -> (TaskRemovalStore, StubTaskRemover) {
        let remover = StubTaskRemover()
        return (TaskRemovalStore(remover: remover), remover)
    }

    /// Nothing is removed without a decision: there is no path from a tap
    /// straight to a deletion.
    @Test("does nothing until something is confirmed")
    func nothingHappensUnprompted() async {
        let (store, remover) = store()

        #expect(store.pending == nil)
        #expect(await store.confirm() == nil)
        let calls = await remover.calls
        #expect(calls.isEmpty)
    }

    @Test("archives what it was asked about, subtasks included by default")
    func archives() async {
        let (store, remover) = store()
        store.ask(.archive, taskID: "t1", title: "A task")

        let removed = await store.confirm()

        #expect(removed == "t1")
        #expect(store.pending == nil)
        let calls = await remover.calls
        #expect(calls == [.init(kind: "archive", id: "t1", cascade: true, discard: false)])
    }

    @Test("archives without subtasks when that is turned off")
    func archiveWithoutSubTasks() async {
        let (store, remover) = store()
        store.includesSubTasks = false
        store.ask(.archive, taskID: "t1", title: "A task")

        _ = await store.confirm()

        let calls = await remover.calls
        #expect(calls.first?.cascade == false)
    }

    @Test("deletes without discarding anything, first time")
    func deletesWithoutDiscarding() async {
        let (store, remover) = store()
        store.ask(.delete, taskID: "t1", title: "A task")

        _ = await store.confirm()

        // The preflight first, and the delete carrying the ticket it answered with — the route
        // refuses a delete without one.
        let calls = await remover.calls
        #expect(calls == [
            .init(kind: "preflight", id: "t1", cascade: true, discard: false),
            .init(kind: "delete", id: "t1", cascade: true, discard: false, confirmation: "ticket-1"),
        ])
    }

    /// The refusal is a question, not a failure: the user asked for something
    /// reasonable and the server is asking which thing they meant. Reporting an
    /// error would be wrong, and silently retrying with the work discarded would
    /// be worse.
    @Test("a dirty worktree turns a deletion into a heavier question")
    func dirtyWorktreeAsksAgain() async {
        let (store, remover) = store()
        await remover.setPreflight(requiresDiscardConsent: true)
        store.ask(.delete, taskID: "t1", title: "A task")

        let removed = await store.confirm()

        #expect(removed == nil, "nothing was removed yet")
        #expect(store.pending?.action == .discardAndDelete)
        #expect(store.pending?.taskID == "t1")
        #expect(store.failure == nil, "this is a question, not a failure")
        let calls = await remover.calls
        #expect(calls.count == 1, "nothing should be retried on its own")
        #expect(calls.first?.kind == "preflight")
    }

    @Test("answering the heavier question discards and deletes")
    func discardingDeletes() async {
        let (store, remover) = store()
        await remover.setPreflight(requiresDiscardConsent: true)
        store.ask(.delete, taskID: "t1", title: "A task")
        _ = await store.confirm()

        let removed = await store.confirm()

        #expect(removed == "t1")
        let calls = await remover.calls
        #expect(
            calls.last == .init(kind: "delete", id: "t1", cascade: true, discard: true, confirmation: "ticket-1")
        )
    }

    /// Without a ticket there is nothing to delete with, so a preflight that fails must stop there
    /// rather than send a delete the route will refuse.
    @Test("a refused preflight is reported and nothing is deleted")
    func refusedPreflightIsReported() async {
        let (store, remover) = store()
        await remover.failPreflight(with: KandevError.connectionClosed)
        store.ask(.delete, taskID: "t1", title: "A task")

        let removed = await store.confirm()

        #expect(removed == nil)
        #expect(store.failure != nil)
        let calls = await remover.calls
        #expect(calls.contains { $0.kind == "delete" } == false)
    }

    /// A delete refused for some other reason is a failure, and must not be
    /// mistaken for the dirty-worktree question.
    @Test("a refusal for another reason is reported as a failure")
    func otherRefusalsAreFailures() async {
        let (store, remover) = store()
        await remover.failDelete(
            with: KandevError.http(status: 500, body: #"{"code":"internal_error"}"#)
        )
        store.ask(.delete, taskID: "t1", title: "A task")

        let removed = await store.confirm()

        #expect(removed == nil)
        #expect(store.pending?.action == .delete, "still the decision that was asked for")
        #expect(store.failure != nil)
    }

    @Test("a failed archive is reported and leaves the question standing")
    func failedArchiveIsReported() async {
        let (store, remover) = store()
        await remover.failArchive(with: KandevError.connectionClosed)
        store.ask(.archive, taskID: "t1", title: "A task")

        let removed = await store.confirm()

        #expect(removed == nil)
        #expect(store.failure != nil)
        #expect(store.pending?.action == .archive, "so it can be tried again")
    }

    @Test("cancelling drops the question and any failure with it")
    func cancelClears() async {
        let (store, remover) = store()
        await remover.failArchive(with: KandevError.connectionClosed)
        store.ask(.archive, taskID: "t1", title: "A task")
        _ = await store.confirm()
        #expect(store.failure != nil)

        store.cancel()

        #expect(store.pending == nil)
        #expect(store.failure == nil)
    }

    @Test("asking about something new clears the previous failure")
    func askingAgainClearsFailure() async {
        let (store, remover) = store()
        await remover.failArchive(with: KandevError.connectionClosed)
        store.ask(.archive, taskID: "t1", title: "A task")
        _ = await store.confirm()

        store.ask(.delete, taskID: "t2", title: "Another")

        #expect(store.failure == nil)
        #expect(store.pending?.taskID == "t2")
    }
}

@MainActor
@Suite("TaskListStore.removeRow")
struct RemoveRowTests {
    private func loaded() async -> TaskListStore {
        let source = FakeTaskSource()
        await source.setWorkspaces([workspace])
        await source.setWorkflows([KandevWorkflow(id: "wf1", name: "Development")])
        await source.setTasks([
            makeTask(id: "t1", title: "One", stepID: nil),
            makeTask(id: "t2", title: "Two", stepID: nil),
        ])
        let store = TaskListStore(source: source)
        await store.refresh()
        return store
    }

    /// Two things remove rows — a signal from the server and this client's own
    /// successful removal — and they must agree.
    @Test("takes the row away and keeps the count honest")
    func removesARow() async {
        let store = await loaded()
        #expect(store.rows.count == 2)
        #expect(store.totalOnServer == 2)

        store.removeRow(taskID: "t1")

        #expect(store.rows.map(\.id) == ["t2"])
        #expect(store.totalOnServer == 1)
    }

    @Test("removing a row that is not there changes nothing")
    func removingAnUnknownRowIsANoOp() async {
        let store = await loaded()

        store.removeRow(taskID: "never-seen")

        #expect(store.rows.count == 2)
        #expect(store.totalOnServer == 2)
    }
}

@MainActor
@Suite("TaskRemovalStore unarchiving")
struct UnarchiveTests {
    /// No confirmation, deliberately, and this test is what says so: putting
    /// something back is not destructive, and asking would be ceremony.
    @Test("unarchives without asking first")
    func unarchivesImmediately() async {
        let remover = StubTaskRemover()
        let store = TaskRemovalStore(remover: remover)

        let restored = await store.unarchive(taskID: "t1")

        #expect(restored)
        #expect(store.pending == nil, "nothing should be left pending")
        let calls = await remover.calls
        #expect(calls == [.init(kind: "unarchive", id: "t1", cascade: false, discard: false)])
    }

    @Test("a failed unarchive is reported")
    func failureIsReported() async {
        let remover = StubTaskRemover()
        await remover.failUnarchive(with: KandevError.connectionClosed)
        let store = TaskRemovalStore(remover: remover)

        let restored = await store.unarchive(taskID: "t1")

        #expect(restored == false)
        #expect(store.failure != nil)
    }
}
