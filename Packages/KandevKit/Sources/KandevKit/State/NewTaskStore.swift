import Foundation
import Observation

/// The form for creating a task, and for the two chats that are not a task.
///
/// Owns the choices as well as the text: a task needs a workflow, and the brief
/// is not a description but the session's first prompt, so both have to be
/// nothing-specific before this can offer to submit.
///
/// It also owns the third thing this screen can do. A chat is not a different
/// object on the server — starting one creates a task and a session — so a chat
/// started here opens in the same screen a task does, and the sentence that
/// started it is not thrown away.
@MainActor
@Observable
public final class NewTaskStore {
    public enum Phase: Equatable {
        case editing
        case creating
        case failed(String)
    }

    /// The task's name. Written from the brief until someone edits it, because a
    /// task needs a title and nobody wants to write the same sentence twice.
    public var title = "" {
        didSet {
            guard !isDerivingTitle else { return }
            titleIsDerived = false
        }
    }

    /// What needs doing, in the words of whoever wants it done. The server sends
    /// this to the agent as the first message, word for word.
    public var brief = "" {
        didSet {
            guard titleIsDerived else { return }
            isDerivingTitle = true
            title = Self.derivedTitle(from: brief)
            isDerivingTitle = false
        }
    }

    public var workspaceID: String?
    public var workflowID: String?
    public var stepID: String?
    public var agentProfileID: String?

    public private(set) var phase: Phase = .editing
    public private(set) var workspaces: [KandevWorkspace] = []
    public private(set) var agentProfiles: [KandevAgentProfile] = []
    public private(set) var isLoadingOptions = false
    /// The task the server created, once it has.
    public private(set) var createdTask: KandevTask?
    /// The chat the server started, once it has.
    public private(set) var startedChat: KandevChat?

    /// Whether the title is still following the brief.
    private var titleIsDerived = true
    /// Guards the derivation above from looking like someone typing.
    private var isDerivingTitle = false

    private let taskSource: any KandevTaskSource
    private let creator: any KandevTaskCreating
    private let profileSource: (any KandevSessionStarting)?
    private let chatStarter: (any KandevChatStarting)?
    /// The workspace's workflows and steps, shared with the list that has already
    /// read them. A store created without one owns its own.
    private let catalogue: WorkflowCatalogue

    public init(
        taskSource: any KandevTaskSource,
        creator: any KandevTaskCreating,
        profileSource: (any KandevSessionStarting)? = nil,
        chatStarter: (any KandevChatStarting)? = nil,
        catalogue: WorkflowCatalogue? = nil,
        workspaceID: String? = nil,
        workflowID: String? = nil
    ) {
        self.taskSource = taskSource
        self.creator = creator
        self.profileSource = profileSource
        self.chatStarter = chatStarter
        self.catalogue = catalogue ?? WorkflowCatalogue(source: taskSource)
        self.workspaceID = workspaceID
        self.workflowID = workflowID
    }

    /// The workspace's workflows, for the picker.
    public var workflows: [KandevWorkflow] { catalogue.workflows }

