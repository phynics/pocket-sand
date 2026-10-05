import KandevKit
import SwiftUI

/// A task to open, and the words to carry into it.
///
/// The words are empty for a filed task: the server already has the brief, and
/// sends it to the agent as the first message when a session starts. A chat has no
/// brief — it is a conversation — so its sentence travels with it into the
/// composer, exactly as the first-party client pre-fills a chat's input.
struct OpenedTask: Equatable {
    var taskID: String
    var sentence: String
}

/// Starting something: a task, a chat about the work, or a chat about the setup.
///
/// The sentence comes first because the server makes it the agent's first message —
/// creating a task and starting a conversation are the same act, and a form that
/// asks for a title before it asks what you want done has the order backwards.
///
/// What is left is not a form. It is two statements about what will happen, each
/// one tap from being changed: where the task is filed, and which agent takes it.
/// Both show an answer rather than asking a question, and both were chosen before
/// anyone arrived — the workspace's first workflow, the agent that is set up.
///
/// The doors are the point of the screen. A chat is not a different object on the
/// server — starting one creates a task and a session — so "Just ask instead"
/// starts one and opens the same screen a task opens. When nothing is set up, the
/// third door is the way out rather than a dead end.
struct NewTaskView: View {
    let store: NewTaskStore
    let onOpened: (OpenedTask) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The sentence is the reason this screen exists, so the keyboard opens on it.
    @FocusState private var isWriting: Bool

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            Form {
                sentenceSection
                if store.needsAgentProfile {
                    setupSection
                } else {
                    destinationSection
                }
                if case .failed(let message) = store.phase {
                    Section { FailureNote(message: message) }
                }
                askSection
            }
            .paperBackground()
            .scrollContentBackground(.hidden)
            .navigationTitle("New task")
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
                    Button(action: create) {
                        if store.phase == .creating {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Create")
                                .font(Theme.Face.chrome(.callout, weight: .semibold))
                                .foregroundStyle(store.canFile ? Theme.ink : Theme.muted)
                        }
                    }
                    .disabled(!store.canFile)
                }
            }
            .task {
                await store.loadOptions()
                isWriting = store.brief.isEmpty
            }
        }
    }

    // MARK: - What needs doing

    /// The sentence, and the name the server needs underneath it.
    ///
    /// The title follows the sentence until someone edits it, so the common case is
    /// one thing written rather than two. It is not hidden, because a title is what
    /// the list shows and there is no way to rename a task from here yet.
    private var sentenceSection: some View {
        @Bindable var store = store

        return Section {
            TextField("What needs doing?", text: $store.brief, axis: .vertical)
                .font(Theme.Face.prose(.title3))
                .foregroundStyle(Theme.ink)
                .lineSpacing(Theme.proseLineSpacing)
                .lineLimit(2...10)
                .focused($isWriting)
            TextField("Title", text: $store.title)
                .font(Theme.Face.prose(.body))
                .foregroundStyle(Theme.ink)
        } footer: {
            // Said once, while the field is empty, and then out of the way: this is
            // not a note about the work, it is the work.
            if store.brief.isEmpty {
                Text("This is what the agent is asked to do. It arrives as the first message, word for word.")
                    .font(Theme.Face.chrome(.footnote))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: - What will happen

    /// The two statements: filed where, taken by whom.
    ///
    /// A menu rather than a picker per field, because filing is one decision —
    /// a workflow and a step — and two rows of two pickers reads as four.
    private var destinationSection: some View {
        @Bindable var store = store

        return Section {
            Menu {
                filingMenu
            } label: {
                consequenceRow(
                    "Filed in",
                    value: filingValue,
                    isChosen: store.workflowID != nil
                )
            }
            Picker("Agent", selection: $store.agentProfileID) {
                ForEach(store.agentProfiles) { profile in
                    Text(profile.displayName).tag(Optional(profile.id))
                }
            }
        } header: {
            Text("What happens next")
                .font(Theme.Face.chrome(.footnote))
                .foregroundStyle(Theme.muted)
                .textCase(nil)
        }
    }

    /// Every workflow, and its steps, in one menu.
    ///
    /// Sections rather than a second level: a nested menu on a phone is a second
    /// tap that hides the answer, and there are rarely many workflows.
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
    /// The chevron is `up.chevron.down.chevron` and not `chevron.right`: this row
    /// opens a menu where it stands, and the row-chevron is the vocabulary this app
    /// deliberately dropped from its lists.
    private func consequenceRow(_ label: String, value: String, isChosen: Bool) -> some View {
        HStack(spacing: Theme.Space.snug) {
            Text(label)
                .font(Theme.Face.chrome(.callout))
                .foregroundStyle(Theme.muted)
            Spacer(minLength: Theme.Space.base)
            Text(value)
                .font(Theme.Face.chrome(.callout))
                .foregroundStyle(isChosen ? Theme.ink : Theme.muted)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)
        }
        .contentShape(Rectangle())
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

    // MARK: - When nothing is set up

    /// The third door: what to do when there is no agent to do anything.
    ///
    /// A disabled button and the words "no agent profiles" is a screen someone
    /// cannot get out of. A chat that edits Kandev's own configuration is exactly
    /// the thing that fixes this, so it is offered here rather than in a settings
    /// screen nobody has found yet.
    private var setupSection: some View {
        Section {
            Button {
                startChat(.config)
            } label: {
                consequenceRow("Change the setup", value: "Setup chat", isChosen: true)
            }
        } header: {
            Text("No agent is set up")
                .font(Theme.Face.chrome(.footnote))
                .foregroundStyle(Theme.muted)
                .textCase(nil)
        } footer: {
            Text("Nothing can start until there is one. The setup chat can make one — it changes Kandev's own settings, not this task's.")
                .font(Theme.Face.chrome(.footnote))
                .foregroundStyle(Theme.muted)
        }
    }

    // MARK: - The other door

    /// Asking instead of filing.
    ///
    /// Quieter than the toolbar's Create, because filing is what this app is for —
    /// but not hidden, because needing an answer now is the commoner reason to open
    /// a phone. It carries the sentence with it, so nothing written is thrown away.
    private var askSection: some View {
        Section {
            Button {
                startChat(.quick)
            } label: {
                Text("Just ask instead")
                    .font(Theme.Face.chrome(.callout))
                    .foregroundStyle(store.canAsk ? Theme.muted : Theme.muted.opacity(0.45))
            }
            .disabled(!store.canAsk)
        } footer: {
            if !store.canAsk && !store.needsAgentProfile {
                Text("A chat needs a sentence and an agent, and no workflow at all.")
                    .font(Theme.Face.chrome(.footnote))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: - Doing it

    private func create() {
        Task {
            guard let task = await store.create() else { return }
            onOpened(OpenedTask(taskID: task.id, sentence: ""))
        }
    }

    private func startChat(_ kind: KandevChatKind) {
        Task {
            guard let chat = await store.startChat(kind: kind) else { return }
            onOpened(OpenedTask(taskID: chat.taskID, sentence: store.brief))
        }
    }
}
