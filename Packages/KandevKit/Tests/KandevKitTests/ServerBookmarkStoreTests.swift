import Foundation
import Testing

@testable import KandevKit

/// Token storage that forgets nothing and touches nothing.
final class InMemoryTokenStorage: TokenStorage, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private(set) var writes: [String] = []

    init(_ initial: [String: String] = [:]) {
        storage = initial
    }

    func token(for account: String) -> String? { storage[account] }

    func setToken(_ token: String?, for account: String) {
        writes.append(account)
        if let token, !token.isEmpty {
            storage[account] = token
        } else {
            storage.removeValue(forKey: account)
        }
    }
}

/// The observable store the connect screen binds to.
@MainActor
@Suite("ServerBookmarkStore")
struct ServerBookmarkStoreTests {
    /// Each test gets its own defaults domain, so tests cannot see each other's
    /// bookmarks and none of them touch the real app's settings.
    private func freshStore(
        tokens: InMemoryTokenStorage = InMemoryTokenStorage()
    ) -> (ServerBookmarkStore, UserDefaults, String) {
        let name = "test.servers.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (ServerBookmarkStore(defaults: defaults, tokens: tokens), defaults, name)
    }

    @Test("adds a server and makes it the active one")
    func addsAndActivates() {
        let (store, _, _) = freshStore()

        let bookmark = store.add(baseURLString: "http://kandev.local:38429")

        #expect(store.bookmarks.count == 1)
        #expect(store.active?.id == bookmark.id)
        #expect(store.active?.name == "kandev.local")
    }

    @Test("names a server after its host unless told otherwise")
    func derivesName() {
        let (store, _, _) = freshStore()

        #expect(store.add(baseURLString: "http://kandev.local:38429").name == "kandev.local")
        #expect(store.add(baseURLString: "http://box:38429", name: "Work").name == "Work")
    }

    @Test("survives a restart")
    func persistsAcrossStoreInstances() {
        let name = "test.servers.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let first = ServerBookmarkStore(defaults: defaults, tokens: InMemoryTokenStorage())
        let bookmark = first.add(baseURLString: "http://kandev.local:38429")

        let second = ServerBookmarkStore(defaults: defaults, tokens: InMemoryTokenStorage())

        #expect(second.bookmarks.map(\.id) == [bookmark.id])
        #expect(second.active?.id == bookmark.id)
    }

    @Test("adds a token only when one is given")
    func storesTokenOnlyWhenGiven() {
        let tokens = InMemoryTokenStorage()
        let (store, _, _) = freshStore(tokens: tokens)

        store.add(baseURLString: "http://kandev.local:38429")
        #expect(tokens.writes.isEmpty, "no token given, so nothing should be written")

        let withToken = store.add(baseURLString: "http://box:38429", token: "kandev_pat_abc")
        #expect(store.token(for: withToken) == "kandev_pat_abc")
    }

    @Test("does not save an empty token as if it were a credential")
    func ignoresEmptyToken() {
        let tokens = InMemoryTokenStorage()
        let (store, _, _) = freshStore(tokens: tokens)

        let bookmark = store.add(baseURLString: "http://kandev.local:38429", token: "")

        #expect(tokens.writes.isEmpty)
        #expect(store.token(for: bookmark) == nil)
    }

    /// The behaviour a user would notice: typing the same server twice should not
    /// leave two entries and two tokens to keep in step.
    @Test("recognises a server it already knows, however it is spelled")
    func deduplicatesTheSameServer() {
        let (store, _, _) = freshStore()

        let first = store.add(baseURLString: "http://kandev.local:38429")
        let second = store.add(baseURLString: "http://kandev.local:38429/")

        #expect(store.bookmarks.count == 1)
        #expect(first.id == second.id)
    }

    @Test("keeps servers that differ by port apart")
    func keepsDistinctServers() {
        let (store, _, _) = freshStore()

        store.add(baseURLString: "http://kandev.local:38429")
        store.add(baseURLString: "http://kandev.local:1234")

        #expect(store.bookmarks.count == 2)
    }

    @Test("removing a server forgets its token and picks another")
    func removingForgetsToken() {
        let tokens = InMemoryTokenStorage()
        let (store, _, _) = freshStore(tokens: tokens)

        let first = store.add(baseURLString: "http://kandev.local:38429", token: "kandev_pat_one")
        let second = store.add(baseURLString: "http://box:38429", token: "kandev_pat_two")
        #expect(store.active?.id == second.id)

        store.remove(second)

        #expect(store.bookmarks.map(\.id) == [first.id])
        #expect(store.token(for: second) == nil)
        #expect(store.active?.id == first.id, "a removal should not leave the app with no server")
    }

    @Test("switching the active server keeps both")
    func switchingKeepsBoth() {
        let (store, _, _) = freshStore()

        let first = store.add(baseURLString: "http://kandev.local:38429")
        let second = store.add(baseURLString: "http://box:38429")

        store.setActive(first.id)

        #expect(store.bookmarks.count == 2)
        #expect(store.active?.id == first.id)
        #expect(second.id != first.id)
    }

    @Test("a stored bookmark that no longer parses does not crash the store")
    func toleratesUnparseableBookmark() {
        let name = "test.servers.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let saved = [ServerBookmark(name: "Legacy", baseURLString: "kandev.local:38429")]
        defaults.set(try! JSONEncoder().encode(saved), forKey: "servers.bookmarks")

        let store = ServerBookmarkStore(defaults: defaults, tokens: InMemoryTokenStorage())

        #expect(store.bookmarks.count == 1)
        #expect(store.bookmarks.first?.address == nil)
        #expect(store.bookmarks.first?.tokenAccount == "kandev.local:38429")
    }
}

@Suite("AppSession")
struct AppSessionTests {
    @MainActor
    @Test("builds from a bookmark and keeps its identity")
    func buildsFromBookmark() {
        let bookmark = ServerBookmark(name: "kandev.local", baseURLString: "http://kandev.local:38429")

        let session = AppSession(bookmark: bookmark, token: "kandev_pat_abc")

        #expect(session.bookmark.id == bookmark.id)
        #expect(session.bookmark.name == "kandev.local")
    }

    @MainActor
    @Test("a bookmark whose address does not parse still yields a usable session")
    func toleratesUnparseableAddress() {
        let bookmark = ServerBookmark(name: "Legacy", baseURLString: "kandev.local:38429")

        let session = AppSession(bookmark: bookmark, token: nil)

        #expect(session.bookmark.name == "Legacy")
    }
}
