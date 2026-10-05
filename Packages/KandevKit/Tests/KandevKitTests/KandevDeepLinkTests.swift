import Foundation
import Testing

@testable import KandevKit

@Suite("KandevDeepLink")
struct KandevDeepLinkTests {
    @Test("parses a task link")
    func parsesTaskLink() {
        #expect(KandevDeepLink(url: URL(string: "pocketsand://task/abc-123")!) == .task(id: "abc-123"))
    }

    @Test("accepts a trailing slash and ignores case in the scheme and host")
    func toleratesVariations() {
        #expect(KandevDeepLink(url: URL(string: "PocketSand://TASK/abc-123/")!) == .task(id: "abc-123"))
    }

    @Test("rejects another app's scheme")
    func rejectsForeignScheme() {
        #expect(KandevDeepLink(url: URL(string: "https://task/abc")!) == nil)
    }

    @Test("rejects an unknown host rather than guessing")
    func rejectsUnknownHost() {
        #expect(KandevDeepLink(url: URL(string: "pocketsand://settings")!) == nil)
    }

    @Test("rejects a task link with no id")
    func rejectsMissingID() {
        #expect(KandevDeepLink(url: URL(string: "pocketsand://task")!) == nil)
        #expect(KandevDeepLink(url: URL(string: "pocketsand://task/")!) == nil)
    }
}
