import Foundation
import Observation
import Security

/// A saved server.
public struct ServerBookmark: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    /// What the user calls it. Defaults to the host.
    public var name: String
    public var baseURLString: String

    public init(id: UUID = UUID(), name: String, baseURLString: String) {
        self.id = id
        self.name = name
        self.baseURLString = baseURLString
    }

    /// The address, once it validates. `nil` for a bookmark that was stored by an
    /// older build and no longer parses.
    public var address: ServerAddress? { ServerAddress(string: baseURLString) }

    public var baseURL: URL? { address?.url }

    /// The account a server's token is stored under. Keyed by host so that
    /// re-adding the same server finds its token again.
    public var tokenAccount: String {
        address?.host ?? baseURLString
    }

    /// A sensible name when the user does not supply one.
    public static func suggestedName(for urlString: String) -> String {
        URL(string: urlString)?.host ?? urlString
    }
}

/// Where tokens are kept.
///
/// A protocol rather than free functions so tests can use memory. Exercising the
/// real Keychain from a test is worse than it sounds: an unsigned test binary can
/// make the system put up a prompt, and a test suite that blocks on a dialog is
/// not a test suite.
public protocol TokenStorage: Sendable {
    func token(for account: String) -> String?
    func setToken(_ token: String?, for account: String)
}

/// Personal access tokens, in the Keychain.
///
/// A token is a credential, so it does not go in `UserDefaults` beside the URL.
/// Kandev only needs one when its authentication feature is on, which is off by
/// default, so an absent token is the normal case rather than an error.
public struct KeychainTokenStorage: TokenStorage {
    private let service: String

    public init(service: String = "codes.pocketsand.kandev") {
        self.service = service
    }

    public func token(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setToken(_ token: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Delete then add, rather than branching on update: it is one code path
        // and it cannot leave a stale item behind.
        SecItemDelete(base as CFDictionary)

        guard let token, !token.isEmpty else { return }
        var attributes = base
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

/// The servers this app knows about.
///
/// Follows the plan recorded for v1: several may be saved, but nothing in the UI
/// picks between them yet — the most recent one is used, and the rest are
/// reachable from the connect screen.
@MainActor
@Observable
public final class ServerBookmarkStore {
    private static let bookmarksKey = "servers.bookmarks"
    private static let activeKey = "servers.active"

    public private(set) var bookmarks: [ServerBookmark] = []
    public private(set) var activeID: UUID?

    private let defaults: UserDefaults
    private let tokens: any TokenStorage

    public init(
        defaults: UserDefaults = .standard,
        tokens: any TokenStorage = KeychainTokenStorage()
    ) {
        self.defaults = defaults
        self.tokens = tokens
        if let data = defaults.data(forKey: Self.bookmarksKey),
           let saved = try? JSONDecoder().decode([ServerBookmark].self, from: data) {
            bookmarks = saved
        }
        if let raw = defaults.string(forKey: Self.activeKey) {
            activeID = UUID(uuidString: raw)
        }
    }

    public var active: ServerBookmark? {
        guard let activeID else { return bookmarks.first }
        return bookmarks.first { $0.id == activeID } ?? bookmarks.first
    }

    public func token(for bookmark: ServerBookmark) -> String? {
        tokens.token(for: bookmark.tokenAccount)
    }

    /// Saves a server and makes it the active one.
    @discardableResult
    public func add(
        baseURLString: String,
        name: String? = nil,
        token: String? = nil
    ) -> ServerBookmark {
        let trimmed = ServerAddress(string: baseURLString)?.displayText
            ?? baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = ServerAddress(string: trimmed)
        let bookmark: ServerBookmark
        if let existing = bookmarks.first(where: {
            guard let address else { return $0.baseURLString == trimmed }
            return $0.address?.canonicalKey == address.canonicalKey
        }) {
            bookmark = existing
        } else {
            bookmark = ServerBookmark(
                name: name?.isEmpty == false ? name! : ServerBookmark.suggestedName(for: trimmed),
                baseURLString: trimmed
            )
            bookmarks.append(bookmark)
        }
        if let token, !token.isEmpty {
            tokens.setToken(token, for: bookmark.tokenAccount)
        }
        setActive(bookmark.id)
        persist()
        return bookmark
    }

    public func setActive(_ id: UUID?) {
        activeID = id
        defaults.set(id?.uuidString, forKey: Self.activeKey)
    }

    public func remove(_ bookmark: ServerBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        tokens.setToken(nil, for: bookmark.tokenAccount)
        if activeID == bookmark.id { setActive(bookmarks.first?.id) }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        defaults.set(data, forKey: Self.bookmarksKey)
    }
}

/// A connected server, and the state that lives as long as the connection does.
///
/// Created once per connection and held by the root view. Everything above the
/// transport hangs off this, so a view can never accidentally build a second
/// socket to the same server.
@MainActor
@Observable
public final class AppSession {
    public let bookmark: ServerBookmark
    public let client: KandevClient
    /// The workspace's workflows and steps, read once and shared by the screens
    /// that need them.
    public let catalogue: WorkflowCatalogue
    public let taskList: TaskListStore

    public init(bookmark: ServerBookmark, token: String?) {
        let url = bookmark.baseURL ?? URL(string: "http://localhost")!
        let client = KandevClient(baseURL: url, token: token)
        let catalogue = WorkflowCatalogue(source: client)
        self.bookmark = bookmark
        self.client = client
        self.catalogue = catalogue
        self.taskList = TaskListStore(source: client, hub: client.hub, catalogue: catalogue)
    }

    public func connect() async throws {
        try await client.connect()
    }
}

