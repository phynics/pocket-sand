import KandevKit
import SwiftUI

/// A task to open, and the words to carry into it.
///
/// The words are empty for a filed task: the server already has the brief, and sends
/// it to the agent as the first message when a session starts. A chat has no brief —
/// it is a conversation — so its sentence travels with it into the composer, exactly
/// as the first-party client pre-fills a chat's input.
struct OpenedTask: Equatable {
    var taskID: String
    var sentence: String
}

/// Starting something: a task, a chat about the work, or a chat about the setup.
///
/// **One input.** The server turns the sentence into the agent's first message, so
/// the sentence is the only thing anyone has to write — and the task's name is taken
/// from its first few words rather than asked for. A screen with one field is a screen
/// where nobody has to work out which field is which, which is what an earlier version
/// of this screen got wrong: two serif placeholders and no labels, and no way to tell
/// the title from the prompt.
///
/// **The doors are visible.** A chat is not a hidden gesture and the setup chat is not
/// something you have to be stuck to find, so all three are named across the top and
/// the rest of the screen follows the one that is chosen. An earlier version put them
/// at the bottom, where the keyboard covered them.
///
/// A chat is not a different object on the server — starting one creates a task and a
/// session — so all three doors end in the same place: the transcript this app already
/// has, carrying the sentence with it.
struct NewTaskView: View {
    let store: NewTaskStore
    let onOpened: (OpenedTask) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var mode: Mode

    init(store: NewTaskStore, initialMode: Mode = .task, onOpened: @escaping (OpenedTask) -> Void) {
        self.store = store
        self.onOpened = onOpened
        _mode = State(initialValue: initialMode)
    }

    /// What this screen can start.
    enum Mode: String, CaseIterable, Identifiable {
        case task
        case chat
        case setup

        var id: String { rawValue }

        var title: String {
            switch self {
            case .task: "Task"
            case .chat: "Chat"
            case .setup: "Setup"
            }
        }

        /// The question the input answers, which is the input's label. A placeholder
        /// disappears the moment someone types; a label does not, and this screen has
        /// to stay legible after the first keystroke.
        var question: String {
            switch self {
            case .task: "What needs doing?"
            case .chat: "What do you want to ask?"
            case .setup: "What should change?"
            }
        }

        /// An example, because "what needs doing" is a question and a concrete sentence
        /// answers a question better than an instruction does.
        var example: String {
            switch self {
            case .task: "Fix the flaky test in the auth suite"
            case .chat: "How does the retry policy work?"
            case .setup: "Add a review step"
            }
        }

        var action: String {
            switch self {
            case .task: "Create"
            case .chat: "Start chat"
            case .setup: "Start setup chat"
            }
        }

