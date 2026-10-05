import KandevKit
import SwiftUI

/// The home screen: one flat list of a workspace's tasks.
///
/// Flat, with the step as a spine at the leading edge, ordered by last activity.
/// Not the Threads view and not a board — see ADR-0002 and the glossary.
///
/// The list is deliberately not a set of cards. Structure comes from rules and a
/// shared left edge, so the eye can run down the spines and down the times without
/// being interrupted by a container on every row.
struct TaskListView: View {
    let session: AppSession
    let servers: ServerBookmarkStore
    let onSelectServer: (ServerBookmark) -> Void
    let onAddServer: () -> Void

    @State private var connectionProblem: String?
    @State private var path: [String] = []
    /// Watching this is how a list that was left open overnight notices the morning.
    @Environment(\.scenePhase) private var scenePhase
    @State private var isCreatingTask = false
    @State private var newTask: NewTaskStore?
    @State private var removal: TaskRemovalStore

    private var store: TaskListStore { session.taskList }

    init(
        session: AppSession,
        servers: ServerBookmarkStore,
        onSelectServer: @escaping (ServerBookmark) -> Void,
        onAddServer: @escaping () -> Void
    ) {
        self.session = session
        self.servers = servers
        self.onSelectServer = onSelectServer
        self.onAddServer = onAddServer
        _removal = State(initialValue: TaskRemovalStore(remover: session.client))
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .paperBackground()
                .navigationTitle(title)
                // Inline, because a large system title is a second loud thing on a
                // screen whose loud thing is the list. The workspace name is
                // context; it does not need to be a headline.
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbar }
                // Navigating by task id, not by row: a deep link knows an id and
                // nothing else, and the detail view already loads the task.
                .navigationDestination(for: String.self) { taskID in
                    TaskDetailView(
                        taskID: taskID,
                        source: session.client,
                        catalogue: session.catalogue,
                        permissions: store.workspace?.conversationPermissions ?? .default
                    )
                }
                .refreshable { await store.refresh() }
                // Coming back to a screen is the event that matters: the socket may
                // have been down for hours, and nothing about the rows can be trusted
                // across that. Debounced inside the store, because this fires after
                // every interruption.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await store.refreshIfDue() }
                }
                .overlay(alignment: .bottomTrailing) {
                    newTaskButton
                        .padding(.trailing, Theme.Space.loose)
                        .padding(.bottom, Theme.Space.loose)
                }
                .task {
                    await connectIfNeeded()
                    if store.phase == .idle {
                        await store.refresh()
                    }
                    await store.startWatching()
                }
                .onDisappear { store.stopWatching() }
                .onOpenURL { url in
                    guard case .task(let id) = KandevDeepLink(url: url) else { return }
                    path = [id]
                }
                .confirmationDialog(
                    removalTitle,
                    isPresented: Binding(
                        get: { removal.pending != nil },
                        set: { if !$0 { removal.cancel() } }
                    ),
                    titleVisibility: .visible
                ) {
                    if let pending = removal.pending {
                        Button(confirmLabel(for: pending.action), role: .destructive) {
                            Task {
                                if let removed = await removal.confirm() {
                                    withAnimation { store.removeRow(taskID: removed) }
                                }
                            }
                        }
                        Button("Cancel", role: .cancel) { removal.cancel() }
                    }
                } message: {
                    Text(removalMessage)
                }
                .sheet(isPresented: $isCreatingTask) {
                    if let newTask {
                        NewTaskView(store: newTask) { task in
                            isCreatingTask = false
                            // Straight to what was just created: refetching the
                            // list to find it would be slower and could miss it.
                            path = [task.id]
                            Task { await store.refresh() }
                        }
                    }
                }
        }
    }

    private var title: String {
        store.workspaceName ?? session.bookmark.name
    }

    @ViewBuilder
    private var content: some View {
        if let connectionProblem {
            EmptyNote(
                title: "Cannot reach the server",
                detail: connectionProblem
            )
            .padding(Theme.Space.loose)
            .overlay(alignment: .bottom) {
                Button("Try again") {
                    Task {
                        await connectIfNeeded()
                        await store.refresh()
                    }
                }
                .font(Theme.Face.chrome(.callout, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .buttonStyle(.plain)
                .padding(.bottom, Theme.Space.section)
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if store.showingArchived {
                Section {
                    Text("Tasks you archived, newest first. Swipe one to put it back.")
                        .font(Theme.Face.chrome(.footnote))
                        .foregroundStyle(Theme.muted)
                }
            }

            if case .failed(let message) = store.phase {
                Section {
                    Text(message)
                        .font(Theme.Face.chrome(.footnote))
                        .foregroundStyle(Theme.muted)
                }
            }

            ForEach(store.rows) { row in
                // A button rather than a NavigationLink: the link draws a chevron at
                // the trailing edge, which is a second thing in the row competing with
                // the title for the width the title needs.
                Button {
                    path = [row.id]
                } label: {
                    TaskRowView(row: row)
                }
                .buttonStyle(.plain)
                .task {
                    // Prefetch by position rather than watching an index: a row
                    // asks for the next page when it is the last one drawn.
                    if row.id == store.rows.last?.id {
                        await store.loadMore()
                    }
                }
                // Per row, not on the List: applied to the List it does nothing,
                // and the spine then starts inset from the screen edge instead of
                // forming the continuous colour column the design is built on.
                .listRowInsets(EdgeInsets())
                // Clear, so the paper's grain runs behind the rows rather than
                // stopping at each one.
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Theme.rule)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if store.showingArchived {
                        // No confirmation: putting something back is not
                        // destructive, and asking would be ceremony.
                        Button("Unarchive", systemImage: "arrow.up.bin") {
                            Task {
                                guard await removal.unarchive(taskID: row.id) else { return }
                                withAnimation { store.removeRow(taskID: row.id) }
                            }
                        }
                        .tint(.indigo)
                    } else {
                        Button("Archive", systemImage: "archivebox") {
                            removal.ask(.archive, taskID: row.id, title: row.title)
                        }
                        .tint(.indigo)

                        Button("Delete", systemImage: "trash", role: .destructive) {
                            removal.ask(.delete, taskID: row.id, title: row.title)
                        }
                    }
                }
            }

            if store.hasMore {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Room for the button that floats over this list, so the last row can still
        // be read and swiped rather than sitting under a circle.
        .contentMargins(.bottom, 76, for: .scrollContent)
        .overlay {
            if store.phase == .loading && store.rows.isEmpty {
                ProgressView().controlSize(.small)
            } else if store.phase == .loaded && store.rows.isEmpty {
                EmptyNote(
                    title: store.showingArchived ? "Nothing archived" : "No open tasks",
                    detail: store.showingArchived
                        ? "Tasks you archive will be here, and can come back."
                        : "This workspace has nothing on the board. Create a task and it will show up here."
                )
                .padding(.horizontal, Theme.Space.loose)
                .frame(maxWidth: Theme.measure, alignment: .leading)
            }
        }
        .animation(.default, value: store.rows)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await store.setShowingArchived(!store.showingArchived) }
            } label: {
                if store.showingArchived {
                    Label("Show the board", systemImage: "rectangle.stack")
                } else {
                    Label("Show archived", systemImage: "archivebox")
                }
            }
        }

        // Two at most. Creating a task is the screen's one action and it belongs
        // under the thumb, not in a corner the hand cannot reach; what is left up
        // here is about the list, and the servers live behind the disclosure.
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Section("Server") {
                    ForEach(servers.bookmarks) { bookmark in
                        Button {
                            onSelectServer(bookmark)
                        } label: {
                            if bookmark.id == session.bookmark.id {
                                Label(bookmark.name, systemImage: "checkmark")
                            } else {
                                Text(bookmark.name)
                            }
                        }
                    }
                    Divider()
                    Button("Add server…", systemImage: "plus", action: onAddServer)
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    /// The one action this screen has, floating where a thumb reaches it.
    ///
    /// Glass, because it floats over the list: the material is what says the list is
    /// still there underneath rather than that a hole has been cut in it. A circle
    /// rather than a bare glyph, because over a list of serif titles a floating plus
    /// reads as stray punctuation.
    private var newTaskButton: some View {
        Button {
            newTask = NewTaskStore(
                taskSource: session.client,
                creator: session.client,
                profileSource: session.client,
                catalogue: session.catalogue,
                workspaceID: store.workspace?.id
            )
            isCreatingTask = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.ink)
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .circleGlass()
        .accessibilityLabel("New task")
    }

    /// The question being asked, worded for what it will do.
    private var removalTitle: String {
        guard let pending = removal.pending else { return "" }
        switch pending.action {
        case .archive: return "Archive “\(pending.title)”?"
        case .delete: return "Delete “\(pending.title)”?"
        case .discardAndDelete: return "Discard its changes and delete?"
        }
    }

    private var removalMessage: String {
        guard let pending = removal.pending else { return "" }
        switch pending.action {
        case .archive:
            return "It leaves the board. Nothing is deleted, and it can be unarchived."
        case .delete:
            return "This cannot be undone. If its worktree holds uncommitted work, you will be asked again."
        case .discardAndDelete:
            // The server refused until this was asked for explicitly, so the
            // consequence is spelled out here rather than assumed.
            return "The worktree for this task has uncommitted changes. Deleting now discards them permanently."
        }
    }

    private func confirmLabel(for action: TaskRemovalStore.Action) -> String {
        switch action {
        case .archive: return "Archive"
        case .delete: return "Delete"
        case .discardAndDelete: return "Discard changes and delete"
        }
    }

    /// The socket is opened here rather than at launch so that a server which is
    /// down produces a message on this screen instead of a blank app.
    private func connectIfNeeded() async {
        connectionProblem = nil
        do {
            try await session.connect()
        } catch {
            connectionProblem = error.localizedDescription
        }
    }
}
