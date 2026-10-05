import KandevKit
import SwiftUI

/// One task's conversation: the transcript, the queue, and the composer.
///
/// Reading and writing are one screen because they are one loop: type, send, watch
/// it land, stop it if it goes wrong. The order those happen in lives in
/// `TaskConversationStore`, not here.
struct TaskDetailView: View {
    let taskID: String

    private let catalogue: WorkflowCatalogue

    @State private var conversation: TaskConversationStore
    @State private var move: TaskMoveStore
    /// Rows showing their full text, and turns showing their work. Both are empty
    /// to start: a thought shows its first line, a long command its first line, and
    /// a finished turn its question and answer.
    @State private var expandedRows: Set<String> = []
    /// The exchange open in a sheet, if any.
    @State private var stepsContent: TurnSheetContent?
    /// Whether the newest row is on screen. Following is a courtesy, and yanking
    /// someone out of the history they are reading is not.
    @State private var isAtNewest = true
    /// The content's last-measured height, so a change in it is read as growth.
    @State private var contentHeight: CGFloat = 0

    /// The scroll's aiming point: a view at the true foot of the conversation.
    private static let bottomMarkerID = "conversation-bottom"
    /// Which agent to start. Chosen before starting rather than after: an agent
    /// costs money and runs on someone's machine.
    @State private var selectedProfileID: String?
    @Environment(\.scenePhase) private var scenePhase

    init(
        taskID: String,
        source: any KandevConversationServer,
        catalogue: WorkflowCatalogue,
        permissions: ConversationPermissions = .default,
        initialDraft: String = ""
    ) {
        self.taskID = taskID
        self.catalogue = catalogue
        _conversation = State(
            initialValue: TaskConversationStore(
                transcriptSource: source,
                promptSource: source,
                steps: catalogue.stepsByID,
                permissions: permissions,
                conversationServer: source,
                sessionStarter: source,
                initialDraft: initialDraft
            )
        )
        _move = State(initialValue: TaskMoveStore(mover: source))
    }

    private var transcript: TranscriptStore { conversation.transcript }

    var body: some View {
        VStack(spacing: 0) {
            // A facts line, not a control surface, and so not glass. The skill's
            // rule is that glass belongs to the navigation layer and never to
            // content; more practically, untinted glass here let a heading from the
            // conversation ghost through and compete with the agent's name, which is
            // the one thing this line exists to say.
            if let task = transcript.task {
                headerBar(task)
                Rule()
            }

            transcriptView
        }
        .paperBackground()
        .navigationTitle(transcript.task?.title ?? "Task")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay {
            if transcript.phase == .loading && transcript.turns.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            if transcript.phase == .idle {
                await conversation.load(taskID: taskID)
                if case .failed = transcript.phase {
                    ScreenshotTour.ready(.failed)
                } else {
                    ScreenshotTour.ready(.loaded)
                }
            }
        }
        .onChange(of: transcript.task) { _, task in
            guard let task else { return }
            move.bind(
                taskID: task.id,
                workflowID: task.workflowID,
                currentStepID: task.workflowStepID
            )
        }
        .onDisappear {
            // One screen consumes the notification stream at a time, so leaving
            // the screen has to give it back.
            Task { await conversation.stopFollowing() }
        }
    }

