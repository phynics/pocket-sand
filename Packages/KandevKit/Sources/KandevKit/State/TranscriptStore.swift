import Foundation
import Observation

/// One task's conversation, for one of its sessions.
@MainActor
@Observable
public final class TranscriptStore {
    public enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var task: KandevTask?
    public private(set) var sessions: [KandevSession] = []
    public private(set) var turns: [TranscriptTurn] = []
    public private(set) var stepName: String?
    /// Set when the task exists but has no session yet. Opening a task must never
    /// start an agent, so this is a real state and not an error.
    public private(set) var hasNoSession = false
    public private(set) var selectedSessionID: String?

    private let source: any KandevTranscriptSource
    private let pageLimit: Int
    /// The messages as last read, kept so a live upsert can be merged by id
    /// rather than triggering a refetch. Bounded by the page limit.
    private var messages: [KandevMessage] = []

    public init(source: any KandevTranscriptSource, stepNames: [String: String] = [:], pageLimit: Int = 100) {
        self.source = source
        self.stepNames = stepNames
        self.pageLimit = pageLimit
    }

    private var stepNames: [String: String]

    public func load(taskID: String) async {
        phase = .loading
        do {
            let task = try await source.task(id: taskID)
            self.task = task
            stepName = task.workflowStepID.flatMap { stepNames[$0] }

            let sessions = try await source.sessions(taskID: taskID)
            self.sessions = sessions

            guard let session = chooseSession(from: sessions, task: task) else {
                hasNoSession = true
                turns = []
                selectedSessionID = nil
                phase = .loaded
                return
            }
            hasNoSession = false
            try await loadTranscript(sessionID: session.id)
        } catch {
            phase = .failed(KandevError.readableMessage(for: error))
        }
    }

    /// The session currently open, if any.
    public var selectedSession: KandevSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    /// Switches to another session of the same task, or refetches the open one
    /// when `force` is set — which is how a sent prompt becomes visible.
    public func select(sessionID: String, force: Bool = false) async {
        guard force || sessionID != selectedSessionID else { return }
        phase = .loading
        do {
            try await loadTranscript(sessionID: sessionID)
        } catch {
            phase = .failed(KandevError.readableMessage(for: error))
        }
    }

    /// The session a task opens on: the one it calls primary, else the one the
    /// task points at, else the first.
    private func chooseSession(from sessions: [KandevSession], task: KandevTask) -> KandevSession? {
        if let primary = sessions.first(where: { $0.isPrimary == true }) { return primary }
        if let id = task.primarySessionID, let match = sessions.first(where: { $0.id == id }) {
            return match
        }
        return sessions.first
    }

    private func loadTranscript(sessionID: String) async throws {
        let page = try await source.messages(sessionID: sessionID, limit: pageLimit, before: nil)
        messages = page.messages
        turns = TranscriptTurn.grouping(messages)
        selectedSessionID = sessionID
        phase = .loaded
    }

    /// Merges a change to the task on screen.
    ///
    /// The task is read once when the screen opens, and the server renames a task shortly after
    /// it is created — an agent replaces the provisional title derived from the first sentence.
    /// Without this the screen keeps the name a task had for the first few seconds of its life.
    public func apply(_ update: KandevTaskUpdate) {
        guard let task, update.taskID == task.id else { return }
        self.task = update.applied(to: task)
    }

    /// Whether a turn should start folded away.
    ///
    /// Everything but the turn being written. A finished turn folds as soon as its work
    /// stops — the reader is following the run in flight, and the history of what the
    /// agent did is a summary of it.
    public func isCondensedByDefault(turnID: String, working: Bool) -> Bool {
        !(working && turns.last?.id == turnID)
    }

    /// Merges one message into the open transcript.
    ///
    /// An upsert, not an append: a live server sends the same message id again as
    /// the text accumulates — an agent's thinking message arrived first with empty
    /// content and metadata, then a reply under a new id. Appending would show a
    /// conversation that grows duplicates instead of sentences.
    ///
    /// Ignored for a session other than the one on screen, and for a message the
    /// open page does not contain, so a live frame can never silently rewrite a
    /// conversation the reader is not looking at.
    @discardableResult
    public func upsert(_ message: KandevMessage) -> Bool {
        guard message.sessionID == nil || message.sessionID == selectedSessionID else { return false }
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        turns = TranscriptTurn.grouping(messages)
        return true
    }
}
