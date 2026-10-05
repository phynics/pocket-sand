import Foundation
import Testing

@testable import KandevKit

@Suite("ServerAddress")
struct ServerAddressTests {
    @Test("accepts an http or https address with a host")
    func acceptsValidAddresses() throws {
        #expect(ServerAddress(string: "http://kandev.local:38429")?.host == "kandev.local")
        #expect(ServerAddress(string: "https://kandev.example.com")?.host == "kandev.example.com")
        #expect(ServerAddress(string: "http://127.0.0.1:38429")?.host == "127.0.0.1")
    }

    @Test("trims surrounding whitespace, because a paste usually has some")
    func trimsWhitespace() {
        #expect(ServerAddress(string: "  http://kandev.local:38429 \n")?.host == "kandev.local")
    }

    @Test("refuses a bare host rather than assuming a scheme")
    func refusesBareHost() {
        #expect(ServerAddress(string: "kandev.local:38429") == nil)
        #expect(ServerAddress(string: "kandev.local") == nil)
        #expect(ServerAddress(string: "kandev.local") == nil)
    }

    @Test("refuses an empty or whitespace-only entry")
    func refusesEmpty() {
        #expect(ServerAddress(string: "") == nil)
        #expect(ServerAddress(string: "   ") == nil)
    }

    @Test("refuses a scheme it cannot speak")
    func refusesOtherSchemes() {
        #expect(ServerAddress(string: "ftp://kandev.local") == nil)
        #expect(ServerAddress(string: "ws://kandev.local") == nil)
        #expect(ServerAddress(string: "file:///etc/hosts") == nil)
    }

    @Test("refuses an address with no host")
    func refusesMissingHost() {
        #expect(ServerAddress(string: "http://") == nil)
        #expect(ServerAddress(string: "https:///path") == nil)
    }

    /// Two spellings, one server. What matters is that a user who types both does
    /// not end up with two bookmarks and two tokens.
    @Test("treats the same server spelled differently as one server")
    func canonicalKeyIgnoresSpelling() throws {
        let plain = try #require(ServerAddress(string: "http://kandev.local:38429"))
        let slashed = try #require(ServerAddress(string: "http://kandev.local:38429/"))
        let shouty = try #require(ServerAddress(string: "HTTP://kandev.local:38429"))

        #expect(plain.canonicalKey == slashed.canonicalKey)
        #expect(plain.canonicalKey == shouty.canonicalKey)
        #expect(plain.canonicalKey == "http://kandev.local:38429")
    }

    @Test("distinguishes servers that differ by port or scheme")
    func canonicalKeyKeepsWhatMatters() throws {
        let plain = try #require(ServerAddress(string: "http://kandev.local:38429"))
        let otherPort = try #require(ServerAddress(string: "http://kandev.local:1234"))
        let secure = try #require(ServerAddress(string: "https://kandev.local:38429"))

        #expect(plain.canonicalKey != otherPort.canonicalKey)
        #expect(plain.canonicalKey != secure.canonicalKey)
    }
}
