import Foundation
import Observation

/// The task list's state: which tasks to show, and what went wrong.
///
/// One store per connected server. It owns the load sequence — workspace, then
/// step names, then tasks — because the view should never have to know that a
/// step name and a task arrive from different places.
@MainActor
@Observable
public final class TaskListStore {
    public enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var rows: [TaskRow] = []
    public private(set) var workspaceName: String?
    /// The workspace as the server described it, scopes included.
    public private(set) var workspace: KandevWorkspace?
    /// Steps whose name could not be resolved. Non-empty means some row is
    /// missing its chip, which is a data problem worth surfacing rather than
    /// silently rendering a gap.
    public private(set) var unresolvedStepCount = 0
    public private(set) var totalOnServer = 0
    public private(set) var hasMore = false

    /// True when the server mentioned a task this page does not hold, so the
    /// list is behind — a task was created, or the page is narrower than the
    /// workspace. Surfaced rather than swallowed: a list that quietly stops being
    /// complete is worse than one that admits it.
    public private(set) var hasUnseenTasks = false

    private let source: any KandevTaskSource
    private let hub: KandevNotificationHub?
    /// The debounce in front of every automatic refresh. See `RefreshPolicy`.
    private var refreshPolicy = RefreshPolicy()
    private let pageSize: Int
    /// How long to wait before catching up after an unknown task appears. Bursts
    /// of notifications arrive together, and refetching per frame would thrash.
    private let catchUpDelay: Duration
    private var watchTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var sessionWatchTask: Task<Void, Never>?
    private var catchUpTask: Task<Void, Never>?
    private var workspaceID: String?
    private var tasks: [KandevTask] = []
    /// The workspace's workflows and steps, shared with the screens that need them
    /// too. A store created without one owns its own.
    private let catalogue: WorkflowCatalogue
    private var nextPage = 1
    private var isLoadingMore = false

    public init(
        source: any KandevTaskSource,
        hub: KandevNotificationHub? = nil,
        catalogue: WorkflowCatalogue? = nil,
        pageSize: Int = 50,
        catchUpDelay: Duration = .seconds(2)
    ) {
        self.source = source
        self.hub = hub
        self.catalogue = catalogue ?? WorkflowCatalogue(source: source)
        self.pageSize = pageSize
        self.catchUpDelay = catchUpDelay
    }

    /// Every known step by id, because a row draws the step's colour as well as
    /// its name.
    public var stepsByID: [String: KandevWorkflowStep] { catalogue.stepsByID }

    /// Whether the list is showing work taken off the board rather than on it.
    public private(set) var showingArchived = false