    /// The transcript, with the composer floating over its foot.
    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy, and it matters: a run can be eighty steps, each with a
                // glyph, a hairline and sometimes glass. Eager, every one of them
                // is built and laid out on every change to the transcript — and the
                // transcript changes on every message the agent emits.
                LazyVStack(alignment: .leading, spacing: Theme.Space.section) {
                    content
                        .padding(.horizontal, Theme.Space.loose)
                        .padding(.top, Theme.Space.base)
                        .frame(maxWidth: Theme.measure, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                // Growth is the conversation moving: a new row, the step being written,
                // the summary taking a second line, the queue arriving. Measured here,
                // where it is the content's own height, rather than on the scroll view,
                // where it would be the frame's.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    let grew = height > contentHeight
                    contentHeight = height
                    // Only a reader already at the foot is followed. Following is a
                    // courtesy, and yanking someone out of the history they are reading
                    // is not. No animation: the transcript's own transitions are the
                    // movement, and a second animation on the scroll lands somewhere
                    // neither of them meant.
                    guard grew, isAtNewest else { return }
                    proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
                }
            }
            // A conversation reads newest-last, so it opens at the bottom.
            .defaultScrollAnchor(.bottom)
            .refreshable { await conversation.load(taskID: taskID) }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await conversation.refreshIfDue() }
            }
            // An inset rather than a sibling, so the transcript runs beneath it.
            // That is what makes glass worth using here: glass earns its place by
            // having something to refract.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composerBar(conversation.composer)
            }
            // The sheet decides its own detents, because a set of them has no order
            // and the one it opens at has to be said out loud.
            .sheet(item: $stepsContent) { content in
                TurnStepsView(content: content, title: transcript.task?.title ?? "Task")
            }
            // The sheet opens on a snapshot of the exchange, and a running turn keeps
            // producing steps behind it: left alone, the snapshot freezes at the moment
            // it was tapped. Rebuilding it from the transcript keeps the sheet the
            // exchange it claims to be. Row ids are the server's message ids, so nothing
            // already on screen moves when it is rebuilt.
            .onChange(of: transcript.turns) { _, _ in
                guard let current = stepsContent,
                      let rebuilt = rebuiltSheet(current),
                      rebuilt != current
                else { return }
                stepsContent = rebuilt
            }
        }
    }

    // MARK: - The two control surfaces

    /// Facts about the task, above the transcript.
    private func headerBar(_ task: KandevTask) -> some View {
        header(task)
            .padding(.horizontal, Theme.Space.loose)
            .padding(.vertical, Theme.Space.base)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            transcriptBody
            queuedPrompts
            // The scroll's aiming point: the true foot of the conversation, under the
            // queue, so "follow the newest" does not stop at the last turn while prompts
            // wait below it. It is also what says whether the reader is at the foot — a
            // view that is on screen or is not, rather than arithmetic against a composer
            // whose height changes with the draft.
            Color.clear
                .frame(height: 2)
                .id(Self.bottomMarkerID)
                .onScrollVisibilityChange { visible in isAtNewest = visible }
        }
    }

    // MARK: - Header

    /// The title is in the navigation bar, so this is the line of facts about the
    /// task: where it sits, who is on it. The agent's name is mono because it is
    /// an identifier — `ocg/kandev/deepseek-v4.1-flash` is a token, not a name.
    @ViewBuilder
    private func header(_ task: KandevTask) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            HStack(spacing: Theme.Space.base) {
                // Only when there is somewhere to move to. A chevron with no step
                // beside it is a control that promises a choice it cannot offer —
                // which is what a deep link into a task produces before the
                // workflow's steps have been read.
                if !destinationSteps(for: task).isEmpty {
                    Menu {
                        ForEach(destinationSteps(for: task)) { step in
                            Button {
                                move.targetStepID = step.id
                                Task { await move.previewTarget() }
                            } label: {
                                if step.id == task.workflowStepID {
                                    Label(step.name, systemImage: "checkmark")
                                } else {
                                    Text(step.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: Theme.Space.hair) {
                            if let step = transcript.stepName {
                                StepLabel(
                                    name: step,
                                    colorToken: catalogue.step(id: task.workflowStepID)?.color
                                )
                            }
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: Theme.Space.base) {
                if let agent = task.primaryAgentName {
                    Text(agent)
                        .font(Theme.Face.machine(.caption))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                if transcript.sessions.count > 1 {
                    sessionSwitcher
                }
            }

            if move.targetStepID != nil {
                pendingMove(task)
            }
        }
    }

    /// The steps of the task's own workflow, in the order the workflow puts them.
    /// A step from another workflow is a destination too, but only by moving
    /// workflow as well, which this screen does not offer yet.
    private func destinationSteps(for task: KandevTask) -> [KandevWorkflowStep] {
        catalogue.steps(for: task.workflowID)
    }

    /// What the chosen move would do, and the word that does it.
    ///
    /// Shown before committing because a move is not only a position: it can hand
    /// the work to another agent or start a new session, and that is worth seeing
    /// first.
    @ViewBuilder
    private func pendingMove(_ task: KandevTask) -> some View {
        let target = catalogue.step(id: move.targetStepID)

        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text("Move to \(target?.name ?? "another step")")
                .font(Theme.Face.prose(.callout))

            if move.phase == .previewing {
                Text("Checking what this will do")
                    .font(Theme.Face.chrome(.caption))
                    .foregroundStyle(Theme.muted)
            } else if let summary = move.previewSummary {
                Text(summary)
                    .font(Theme.Face.chrome(.caption))
                    .foregroundStyle(Theme.muted)
            }

            HStack(spacing: Theme.Space.loose) {
                Button("Move") {
                    Task {
                        if await move.move() {
                            await conversation.load(taskID: taskID)
                        }
                    }
                }
                .font(Theme.Face.chrome(.callout, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .disabled(!move.canMove)

                Button("Cancel") { move.targetStepID = nil }
                    .font(Theme.Face.chrome(.callout))
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)

            if let failure = move.failure {
                FailureNote(message: failure)
            }
        }
        .padding(Theme.Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
    }

    private var sessionSwitcher: some View {
        Menu {
            ForEach(transcript.sessions) { session in
                Button {
                    Task { await conversation.open(sessionID: session.id) }
                } label: {
                    if session.id == transcript.selectedSessionID {
                        Label(session.displayName, systemImage: "checkmark")
                    } else {
                        Text(session.displayName)
                    }
                }
            }
        } label: {
            Text(transcript.selectedSession?.displayName ?? "Sessions")
                .font(Theme.Face.chrome(.caption))
                .foregroundStyle(Theme.muted)
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptBody: some View {
        if let failure = failureMessage {
            FailureNote(message: failure)
        } else if transcript.hasNoSession {
            startSession
        } else if transcript.turns.isEmpty && transcript.phase == .loaded {
            EmptyNote(
                title: "Nothing said yet",
                detail: "This session has no messages. Ask it something below."
            )
        } else {
            ForEach(Array(transcript.turns.enumerated()), id: \.element.id) { index, turn in
                TranscriptTurnView(
                    turn: turn,
                    isCondensed: transcript.isCondensedByDefault(turnID: turn.id),
                    isWorking: isWorking,
                    previousReply: transcript.turns.reply(preceding: index),
                    expandedRows: $expandedRows,
                    onShowSteps: { stepsContent = $0 }
                )
            }
        }
    }

    /// A task with no session, and the one thing that can change that.
    @ViewBuilder
    private var startSession: some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            EmptyNote(
                title: "No session yet",
                detail: "This task has no agent conversation. Start one and it will have something to say."
            )

            if !conversation.permissions.canControlSessions {
                Text("This account can read this workspace but cannot start agent work in it.")
                    .font(Theme.Face.chrome(.caption))
                    .foregroundStyle(Theme.muted)
            } else if conversation.isLoadingProfiles {
                ProgressView().controlSize(.small)
            } else if conversation.startableProfiles.isEmpty {
                Text("No agents are configured on this server.")
                    .font(Theme.Face.chrome(.caption))
                    .foregroundStyle(Theme.muted)
            } else {
                Picker("Agent", selection: $selectedProfileID) {
                    ForEach(conversation.startableProfiles) { profile in
                        Text(profileLabel(profile)).tag(Optional(profile.id))
                    }
                }
                .pickerStyle(.menu)
                .font(Theme.Face.chrome(.callout))
                .tint(Theme.ink)

                Button("Start session") {
                    guard let selectedProfileID else { return }
                    Task { await conversation.startSession(agentProfileID: selectedProfileID) }
                }
                .font(Theme.Face.chrome(.callout, weight: .semibold))
                .foregroundStyle(conversation.isStartingSession ? Theme.muted : Theme.ink)
                .buttonStyle(.plain)
                .disabled(selectedProfileID == nil || conversation.isStartingSession)
            }

            if let failure = conversation.sessionStartFailure {
                FailureNote(message: failure)
            }
        }
        .task {
            await conversation.loadStartableProfiles()
            if selectedProfileID == nil {
                selectedProfileID = conversation.startableProfiles.first?.id
            }
        }
        .onChange(of: conversation.startableProfiles) { _, profiles in
            if selectedProfileID == nil { selectedProfileID = profiles.first?.id }
        }
    }

    /// The runtime name disambiguates two profiles of the same agent, which is the
    /// common case: the same model appears under several runtimes.
    private func profileLabel(_ profile: KandevAgentProfile) -> String {
        guard let runtime = profile.agentDisplayName, !runtime.isEmpty else {
            return profile.displayName
        }
        return "\(runtime) · \(profile.displayName)"
    }

    /// The queue, shown where it will land: after the last thing the agent said.
    ///
    /// A prompt waits here rather than appearing in the transcript, because the
    /// transcript is what the server has accepted and a queued prompt is not that
    /// yet. The entries are numbered because a queue is genuinely a sequence, and
    /// the position is the thing that changes.
    @ViewBuilder
    private var queuedPrompts: some View {
        let queued = conversation.composer.queuedPrompts
        if !queued.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                HStack {
                    Text("Waiting")
                        .font(Theme.Face.chrome(.footnote, weight: .medium))
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Discard all") {
                        Task { await conversation.clearQueue() }
                    }
                    .font(Theme.Face.chrome(.footnote))
                    .foregroundStyle(Theme.muted)
                    .buttonStyle(.plain)
                }

                ForEach(Array(queued.enumerated()), id: \.element.id) { index, entry in
                    HStack(alignment: .top, spacing: Theme.Space.snug) {
                        Text("\(index + 1)")
                            .font(Theme.Face.machine(.caption))
                            .foregroundStyle(Theme.muted)
                        VStack(alignment: .leading, spacing: Theme.Space.hair) {
                            Text(entry.content)
                                .font(Theme.Face.prose(.callout))
                                .foregroundStyle(Theme.muted)
                                .lineLimit(3)
                            // Named for what it does: the server cancels the turn
                            // that is running to make room.
                            Button("Interrupt and send this") {
                                Task { await conversation.interruptAndSend(entryID: entry.id) }
                            }
                            .font(Theme.Face.chrome(.caption))
                            .foregroundStyle(Theme.ink)
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, Theme.Space.base)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.rule).frame(width: 1)
                    }
                }
            }
            // Room beneath the last entry, which otherwise ends flush against the
            // composer's glass with the two reading as one surface.
            .padding(.bottom, Theme.Space.base)
        }
    }

    /// Which turn a sheet's id came from: a row's own id, the first machine row of a run
    /// whose summary was tapped, or the first of a run folded into a repeat.
    private func turnIndex(forSheetID id: String) -> Int? {
        let rowID: String
        if id.hasPrefix("steps:") {
            rowID = String(id.dropFirst("steps:".count))
        } else if id.hasPrefix("repeat:") {
            rowID = String(id.dropFirst("repeat:".count))
        } else {
            rowID = id
        }
        return transcript.turns.firstIndex { $0.rows.contains { $0.id == rowID } }
    }

    /// The sheet's content, rebuilt from the transcript it came from.
    ///
    /// Nil when the turn is gone — a refetch that dropped it — in which case the sheet
    /// keeps what it has rather than being emptied.
    private func rebuiltSheet(_ current: TurnSheetContent) -> TurnSheetContent? {
        guard let index = turnIndex(forSheetID: current.id) else { return nil }
        let turn = transcript.turns[index]
        return TurnSheetContent(
            id: current.id,
            previousReply: transcript.turns.reply(preceding: index),
            prompt: turn.promptRow,
            steps: turn.machineRows,
            reply: turn.replyRow,
            focus: current.focus
        )
    }

    private var failureMessage: String? {
        if case .failed(let message) = transcript.phase { return message }
        return nil
    }

    // MARK: - Composer

    private func composerBar(_ store: ComposerStore) -> some View {
        @Bindable var composer = store

        return VStack(alignment: .leading, spacing: Theme.Space.snug) {
            if let failure = composerFailure(store) {
                FailureNote(message: failure)
            } else if let notice = composerNotice(store) {
                Text(notice)
                    .font(Theme.Face.chrome(.caption))
                    .foregroundStyle(Theme.muted)
            }

            HStack(alignment: .bottom, spacing: Theme.Space.base) {
                TextField("Message the agent", text: $composer.draft, axis: .vertical)
                    .font(Theme.Face.prose(.body))
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, Theme.Space.base)
                    .padding(.vertical, Theme.Space.snug + 2)
                    .fieldWell()
                    .disabled(store.identity == nil)

                // One glyph, not words: "Stop" and "Send" cost a third of a phone's
                // width between them and pushed the field into a sliver.
                //
                // In a container with the bar because glass cannot sample glass: the
                // button and the surface it sits on have to share one.
                GlassEffectContainer(spacing: Theme.Space.snug) {
                    actionButton(store)
                }
                .padding(.bottom, 2)
            }

        }
        .padding(.horizontal, Theme.Space.loose)
        .padding(.vertical, Theme.Space.base)
        .frame(maxWidth: .infinity)
        .controlGlass()
    }

    /// A glyph with a name for anyone who cannot see it.
    ///
    /// `.glass` is the interactive glass button style, so it responds under a finger —
    /// which is most of what makes a glass control feel like one.
    private func action(
        _ systemName: String,
        label: String,
        tint: Color,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        // The button style is the glass. Adding `.glassEffect` on top of it stacks two
        // materials on one control — two backdrops where one is meant, and a second
        // specular edge inside the first.
        .buttonStyle(.glass)
        .accessibilityLabel(label)
    }

    /// The one button beside the field, in whichever of its three states applies.
    @ViewBuilder
    private func actionButton(_ store: ComposerStore) -> some View {
        switch store.action(turnIsRunning: isWorking) {
        case .send:
            action(
                "arrow.up",
                label: "Send",
                tint: store.canSend ? Theme.ink : Theme.muted
            ) {
                Task { await conversation.send() }
            }
            .disabled(!store.canSend)

        case .stopTurn:
            action("stop.fill", label: "Stop the running turn", tint: .red) {
                Task { await conversation.stopTurn() }
            }

        case .sendQueuedNow:
            // A bolt, because this is the button that says "now": the prompt is
            // already queued, and tapping sends it at the cost of the turn in
            // progress.
            action(
                "bolt.fill",
                label: "Send the waiting prompt now, interrupting the running turn",
                tint: Theme.ink
            ) {
                Task { await conversation.interruptAndSend() }
            }
        }
    }

    /// Read from the store, not the task snapshot: an agent started from this screen
    /// does not change the task that was read when it opened.
    private var isWorking: Bool {
        conversation.isWorking
    }

    /// What the composer tried to do and could not.
    ///
    /// Separate from a notice, because the two want different voices: "waiting for the
    /// session" is this screen thinking out loud, and "the server refused the prompt"
    /// is something the person has to decide about.
    private func composerFailure(_ composer: ComposerStore) -> String? {
        if case .failed(let message) = composer.phase { return message }
        return nil
    }

    /// One line explaining why the composer cannot be used, when it cannot.
    private func composerNotice(_ composer: ComposerStore) -> String? {
        if case .full(let limit) = composer.phase {
            return "The queue holds \(limit) prompts. It clears as the agent finishes each one."
        }
        if composer.identity == nil && !transcript.hasNoSession {
            return "Waiting for the session before this can send."
        }
        if !composer.permissions.canPrompt {
            return "This account can read this workspace but cannot send prompts to it."
        }
        return nil
    }
}

#Preview("Detail") {
    Text("Task detail needs a live source; see TaskDetailView's initialiser.")
        .padding()
}
