import Foundation

/// A repository a workspace can attach work to.
///
/// Read from `GET /api/v1/workspaces/{id}/repositories`, whose shape comes from the
/// vendored reference for `repository.list`. The live server this client was tested
/// against has none configured, so this reads the documented fields and nothing
/// more — a field invented here would be a field that silently stays empty.
public struct KandevRepository: Sendable, Decodable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// `local` for a path on this machine, otherwise the provider's own name.
    public var sourceType: String?
    public var localPath: String?
    public var provider: String?
    public var defaultBranch: String?

    public init(
        id: String,
        name: String = "",
        sourceType: String? = nil,
        localPath: String? = nil,
        provider: String? = nil,
        defaultBranch: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sourceType = sourceType
        self.localPath = localPath
        self.provider = provider
        self.defaultBranch = defaultBranch
    }

    enum CodingKeys: String, CodingKey {
        case id, name, provider
        case sourceType = "source_type"
        case localPath = "local_path"
        case defaultBranch = "default_branch"
    }

    /// Where this repository actually is.
    ///
    /// A local repository is a path and a hosted one is a provider, and one of the
    /// two is what tells apart two repositories whose names look alike.
    public var origin: String {
        if let localPath, !localPath.isEmpty { return localPath }
        if let provider, !provider.isEmpty { return provider }
        return sourceType ?? "unknown"
    }
}

/// The answer to `GET /api/v1/workspaces/{id}/repositories`.
public struct KandevRepositoryList: Sendable, Decodable, Equatable {
    public var repositories: [KandevRepository]
    public var total: Int?
}

public extension KandevHTTPRoute {
    /// The workspace's repositories. HTTP, and the first-party client reads the
    /// same route to offer them when a task is created.
    static func workspaceRepositories(workspaceID: String) -> String {
        "/api/v1/workspaces/\(workspaceID)/repositories"
    }
}
