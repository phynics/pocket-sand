import Foundation

/// The container shapes the server wraps list responses in.
///
/// Each was read off a live server. They are separate types rather than a
/// generic `List<Item>` because the server names the arrays differently per
/// action (`workspaces`, `workflows`, `steps`, `tasks`, `messages`).
public struct KandevWorkspaceList: Sendable, Decodable, Equatable {
    public var workspaces: [KandevWorkspace]
    public var total: Int?
}

public struct KandevWorkflowList: Sendable, Decodable, Equatable {
    public var workflows: [KandevWorkflow]
    public var total: Int?
}

public struct KandevWorkflowStepList: Sendable, Decodable, Equatable {
    public var steps: [KandevWorkflowStep]
    public var total: Int?
}

public struct KandevTaskList: Sendable, Decodable, Equatable {
    public var tasks: [KandevTask]
    public var total: Int

    public init(tasks: [KandevTask], total: Int) {
        self.tasks = tasks
        self.total = total
    }
}

public struct KandevSessionList: Sendable, Decodable, Equatable {
    public var sessions: [KandevSession]
    public var total: Int?

    public init(sessions: [KandevSession], total: Int? = nil) {
        self.sessions = sessions
        self.total = total
    }
}

/// The orderings the task list endpoint accepts.
///
/// Verified against `NormalizeTasksListSort` in the server: these six names are
/// the whole set, and anything else is silently replaced by `updated_desc`.
public enum KandevTaskSort: String, Sendable, CaseIterable {
    case updatedDesc = "updated_desc"
    case updatedAsc = "updated_asc"
    case createdDesc = "created_desc"
    case createdAsc = "created_asc"
    case titleAsc = "title_asc"
    case titleDesc = "title_desc"
}

/// Parameters for `GET /api/v1/workspaces/{id}/tasks`.
public struct KandevTaskListQuery: Sendable, Equatable {
    public enum ArchiveMode: Sendable, Equatable {
        /// Only unarchived tasks. The default.
        case active
        case includingArchived
        case onlyArchived

        var queryItems: [URLQueryItem] {
            switch self {
            case .active: []
            case .includingArchived: [URLQueryItem(name: "include_archived", value: "true")]
            case .onlyArchived: [URLQueryItem(name: "only_archived", value: "true")]
            }
        }
    }

    /// The server caps this at 100 and ignores anything larger.
    public static let maximumPageSize = 100

    public var page: Int?
    public var pageSize: Int?
    public var sort: KandevTaskSort?
    public var search: String?
    public var workflowID: String?
    public var repositoryID: String?
    public var archived: ArchiveMode
    /// Drops configuration sessions, which are not work you can act on.
    public var excludeConfig: Bool
    /// Whether ephemeral tasks — quick chats — are included.
    ///
    /// The server leaves them out unless asked, which is how the first-party client
    /// hides them. A list that shows them has to ask: the grouping is not enough on its
    /// own, and a chat the server never sent cannot be grouped.
    public var includeEphemeral: Bool

    public init(
        page: Int? = nil,
        pageSize: Int? = nil,
        sort: KandevTaskSort? = nil,
        search: String? = nil,
        workflowID: String? = nil,
        repositoryID: String? = nil,
        archived: ArchiveMode = .active,
        excludeConfig: Bool = true,
        includeEphemeral: Bool = false
    ) {
        self.page = page
        self.pageSize = pageSize
        self.sort = sort
        self.search = search
        self.workflowID = workflowID
        self.repositoryID = repositoryID
        self.archived = archived
        self.excludeConfig = excludeConfig
        self.includeEphemeral = includeEphemeral
    }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let page { items.append(URLQueryItem(name: "page", value: String(page))) }
        if let pageSize {
            items.append(
                URLQueryItem(name: "page_size", value: String(min(pageSize, Self.maximumPageSize)))
            )
        }
        if let sort { items.append(URLQueryItem(name: "sort", value: sort.rawValue)) }
        if let search, !search.isEmpty {
            items.append(URLQueryItem(name: "query", value: search))
        }
        if let workflowID { items.append(URLQueryItem(name: "workflow_id", value: workflowID)) }
        if let repositoryID { items.append(URLQueryItem(name: "repository_id", value: repositoryID)) }
        items.append(contentsOf: archived.queryItems)
        if excludeConfig { items.append(URLQueryItem(name: "exclude_config", value: "true")) }
        if includeEphemeral { items.append(URLQueryItem(name: "include_ephemeral", value: "true")) }
        return items
    }
}