        /// What the sentence will be used for, said once and only while the field is
        /// empty.
        var footnote: String {
            switch self {
            case .task: "The agent receives this as its first message, word for word."
            case .chat: "Sent as the chat's first message. Nothing is filed: it is a conversation."
            case .setup: "The setup chat changes Kandev's own settings, not a task's."
            }
        }
    }

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            Form {
                modeSection
                sentenceSection
                destinationSection
                if case .failed(let message) = store.phase {
                    Section { FailureNote(message: message) }
                }
            }
            .paperBackground()
            .scrollContentBackground(.hidden)
            // A plain list and no row background: a Form's inset cards are filled
            // containers, and this app does not use them. The sentence is written on
            // the paper, not in a box on it.
            .listStyle(.plain)
            .navigationTitle(mode == .task ? "New task" : "Start a chat")
            .scrollToRequestedAnchor()
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .overlay {
                if store.isLoadingOptions && store.workflows.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(Theme.Face.chrome(.callout))
                        .foregroundStyle(Theme.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: start) {
                        if store.phase == .creating {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(mode.action)
                                .font(Theme.Face.chrome(.callout, weight: .semibold))
                                .foregroundStyle(canStart ? Theme.ink : Theme.muted)
                        }
                    }
                    .disabled(!canStart)
                }
            }
            // Deliberately not focusing the sentence. With the keyboard up the choices
            // below it fall under the fold, and the whole argument of this screen is
            // what it shows at once: what you are asking for, where it goes, who takes
            // it, and the other ways to start.
            .task {
                await store.loadOptions()
                // Settled. Whether it settled *with* anything is what a run has to know:
                // a screenshot of a screen that failed to load is not evidence about how
                // that screen looks. A no-op unless a run asked for it.
                if case .failed = store.phase {
                    ScreenshotTour.ready(.failed)
                } else {
                    ScreenshotTour.ready(.loaded)
                }
            }
        }
    }

    private var canStart: Bool {
        switch mode {
        case .task: store.canFile
        case .chat, .setup: store.canAsk
        }
    }

    // MARK: - The doors

    /// All three, named, with the chosen one in ink and a rule under it.
    ///
    /// A rule rather than a filled pill: this app has no accent colour and no filled
    /// containers, so the way to say "this one" is weight and a line — the same
    /// vocabulary the spine uses on a task row.
    private var modeSection: some View {
        Section {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    // Stacked, because three words cannot share a line at these sizes and
                    // "Set-up" broken across two is worse than three lines: the hyphen is
                    // the layout admitting it has nowhere to put the word.
                    VStack(alignment: .leading, spacing: Theme.Space.base) {
                        ForEach(Mode.allCases) { candidate in
                            modeButton(candidate, fillsWidth: true)
                        }
                    }
                } else {
                    HStack(spacing: Theme.Space.loose) {
                        ForEach(Mode.allCases) { candidate in
                            modeButton(candidate, fillsWidth: false)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .listRowBackground(Color.clear)
        }
    }

    /// One door: its name, and a rule under the one that is chosen.
    ///
    /// A rule rather than a filled pill: this app has no accent colour and no filled
    /// containers, so the way to say "this one" is weight and a line.
    private func modeButton(_ candidate: Mode, fillsWidth: Bool) -> some View {
        Button {
            mode = candidate
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.hair) {
                Text(candidate.title)
                    .font(Theme.Face.chrome(.callout, weight: mode == candidate ? .semibold : .regular))
                    .foregroundStyle(mode == candidate ? Theme.ink : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Rule().opacity(mode == candidate ? 1 : 0)
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == candidate ? [.isSelected] : [])
    }

    // MARK: - The one input

    private var sentenceSection: some View {
        @Bindable var store = store

        return Section {
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                Text(mode.question)
                    .font(Theme.Face.chrome(.footnote))
                    .foregroundStyle(Theme.muted)
                // No example at the accessibility sizes: a placeholder in a growing
                // field does not wrap, it truncates, and "Fix the flaky t…" is worse
                // than the label above saying what the field is for.
                TextField(dynamicTypeSize.isAccessibilitySize ? "" : mode.example, text: $store.brief, axis: .vertical)
                    .font(Theme.Face.prose(.title3))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(Theme.proseLineSpacing)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .frame(minHeight: 84, alignment: .topLeading)
                    .padding(.horizontal, Theme.Space.base)
                    .padding(.vertical, Theme.Space.snug + 2)
                    .fieldArea()
            }
            .listRowBackground(Color.clear)
        } footer: {
            if store.brief.isEmpty {
                Text(mode.footnote)
                    .font(Theme.Face.chrome(.footnote))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: - Where it goes, and who takes it

    private var destinationSection: some View {
        Section {
            if mode == .task {
                Menu {
                    filingMenu
                } label: {
                    consequenceRow(
                        "Filed in",
                        value: filingValue,
                        isChosen: store.workflowID != nil
                    )
                }
                .listRowBackground(Color.clear)
                .id(ScreenshotTour.Anchor.filedIn)
            }

            Menu {
                ForEach(store.agentProfiles) { profile in
                    Button(profile.displayName) { store.agentProfileID = profile.id }
                }
            } label: {
                consequenceRow(
                    "Agent",
                    value: selectedProfile?.displayName ?? "None set up",
                    isChosen: store.agentProfileID != nil
                )
            }
            .listRowBackground(Color.clear)
            .id(ScreenshotTour.Anchor.agent)

            repositoryRow
                .id(ScreenshotTour.Anchor.repository)
        } header: {
            Text(mode == .task ? "Where it goes" : "Who takes it")
                .font(Theme.Face.chrome(.footnote))
                .foregroundStyle(Theme.muted)
                .textCase(nil)
        } footer: {
            destinationFooter
        }
    }

    /// The repository this work belongs to.
    ///
    /// A workspace with none configured gets a statement rather than an empty menu:
    /// a control that opens onto nothing is worse than no control, and the way to add
    /// one is the setup chat, which is named where the need arises.
    @ViewBuilder private var repositoryRow: some View {
        if store.repositories.isEmpty {
            consequenceRow("Repository", value: "None configured", isChosen: false, isPickable: false)
                .listRowBackground(Color.clear)
        } else {
            Menu {
                Button("The workspace's own") { store.repositoryID = nil }
                ForEach(store.repositories) { repository in
                    Button(repository.name.isEmpty ? repository.origin : repository.name) {
                        store.repositoryID = repository.id
                    }
                }
            } label: {
                consequenceRow("Repository", value: repositoryValue, isChosen: store.repositoryID != nil)
            }
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder private var destinationFooter: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            if store.repositories.isEmpty {
                Text("No repositories in this workspace yet. **Setup** can add one — a GitHub repository, or a path on the machine running Kandev.")
                    .font(Theme.Face.chrome(.footnote))
                    .foregroundStyle(Theme.muted)
            }
            if selectedProfile?.isUnconfirmed == true {
                Text("The runtime does not confirm this agent's model, so starting it may fail.")
                    .font(Theme.Face.chrome(.footnote))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    /// Every workflow, and its steps, in one menu.
    ///
    /// Sections rather than a second level: a nested menu on a phone is a second tap
    /// that hides the answer, and there are rarely many workflows.
    @ViewBuilder private var filingMenu: some View {
        ForEach(store.workflows) { workflow in
            Section(workflow.name) {
                ForEach(store.steps(forWorkflow: workflow.id)) { step in
                    Button(step.name) {
                        store.file(workflowID: workflow.id, stepID: step.id)
                    }
                }
                Button("Its start step") {
                    store.file(workflowID: workflow.id, stepID: nil)
                }
            }
        }
    }

    /// A label, an answer, and the platform's own "this opens a choice" glyph.
    ///
    /// The glyph is in ink and not in the muted grey a hint would use: a row that
    /// opens a menu has to look like one, which is what the first version of this
    /// screen got wrong — a workflow nobody knew they could change.
    private func consequenceRow(
        _ label: String,
        value: String,
        isChosen: Bool,
        isPickable: Bool = true
    ) -> some View {
        // Two arrangements, and the first that fits is the one used. At the larger text
        // sizes a label and an answer cannot share a line, and what happens then is not
        // a smaller answer — it is an ellipsis where the answer should be, which is how
        // "Development · its start step" became "No wo…" in a screenshot run.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.snug) {
                labelText(label)
                Spacer(minLength: Theme.Space.base)
                valueText(value, isChosen: isChosen)
                glyph(isPickable: isPickable)
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.snug) {
                VStack(alignment: .leading, spacing: Theme.Space.hair) {
                    labelText(label)
                    valueText(value, isChosen: isChosen)
                }
                Spacer(minLength: 0)
                glyph(isPickable: isPickable)
            }
        }
        .contentShape(Rectangle())
    }

    private func labelText(_ label: String) -> some View {
        Text(label)
            .font(Theme.Face.chrome(.callout))
            .foregroundStyle(Theme.muted)
    }

    private func valueText(_ value: String, isChosen: Bool) -> some View {
        Text(value)
            .font(Theme.Face.chrome(.callout))
            .foregroundStyle(isChosen ? Theme.ink : Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func glyph(isPickable: Bool) -> some View {
        if isPickable {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
        }
    }

    private var selectedProfile: KandevAgentProfile? {
        store.agentProfiles.first { $0.id == store.agentProfileID }
    }

    private var repositoryValue: String {
        guard let id = store.repositoryID,
              let repository = store.repositories.first(where: { $0.id == id })
        else { return "The workspace's own" }
        return repository.name.isEmpty ? repository.origin : repository.name
    }

    /// Where the task will land, in the words the list will use.
    private var filingValue: String {
        let workflow = store.workflows.first { $0.id == store.workflowID }?.name
        let step = store.orderedSteps.first { $0.id == store.stepID }?.name
        switch (workflow, step) {
        case (let workflow?, let step?): return "\(workflow) · \(step)"
        case (let workflow?, nil): return "\(workflow) · its start step"
        case (nil, _): return "No workflow"
        }
    }

    // MARK: - Doing it

    private func start() {
        switch mode {
        case .task:
            Task {
                guard let task = await store.create() else { return }
                onOpened(OpenedTask(taskID: task.id, sentence: ""))
            }
        case .chat:
            startChat(.quick)
        case .setup:
            startChat(.config)
        }
    }

    private func startChat(_ kind: KandevChatKind) {
        Task {
            guard let chat = await store.startChat(kind: kind) else { return }
            onOpened(OpenedTask(taskID: chat.taskID, sentence: store.brief))
        }
    }
}

/// Scrolls a screen to the anchor a screenshot run asked for.
///
/// A still can only show what is on screen, so without this a run photographs the top
/// of every screen and nothing else — which is how the row layout at the largest text
/// sizes went unchecked. Inert unless `KANDEV_SCROLL` names an anchor.
private struct RequestedAnchorScroll: ViewModifier {
    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .task {
                    guard let anchor = ScreenshotTour.anchor else { return }
                    // One turn of the run loop, so the rows exist to be scrolled to.
                    try? await Task.sleep(for: .milliseconds(50))
                    proxy.scrollTo(anchor, anchor: .center)
                }
        }
    }
}

extension View {
    func scrollToRequestedAnchor() -> some View {
        modifier(RequestedAnchorScroll())
    }
}
