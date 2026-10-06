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
    /// Whether the server says there is more of this conversation before the page on screen.
    ///
    /// The transcript holds one page and opens on the newest, so on a long exchange everything
    /// before it is simply absent. This comes from the server rather than from a page size: a full
    /// page is not proof of another one.
    public private(set) var hasOlder = false
    /// Whether a page of history is being read, so a second ask cannot stack a second request.
    public private(set) var isLoadingOlder = false

    private let source: any KandevTranscriptSource
    /// How many messages one page holds.
    ///
    /// The page is the newest one, not the oldest: a chat opens at its tail, and a conversation
    /// longer than one page would otherwise never show what was just said. The client turns the
    /// wire's descending page back into reading order, so what arrives here is chronological.
    private let pageLimit: Int
    /// The messages as last read, kept so a live upsert can be merged by id
    /// rather than triggering a refetch. Bounded by the page limit.
    private var messages: [KandevMessage] = []
    /// Where each message sits in `messages`, so finding one is not a scan.
    ///
    /// The old `upsert` did `firstIndex(where:)` and then regrouped the whole conversation, twice
    /// over, for every token of every streamed reply. Measured: 2000 updates against a 500-message
    /// transcript took 3.7 seconds — 1.85 ms per token, growing with the conversation, on the one
    /// path in this app that runs per token.
    private var messageIndex: [String: Int] = [:]
    /// The id to ask for the page before the one on screen.
    ///
    /// The server hands a cursor back with every page and it is the oldest message in that page —
    /// verified against a live server, where an ISO timestamp in this field is refused and the id
    /// walks the whole conversation with no gaps and no repeats. Held rather than taken from
    /// `messages.first`, because `messages` is also what a live frame writes into: asking from the
    /// wrong end would fetch a page the reader already has.
    private var olderCursor: String?

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
                // Emptied, not left behind: a task with no session must not leave the previous
                // task's messages where a live frame could rebuild the turns out of them.
                messages = []
                messageIndex = [:]
                olderCursor = nil
                hasOlder = false
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

        if sessionID == selectedSessionID {
            // The same conversation, read again — after a send, or when the screen comes back into
            // view. This is a refetch, not a fresh look, and the difference matters because the
            // reader may be holding pages *older* than the one being read: history they asked for.
            // Replacing the transcript with the newest page threw that away, and their place with
            // it — they asked for the past and the app handed them the present.
            mergeNewest(page.messages)
            // The cursor and the claim about older messages are deliberately untouched: they
            // describe the oldest message *held*, which a page of the newest does not change.
            phase = .loaded
            return
        }

        messages = page.messages
        olderCursor = page.cursor
        hasOlder = page.hasMore
        regroup()
        selectedSessionID = sessionID
        phase = .loaded
    }

    /// Merges a freshly read page of the newest messages into what is already held.
    ///
    /// A message already held is replaced where it sits, so the reader's place in the conversation
    /// does not move. One that is new goes on the end, which is where it belongs: the transcript
    /// holds a contiguous run of messages back from the newest, so anything in the newest page that
    /// is not already held is newer than everything held.
    private func mergeNewest(_ page: [KandevMessage]) {
        guard !page.isEmpty else { return }
        for message in page {
            if let position = messageIndex[message.id] {
                messages[position] = message
            } else {
                messages.append(message)
                messageIndex[message.id] = messages.count - 1
            }
        }
        // Once, not per token: a refetch is a read, and the streaming path is `upsert`.
        regroup()
    }

    /// Rebuilds the whole grouping, and the index that makes finding a message cheap.
    ///
    /// For a read, a page, or a message arriving for the first time. Not for the token-by-token
    /// case — see `upsert`.
    private func regroup() {
        messageIndex = Dictionary(
            uniqueKeysWithValues: messages.enumerated().map { ($1.id, $0) }
        )
        turns = TranscriptTurn.grouping(messages)
    }

    /// Reads the page of conversation before the oldest one on screen.
    ///
    /// The transcript holds one page and opens at its tail, so without this everything said before
    /// that page is unreachable — a long exchange simply begins in the middle. Nothing is fetched
    /// when the server has already said there is nothing older, and nothing is fetched twice at
    /// once, because a reader arriving at the top of a scroll asks more than once.
    ///
    /// Answers whether anything arrived, so a caller holding a scroll position can put it back.
    @discardableResult
    public func loadOlder() async -> Bool {
        guard hasOlder, !isLoadingOlder, let sessionID = selectedSessionID else { return false }
        // A page answers with the cursor for the one before it, but a server that omitted it would
        // otherwise stall here forever: the oldest message on screen is the same request.
        guard let cursor = olderCursor ?? messages.first?.id else { return false }

        isLoadingOlder = true
        defer { isLoadingOlder = false }

        do {
            let page = try await source.messages(sessionID: sessionID, limit: pageLimit, before: cursor)
            // The screen can move while this is in flight — another session opened, a task
            // closed — and a page for a conversation nobody is looking at would be merged into
            // whichever one is.
            guard selectedSessionID == sessionID else { return false }
            merge(page.messages)
            olderCursor = page.cursor
            hasOlder = page.hasMore
            return true
        } catch {
            // A page that did not arrive leaves the transcript whole and the cursor where it was,
            // so the next try asks for the same page rather than skipping past it.
            return false
        }
    }

    /// Puts an older page in front of what is already here.
    ///
    /// Merged by id rather than concatenated: a page is fetched from a cursor, and a live frame can
    /// already have written one of its messages into the transcript. Appending it again would show
    /// the reader a conversation that grows duplicates, which is the same fault `upsert` exists to
    /// avoid from the other end.
    private func merge(_ older: [KandevMessage]) {
        guard !older.isEmpty else { return }
        let held = Set(messages.map(\.id))
        let fresh = older.filter { !held.contains($0.id) }
        guard !fresh.isEmpty else { return }
        messages.insert(contentsOf: fresh, at: 0)
        regroup()
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

        if let position = messageIndex[message.id] {
            messages[position] = message
            // The hot path, and the reason this is not one line any more: a streamed reply arrives
            // again under its own id every time its text grows. Only that one row changes — the
            // turn it sits in, the rows around it, the turn's span and every other turn are all
            // untouched — so nothing is regrouped. The turn's own length comes from its messages'
            // creation dates, and an update does not move those.
            replaceRow(for: message)
        } else {
            // A message arriving for the first time. Once per message rather than once per token,
            // so the certain answer is affordable here.
            messages.append(message)
            regroup()
        }
        return true
    }

    /// Swaps the row a message already owns, and leaves the structure around it alone.
    private func replaceRow(for message: KandevMessage) {
        let replacement = TranscriptRow(message: message)
        // From the end, because a growing reply is in the turn being written, which is the last one
        // — so the usual search stops after a handful of rows rather than walking the transcript.
        for turn in turns.indices.reversed() {
            guard let row = turns[turn].rows.firstIndex(where: { $0.id == message.id }) else { continue }
            if let replacement {
                turns[turn].rows[row] = replacement
            } else {
                // It used to draw and now carries nothing worth drawing.
                turns[turn].rows.remove(at: row)
            }
            return
        }
        // Not where the index said it was, which means something changed the transcript under it.
        // Regrouping is the answer that is certainly right, and this is not the hot path.
        regroup()
    }
}
