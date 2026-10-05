import Foundation

/// A workspace: the scope that owns repositories, workflows, tasks, and defaults.
///
/// Verified against a live server via `workspace.list`.
public struct KandevWorkspace: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var taskPrefix: String?
    /// `owner`, `admin`, `member`, `guest`, or empty when authentication is off.
    public var viewerRole: String?
    /// Permission names such as `task.write`, `session.prompt`, `workspace.read`.
    ///
    /// These arrive with the list, so the app can hide a control it has no right
    /// to use without a second request.
    public var scopes: [String]

    public enum CodingKeys: String, CodingKey {
        case id, name, description, scopes
        case taskPrefix = "task_prefix"
        case viewerRole = "viewer_role"
    }

    /// Declared in the body rather than an extension: an extension initialiser
    /// with the same signature as the synthesised memberwise one is a
    /// redeclaration, and defaults are what make these pleasant to call.
    public init(
        id: String,
        name: String,
        description: String? = nil,
        taskPrefix: String? = nil,
        viewerRole: String? = nil,
        scopes: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.taskPrefix = taskPrefix
        self.viewerRole = viewerRole
        self.scopes = scopes
    }

    /// Whether the caller may start or stop agent work in this workspace.
    public var canControlSessions: Bool { scopes.contains("session.control") }
    /// Whether the caller may send prompts.
    public var canPrompt: Bool { scopes.contains("session.prompt") }
    /// Whether the caller may change tasks.
    public var canWriteTasks: Bool { scopes.contains("task.write") }
}

/// A workflow: the ordered steps a task moves through.
public struct KandevWorkflow: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var workspaceID: String?
    public var sortOrder: Int?
    /// `kanban` or `pipeline`.
    public var style: String?
    /// A workflow can carry its own agent instructions.
    ///
    /// On a real server this runs to kilobytes (one workflow held a ~2KB
    /// briefing), so fetch workflows once and keep them; do not refetch them
    /// alongside every task list refresh.
    public var prompt: String?

    public enum CodingKeys: String, CodingKey {
        case id, name, description, prompt, style
        case workspaceID = "workspace_id"
        case sortOrder = "sort_order"
    }

    public init(
        id: String,
        name: String,
        description: String? = nil,
        workspaceID: String? = nil,
        sortOrder: Int? = nil,
        style: String? = nil,
        prompt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.workspaceID = workspaceID
        self.sortOrder = sortOrder
        self.style = style
        self.prompt = prompt
    }
}

/// One step of a workflow: a task's process position.
public struct KandevWorkflowStep: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var workflowID: String?
    public var name: String
    /// Zero-based order within the workflow.
    public var position: Int
    /// A tailwind class such as `bg-blue-500`, not a colour value.
    public var color: String?
    public var stageType: String?
    public var isStartStep: Bool?

    public enum CodingKeys: String, CodingKey {
        case id, name, position, color
        case workflowID = "workflow_id"
        case stageType = "stage_type"
        case isStartStep = "is_start_step"
    }

    public init(
        id: String,
        workflowID: String? = nil,
        name: String,
        position: Int,
        color: String? = nil,
        stageType: String? = nil,
        isStartStep: Bool? = nil
    ) {
        self.id = id
        self.workflowID = workflowID
        self.name = name
        self.position = position
        self.color = color
        self.stageType = stageType
        self.isStartStep = isStartStep
    }
}