    /// Whether the screen can file a task: a workflow to file it in, and a title,
    /// which the server requires. A brief is optional — an empty one would make an
    /// empty first prompt, which is worse than no prompt at all.
    public var canFile: Bool {
        guard phase != .creating, workflowID != nil else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the screen can start a chat. A chat needs an agent and something to
    /// say; it does **not** need a workflow, which is the whole difference.
    public var canAsk: Bool {
        guard phase != .creating, agentProfileID != nil else { return false }
        return !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The state worth offering help in: profiles were asked for and there are
    /// none, so neither door can open.
    ///
    /// Saying "no agent is set up" and stopping there leaves someone in a screen
    /// that cannot work. This is what the screen uses to offer the one thing that
    /// can fix it.
    public var needsAgentProfile: Bool {
        profileSource != nil && !isLoadingOptions && agentProfiles.isEmpty
    }

    /// Steps in the order the workflow puts them, for a picker that reads like
    /// the board does.
    public var orderedSteps: [KandevWorkflowStep] {
        catalogue.steps(for: workflowID)
    }

    public func loadOptions() async {
        guard !isLoadingOptions else { return }
        isLoadingOptions = true
        defer { isLoadingOptions = false }

        do {
            workspaces = try await taskSource.workspaces()
            // A server with no workspaces cannot be created in. Saying so is
            // better than a form whose pickers are silently empty.
            guard let workspace = workspaces.first(where: { $0.id == workspaceID }) ?? workspaces.first
            else {
                phase = .failed("This server has no workspaces to create tasks in.")
                return
            }
            workspaceID = workspace.id

            try await catalogue.load(workspaceID: workspace.id)
            if workflowID == nil { workflowID = preferredWorkflow()?.id }
            if let profileSource {
                agentProfiles = (try? await profileSource.agentProfiles()) ?? []
                // Chosen rather than asked about: a task almost always wants the
                // one agent that is set up, and the choice is one tap away.
                if agentProfileID == nil {
                    agentProfileID = agentProfiles.first { $0.enabled == true }?.id
                        ?? agentProfiles.first?.id
                }
            }
        } catch {
            phase = .failed(KandevError.readableMessage(for: error))
        }
    }

    /// Files the task in one move: a workflow and a step chosen together, because
    /// that is one decision and not two. A step of `nil` means the workflow's own
    /// start step, which is the server's decision and not this client's.
    ///
    /// Setting both is what keeps a step from surviving a change of workflow: the
    /// catalogue holds every workflow's steps, so the wrong one could be named
    /// without being re-read.
    public func file(workflowID: String, stepID: String?) {
        self.workflowID = workflowID
        self.stepID = stepID
    }

    /// One workflow's steps, in its own order, for the menu that files a task.
    public func steps(forWorkflow id: String) -> [KandevWorkflowStep] {
        catalogue.steps(for: id)
    }

    /// Creates the task, and returns it.
    ///
    /// The result is the task itself, so the caller can go to it. Refetching the
    /// list to find what was just created would be slower and could miss it.
    @discardableResult
    public func create() async -> KandevTask? {
        guard let workspaceID, let workflowID, canFile else { return nil }
        phase = .creating
        defer { if phase == .creating { phase = .editing } }

        let draft = KandevTaskDraft(
            workspaceID: workspaceID,
            workflowID: workflowID,
            stepID: stepID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            brief: brief.trimmingCharacters(in: .whitespacesAndNewlines),
            agentProfileID: agentProfileID
        )
        do {
            let task = try await creator.createTask(draft)
            createdTask = task
            phase = .editing
            return task
        } catch {
            phase = .failed(KandevError.readableMessage(for: error))
            return nil
        }
    }

    /// The workflow to preselect.
    ///
    /// The first the workspace has. A workspace names a default workflow, but this
    /// client does not read that field yet, and the choice is right there to change.
    private func preferredWorkflow() -> KandevWorkflow? {
        workflows.first
    }

    /// Starts a chat, and returns the task and session behind it.
    ///
    /// A chat is a task on the server, so the caller can open the same screen a
    /// task opens — and the sentence that started the chat travels with it.
    @discardableResult
    public func startChat(kind: KandevChatKind) async -> KandevChat? {
        guard let chatStarter, let workspaceID, let agentProfileID, canAsk else { return nil }
        phase = .creating
        defer { if phase == .creating { phase = .editing } }

        do {
            let chat = try await chatStarter.startChat(
                kind: kind,
                workspaceID: workspaceID,
                agentProfileID: agentProfileID,
                title: chatTitle(for: kind)
            )
            startedChat = chat
            phase = .editing
            return chat
        } catch {
            phase = .failed(KandevError.readableMessage(for: error))
            return nil
        }
    }

    /// What the chat's task is called.
    ///
    /// A chat has no title field of its own, and the first-party client names them
    /// "<agent> - Chat 3", which says nothing in a list. The sentence the person
    /// wrote is a better name, and it is already there.
    private func chatTitle(for kind: KandevChatKind) -> String {
        switch kind {
        case .quick:
            let derived = Self.derivedTitle(from: brief)
            if !derived.isEmpty { return derived }
            return agentProfiles.first { $0.id == agentProfileID }?.displayName ?? "Chat"
        case .config:
            return "Change the setup"
        }
    }

    /// A task's title, taken from the first thing the person wrote.
    ///
    /// The first non-empty line, with any markdown marker removed — people paste
    /// headings and bulleted text into a brief, and "## Fix the flaky test" is a
    /// worse title than "Fix the flaky test". A long line is cut at a word boundary
    /// rather than mid-word.
    nonisolated static func derivedTitle(from brief: String, limit: Int = 60) -> String {
        let firstLine = brief
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        let unmarked = firstLine.drop { character in
            character == "#" || character == "-" || character == "*"
                || character == ">" || character == " " || character == "\t"
        }
        let trimmed = unmarked.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let head = trimmed.prefix(limit)
        guard let lastSpace = head.lastIndex(of: " ") else { return head + "…" }
        return head[..<lastSpace] + "…"
    }
}
