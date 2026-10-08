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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How the work rows are arranged, and whether the chats shelf is open.
    ///
    /// The reader's choices rather than the server's, so they live with the other view settings
    /// and are remembered between launches.
    @AppStorage("task-list-listing") private var listing: TaskListStore.Listing = .byRepository
    @AppStorage("task-list-chats-expanded") private var chatsExpanded = false
    /// The create screen, with an identity of its own.
    ///
    /// A sheet's content comes from this one value rather than from a boolean beside a store. A
    /// presentation that depends on two pieces of state can be asked for before the second one is
    /// read, which is a blank sheet on the first tap and a correct one on the second.
    @State private var createSheet: CreateSheet?
    /// The task the create screen just made, and the words to carry into it. A chat
    /// starts a conversation, so its sentence goes on to the composer; a filed task
    /// does not need it, because the server already has the brief.
    @State private var openedTaskID: String?
    @State private var openedSentence = ""
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
                        permissions: store.workspace?.conversationPermissions ?? .default,
                        initialDraft: taskID == openedTaskID ? openedSentence : "",
                        read: session.read
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
                // Coming back from a task: the server may have renamed it while the detail was
                // on screen and this list was not listening. A rename is a `task.updated`, and
                // a signal only reaches whoever is subscribed to it at the time.
                .onChange(of: path) { _, path in
                    guard path.isEmpty else { return }
                    Task { await store.refresh() }
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
                    openRequestedScreen()
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
                .sheet(item: $createSheet) { sheet in
                    NewTaskView(store: sheet.store, initialMode: sheet.mode) { opened in
                        createSheet = nil
                        openedTaskID = opened.taskID
                        openedSentence = opened.sentence
                        // Straight to what was just created: refetching the
                        // list to find it would be slower and could miss it.
                        path = [opened.taskID]
                        Task { await store.refresh() }
                    }
                }
        }
    }

    /// Opens whatever a screenshot run asked for. A no-op in a release build and while
    /// no run is active; see `ScreenshotTour`.
    private func openRequestedScreen() {
        guard let screen = ScreenshotTour.screen else { return }
        switch screen {
        case .list:
            if case .failed = store.phase {
                ScreenshotTour.ready(.failed)
            } else {
                ScreenshotTour.ready(store.rows.isEmpty ? .failed : .loaded)
            }
        case .detail:
            guard let taskID = ScreenshotTour.taskID else { break }
            path = [taskID]
        case .newTask:
            openCreateSheet(mode: .task)
        case .chat:
            openCreateSheet(mode: .chat)
        case .setup:
            openCreateSheet(mode: .setup)
        case .connect:
            // Nothing to open: `connect` means the saved server was cleared, so the
            // connect screen is showing instead of this one.
            break
        }
    }

    /// Opens the create screen, with the workspace the list is already showing.
    ///
    /// Idempotent, because a second tap while the sheet is open used to rebuild the
    /// store underneath it — which resets the form someone is in the middle of, and
    /// shows up as the sheet "opening again". A tap on a button that has already done
    /// its job should do nothing.
    private func openCreateSheet(mode: NewTaskView.Mode = .task) {
        guard createSheet == nil else { return }
        createSheet = CreateSheet(
            store: NewTaskStore(
                taskSource: session.client,
                creator: session.client,
                profileSource: session.client,
                chatStarter: session.client,
                catalogue: session.catalogue,
                workspaceID: store.workspace?.id
            ),
            mode: mode
        )
    }

    /// A section's rows, with what has not been read first.
    ///
    /// The read state is this client's, so the order it implies is too — the server has never
    /// heard of it. Only work is reordered: a section's own heading still says what it says, and
    /// the blocks move whole so the hierarchy survives.
    private func arranged(_ section: TaskListStore.Section) -> [TaskRow] {
        section.rows.unreadFirst { row in
            session.read.isUnread(taskID: row.id, lastActivity: row.lastActivity)
        }
    }

    /// The rows of one section.
    ///
    /// Extracted so the grouping above does not have to repeat it, and so the
    /// prefetch below can still ask for the next page by *list* position rather than
    /// by section position: the last row of the last section is the end of the list.
    @ViewBuilder private func rows(_ section: [TaskRow]) -> some View {
        ForEach(section) { row in
            // A button rather than a NavigationLink: the link draws a chevron at
            // the trailing edge, which is a second thing in the row competing with
            // the title for the width the title needs.
            Button {
                path = [row.id]
            } label: {
                TaskRowView(
                    row: row,
                    isUnread: session.read.isUnread(taskID: row.id, lastActivity: row.lastActivity),
                    showsRepository: listing == .flat
                )
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
                rowActions(row)
            }
            // The same actions under a press. A swipe is a gesture nobody is told about;
            // a menu is where a long press looks for one, on both platforms. One
            // definition, because a second list of archive-and-delete is how the two
            // drift apart.
            .contextMenu {
                rowActions(row)
            }
        }
    }

    /// What can be done to a row, wherever it is asked for.
    @ViewBuilder private func rowActions(_ row: TaskRow) -> some View {
        if store.showingArchived {
            // No confirmation: putting something back is not
            // destructive, and asking would be ceremony.
            Button("Unarchive", systemImage: "arrow.up.bin") {
                Task {
                    guard await removal.unarchive(taskID: row.id) else { return }
                    withAnimation { store.removeRow(taskID: row.id) }
                }
            }
            // Grey, not a hue: the app has no colour of its own (docs/design.md), and indigo
            // here was the only one it had invented. Grey is the platform's own neutral action.
            .tint(.gray)
        } else {
            Button("Archive", systemImage: "archivebox") {
                removal.ask(.archive, taskID: row.id, title: row.title)
            }
            .tint(.gray)

            Button("Delete", systemImage: "trash", role: .destructive) {
                removal.ask(.delete, taskID: row.id, title: row.title)
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
                // The same treatment every other failure in the app gets: a red mark and
                // ink words. Muted grey read as a note about the list rather than as the
                // reason it is empty.
                Section { FailureNote(message: message) }
            }

            // A removal that was refused. Without this a delete that the server said no to looked
            // like a row that ignored the tap.
            if let failure = removal.failureMessage {
                Section { FailureNote(message: failure) }
            }

            // Chats first, as a shelf that can be closed; then the work, arranged the way the
            // reader asked for. A workspace whose work belongs to no project draws one untitled
            // section, which is the flat list this screen has always been.
            ForEach(store.sections(listing)) { section in
                if section.isChats {
                    chatsSection(section)
                } else {
                    Section {
                        rows(arranged(section))
                    } header: {
                        if let title = section.title {
                            Text(title)
                                .font(Theme.Face.chrome(.footnote))
                                .foregroundStyle(Theme.muted)
                                .textCase(nil)
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

    /// The chats shelf: a heading that opens and closes them, and the chats themselves.
    ///
    /// Closed to begin with, because the work is what this screen is for and a chat is a scratch
    /// conversation — but the count is on the heading, so nothing is hidden silently.
    @ViewBuilder private func chatsSection(_ section: TaskListStore.Section) -> some View {
        Section {
            if chatsExpanded {
                rows(arranged(section))
            }
        } header: {
            Button {
                withAnimation(Motion.fold(reduceMotion: reduceMotion)) { chatsExpanded.toggle() }
            } label: {
                HStack(spacing: Theme.Space.snug) {
                    Image(systemName: chatsExpanded ? "chevron.down" : "chevron.right")
                        .font(Theme.Face.chrome(.caption2, weight: .semibold))
                    Text("Quick Chats")
                    Text("\(section.rows.count)")
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                .font(Theme.Face.chrome(.footnote))
                .foregroundStyle(Theme.muted)
                .textCase(nil)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quick chats, \(section.rows.count)")
            .accessibilityHint(chatsExpanded ? "Closes the chats" : "Opens the chats")
        }
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
                Section("List") {
                    Picker("List", selection: $listing) {
                        ForEach(TaskListStore.Listing.allCases) { candidate in
                            Text(candidate.title).tag(candidate)
                        }
                    }
                }
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
            openCreateSheet()
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

/// The create sheet's identity and the store it shows.
///
/// Its own `Identifiable` rather than the store's: the sheet's lifetime is one presentation, and
/// a second open is a second identity. This is what makes the presentation atomic — the sheet
/// exists exactly while there is something to show in it.
private struct CreateSheet: Identifiable {
    let id = UUID()
    let store: NewTaskStore
    let mode: NewTaskView.Mode
}
