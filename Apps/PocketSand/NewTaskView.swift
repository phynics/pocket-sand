import KandevKit
import SwiftUI

/// Creating a task.
///
/// Deliberately a real form rather than a one-line prompt: a task needs a
/// workflow, and the brief is the agent's first message, not a note about it.
struct NewTaskView: View {
    let store: NewTaskStore
    let onCreated: (KandevTask) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $store.title, axis: .vertical)
                        .font(Theme.Face.prose(.title3))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1...3)
                    TextField("What should the agent do?", text: $store.brief, axis: .vertical)
                        .font(Theme.Face.prose(.body))
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(Theme.proseLineSpacing)
                        .lineLimit(3...10)
                } header: {
                    Text("The work")
                        .font(Theme.Face.chrome(.footnote))
                        .foregroundStyle(Theme.muted)
                        .textCase(nil)
                } footer: {
                    // Worth saying plainly: the server sends this text as the
                    // agent's first message, word for word.
                    Text("The brief becomes the agent's first message. Write it as an instruction.")
                        .font(Theme.Face.chrome(.footnote))
                        .foregroundStyle(Theme.muted)
                }

                Section {
                    Picker("Workflow", selection: $store.workflowID) {
                        ForEach(store.workflows) { workflow in
                            Text(workflow.name).tag(Optional(workflow.id))
                        }
                    }
                    .onChange(of: store.workflowID) { _, newValue in
                        guard let newValue else { return }
                        store.selectWorkflow(newValue)
                    }

                    if !store.orderedSteps.isEmpty {
                        Picker("Start in", selection: $store.stepID) {
                            Text("The workflow's start step").tag(String?.none)
                            ForEach(store.orderedSteps) { step in
                                Text(step.name).tag(Optional(step.id))
                            }
                        }
                    }
                } header: {
                    Text("Workflow")
                        .font(Theme.Face.chrome(.footnote))
                        .foregroundStyle(Theme.muted)
                        .textCase(nil)
                }

                if !store.agentProfiles.isEmpty {
                    Section {
                        Picker("Agent", selection: $store.agentProfileID) {
                            Text("None yet").tag(String?.none)
                            ForEach(store.agentProfiles) { profile in
                                Text(profile.displayName).tag(Optional(profile.id))
                            }
                        }
                    } header: {
                        Text("Agent")
                            .font(Theme.Face.chrome(.footnote))
                            .foregroundStyle(Theme.muted)
                            .textCase(nil)
                    } footer: {
                        // The honest version: choosing an agent records it on the
                        // task; whether one starts now is the step's decision.
                        Text("Recorded on the task. Whether an agent starts now is up to the workflow step.")
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
            }
            .paperBackground()
            .scrollContentBackground(.hidden)
            .navigationTitle("New task")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .overlay {
                if store.isLoadingOptions && store.workflows.isEmpty {
                    ProgressView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(Theme.Face.chrome(.callout))
                        .foregroundStyle(Theme.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if let task = await store.create() { onCreated(task) }
                        }
                    } label: {
                        if store.phase == .creating {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Create")
                                .font(Theme.Face.chrome(.callout, weight: .semibold))
                                .foregroundStyle(store.canCreate ? Theme.ink : Theme.muted)
                        }
                    }
                    .disabled(!store.canCreate)
                }
            }
            .task { await store.loadOptions() }
        }
    }
}