    /// How the work rows are arranged.
    public enum Listing: String, Sendable, CaseIterable, Identifiable {
        /// A section per repository, which is how a workspace's work is usually shaped.
        case byRepository
        /// One list, each row saying which repository it belongs to.
        case flat

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .byRepository: "By project"
            case .flat: "One list"
            }
        }
    }

    /// Newest activity first, which is the order the list is designed around.
    public var query: KandevTaskListQuery { listQuery(page: nil) }

    /// The list's query, at one page. `nil` is the server's first page.
    ///
    /// One builder, because there are two ways into the list — a refresh and its next
    /// page — and a page that forgot the archive flag or the ephemeral one would return
    /// a different list than the one it was appending to.
    private func listQuery(page: Int?) -> KandevTaskListQuery {
        KandevTaskListQuery(
            page: page,
            pageSize: pageSize,
            sort: .updatedDesc,
            archived: showingArchived ? .onlyArchived : .active,
            // Chats belong on the board, not in the archive, and they are drawn as their own
            // section of it. The server hides ephemeral tasks unless asked, and this is the ask.
            includeEphemeral: !showingArchived
        )
    }

    /// Switches between the board and the archive.
    ///
    /// A refetch rather than a filter over what is held: the two sets are
    /// different requests to the server, and the active page does not contain the
    /// archived work at all.
    public func setShowingArchived(_ showing: Bool) async {
        guard showing != showingArchived else { return }
        showingArchived = showing
        await refresh()
    }

    /// Loads everything the list needs, from scratch.
    public func refresh() async {
        phase = .loading
        do {
            let workspace = try await resolveWorkspace()
            self.workspace = workspace
            workspaceName = workspace.name
            workspaceID = workspace.id

            // Steps first: a task carries only a step id, and a row with a blank
            // chip is worse than a slightly slower first paint. The catalogue may
            // have read them already, in which case this costs nothing.
            try await catalogue.load(workspaceID: workspace.id)

            // Read for their names, so a section can say which project it is. A
            // failure here is not a failed list: a heading falls back to "Project".
            if let repositories = try? await source.repositories(workspaceID: workspace.id) {
                repositoryNames = Dictionary(
                    uniqueKeysWithValues: repositories.map { repository in
                        (repository.id, repository.name.isEmpty ? repository.origin : repository.name)
                    }
                )
            }

            nextPage = 1
            let page = try await source.tasks(workspaceID: workspace.id, query: query)
            tasks = page.tasks
            totalOnServer = page.total
            nextPage = 2
            rebuildRows()
            hasMore = tasks.count < totalOnServer
            hasUnseenTasks = false
            phase = .loaded
            // Recorded for reads the person asked for as well as the automatic ones:
            // a pull to refresh is a read, and a scene change a second later should
            // not repeat it.
            refreshPolicy.record(at: Date())
        } catch {
            phase = .failed(KandevError.readableMessage(for: error))
        }
    }

    /// Reads the list again, unless it was read moments ago.
    ///
    /// What the scene-phase and reconnect events call. Returns whether it read, so
    /// the rule can be tested rather than only observed.
    @discardableResult
    public func refreshIfDue(at now: Date = Date()) async -> Bool {
        guard refreshPolicy.isDue(at: now) else { return false }
        // The read records itself, and only when it succeeds: a failed refresh must
        // not push the window out, or a server that is briefly down would be left
        // alone for the whole interval after it comes back.
        await refresh()
        return true
    }

    /// Step id to name, for callers that only need a label.
    public var stepNames: [String: String] { catalogue.stepNames }

    /// Appends the next page, if the server reported one.
    public func loadMore() async {
        guard hasMore, !isLoadingMore, let workspaceID else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await source.tasks(
                workspaceID: workspaceID,
                query: listQuery(page: nextPage)
            )
            tasks.append(contentsOf: page.tasks)
            totalOnServer = page.total
            nextPage += 1
            rebuildRows()
            hasMore = tasks.count < totalOnServer
        } catch {
            // A failed page is not a failed list: keep what is on screen and let
            // the next attempt retry from the same page number.
            phase = .failed(KandevError.readableMessage(for: error))
        }
    }

    // MARK: - Watching

    /// Follows the workspace so a row's spinner and relative time stay honest
    /// without anyone pulling to refresh.
    public func startWatching() async {
        guard let hub, watchTask == nil else { return }
        let stream = await hub.taskSignals(workspaceID: workspaceID)
        // Inherits this actor's isolation, so `apply` is a direct call.
        watchTask = Task { [weak self] in
            for await update in stream {
                self?.apply(update)
            }
        }

        // A second subscription, to the socket rather than to the workspace. While
        // the socket is up the signals above keep the rows honest; the moment it
        // comes back after a drop, this list may have missed a creation or a
        // deletion outright, and the only recovery is to read it again.
        let reconnects = await hub.reconnects()
        reconnectTask = Task { [weak self] in
            for await _ in reconnects {
                await self?.refreshIfDue()
            }
        }
    }

    /// Merges a session's state into the row it belongs to.
    ///
    /// Ignored for a session that is not the task's primary one: a row shows the
    /// task's default session, and a change to a secondary session is not the
    /// row's business. A row cannot tell which session is primary from this frame
    /// alone, so the frame says.
    public func apply(_ change: KandevSessionStateChange) {
        guard change.isPrimary != false, let taskID = change.taskID else { return }
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }

        var task = tasks[index]
        if let newState = change.newState { task.primarySessionState = newState }
        if let activity = change.foregroundActivity { task.foregroundActivity = activity }
        if let updatedAt = change.updatedAt { task.updatedAt = updatedAt }
        tasks[index] = task
        rebuildRows()
    }

    public func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        sessionWatchTask?.cancel()
        sessionWatchTask = nil
        catchUpTask?.cancel()
        catchUpTask = nil
    }

    /// Applies a change signalled by the server.
    ///
    /// The kind decides what happens, and getting this wrong is not subtle: a
    /// deletion carries the whole task, so patching it in place leaves a row for
    /// a task that no longer exists.
    public func apply(_ signal: KandevTaskSignal) {
        switch signal.kind {
        case .updated:
            guard let index = tasks.firstIndex(where: { $0.id == signal.update.taskID }) else {
                // A task this page does not have, because it is beyond the page.
                hasUnseenTasks = true
                scheduleCatchUp()
                return
            }
            // A patch, not a replacement: the summary frames arrive thirteen times
            // to the full task's five during one agent turn, and they carry only a
            // status summary. Replacing the task would drop its title.
            tasks[index] = signal.update.applied(to: tasks[index])
            rebuildRows()

        case .deleted, .archived:
            removeRow(taskID: signal.update.taskID)

        case .created:
            // Not in the page, so nothing to patch: the list is behind and a
            // catch-up is how it becomes complete.
            hasUnseenTasks = true
            scheduleCatchUp()
        }
    }

    /// Takes a row away.
    ///
    /// Public because two things remove rows — a signal from the server and this
    /// client's own successful archive or delete — and they must agree. One path,
    /// two callers: a second implementation of "the row is gone" is how a row
    /// comes back.
    public func removeRow(taskID: String) {
        let before = tasks.count
        tasks.removeAll { $0.id == taskID }
        guard tasks.count != before else { return }
        totalOnServer = max(0, totalOnServer - 1)
        rebuildRows()
    }

    private func scheduleCatchUp() {
        catchUpTask?.cancel()
        let delay = catchUpDelay
        catchUpTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: - Loading

    private func resolveWorkspace() async throws -> KandevWorkspace {
        let workspaces = try await source.workspaces()
        guard let first = workspaces.first else {
            throw KandevError.malformedFrame("This server has no workspaces to show.")
        }
        return first
    }

    /// One group of rows: a heading, and the rows under it.
    public struct Section: Identifiable, Equatable {
        public var id: String
        /// `nil` when the list is not grouped at all, so a workspace with nothing to
        /// group by looks exactly like a list.
        public var title: String?
        public var rows: [TaskRow]
        /// Whether this section holds conversations rather than work.
        public var isChats: Bool = false
    }

    /// The list as it is drawn: conversations first, then the work.
    ///
    /// Chats are always their own section, whatever the arrangement: they are not filed anywhere,
    /// so no arrangement of the work can hold them. A workspace whose work belongs to no project
    /// still draws one untitled section, which is the flat list this screen has always been.
    public func sections(_ listing: Listing = .byRepository) -> [Section] {
        var chats: [TaskRow] = []
        var work: [TaskRow] = []

        for row in rows {
            if row.isEphemeral {
                chats.append(row)
            } else {
                work.append(row)
            }
        }

        var sections: [Section] = []
        if !chats.isEmpty {
            sections.append(Section(id: "chats", title: "Chats", rows: chats, isChats: true))
        }

        switch listing {
        case .flat:
            if !work.isEmpty {
                sections.append(Section(id: "all", title: nil, rows: work))
            }

        case .byRepository:
            var byRepository: [String: [TaskRow]] = [:]
            var repositoryOrder: [String] = []
            var unassigned: [TaskRow] = []

            for row in work {
                guard let repositoryID = row.repositoryID else {
                    unassigned.append(row)
                    continue
                }
                if byRepository[repositoryID] == nil { repositoryOrder.append(repositoryID) }
                byRepository[repositoryID, default: []].append(row)
            }

            for repositoryID in repositoryOrder {
                sections.append(
                    Section(
                        id: repositoryID,
                        title: repositoryNames[repositoryID] ?? "Project",
                        rows: byRepository[repositoryID] ?? []
                    )
                )
            }
            if !unassigned.isEmpty {
                // Titled only when something else is on screen: a heading over the only section
                // is a label that says nothing.
                sections.append(
                    Section(
                        id: "none",
                        title: repositoryOrder.isEmpty ? nil : "No project",
                        rows: unassigned
                    )
                )
            }
        }

        return sections
    }

    /// Repository id to name, read with the tasks so a heading can say which project
    /// a section is.
    public private(set) var repositoryNames: [String: String] = [:]

    private func rebuildRows() {
        let visible = tasks.filter(matchesTheToggle(_:))
        let built = visible.map { task -> TaskRow in
            var row = TaskRow(task: task, steps: catalogue.stepsByID)
            // Filled here because the repositories are read before the rows are built, and a row
            // in a flat list has no section heading to say where it belongs.
            row.repositoryName = row.repositoryID.flatMap { repositoryNames[$0] }
            return row
        }
        rows = Self.nested(built)
        unresolvedStepCount = rows.count { $0.stepName == nil }
    }

    /// What the list adds up to, for the one line above it.
    public struct Stats: Sendable, Equatable {
        /// Tasks that want a person, broadly: failed, asked a question, or at a gate.
        public var wantYou: Int
        /// Agents working on something nobody has to touch.
        public var working: Int
    }

    /// The counts worth putting at the top of the list.
    public var stats: Stats {
        Stats(
            wantYou: rows.count { $0.wantsAPerson },
            working: rows.count { $0.isWorking && !$0.wantsAPerson }
        )
    }

    /// Whether a task belongs in the set the toggle is showing.
    ///
    /// The archive flags go to the server as well, and this does not replace them. It
    /// is the client keeping the same promise the button makes: a page that came back
    /// by either route is drawn the way the toggle says, which is the difference
    /// between an archive and a second copy of the board.
    private func matchesTheToggle(_ task: KandevTask) -> Bool {
        showingArchived ? task.archivedAt != nil : task.archivedAt == nil
    }

    /// Tasks in server order, each followed by its subtasks.
    ///
    /// A subtask whose parent is not in the loaded set stays where it is rather than
    /// disappearing into a parent that is not there: a page boundary, an archived
    /// parent, or a parent in another workspace must not hide a task. That is the same
    /// rule the server's own client uses, and the reason a subtask can appear as a task
    /// without the two disagreeing about what happened to it.
    ///
    /// Depth stops at one, but the set does not: a subtask of a subtask is drawn as a
    /// subtask of the task above it rather than dropped or indented twice. An indent
    /// with no end runs off the side of a phone, and a task that vanishes is worse than
    /// one that is indented wrongly.
    nonisolated static func nested(_ rows: [TaskRow]) -> [TaskRow] {
        let loaded = Set(rows.map(\.id))
        var children: [String: [TaskRow]] = [:]
        var tops: [TaskRow] = []

        for row in rows {
            if let parentID = row.parentID, loaded.contains(parentID) {
                children[parentID, default: []].append(row)
            } else {
                tops.append(row)
            }
        }

        // Every row is emitted once, whatever the data says. A parent chain that comes
        // back to where it started is not something the server should send, and it is
        // not something that gets to hang the list either.
        var emitted = Set<String>()
        func subtree(of parent: TaskRow) -> [TaskRow] {
            var arranged: [TaskRow] = []
            for child in children[parent.id] ?? [] {
                guard emitted.insert(child.id).inserted else { continue }
                var marked = child
                marked.depth = 1
                arranged.append(marked)
                arranged.append(contentsOf: subtree(of: child))
            }
            return arranged
        }

        let arranged = tops.flatMap { parent -> [TaskRow] in
            emitted.insert(parent.id)
            return [parent] + subtree(of: parent)
        }

        // Whatever is left is drawn as a task. That covers a cycle, where every row is
        // somebody's child and there is no root to start from — not something the
        // server should send, and not something that gets to empty the list either.
        let leftovers = rows.filter { !emitted.contains($0.id) }
        return arranged + leftovers
    }
}
