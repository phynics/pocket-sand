import Foundation
import Testing

@testable import KandevKit

@Suite("KandevEndpoint")
struct KandevEndpointTests {
    @Test("turns an http base URL into a ws URL at /ws")
    func httpBecomesWebSocket() throws {
        let url = try KandevEndpoint.webSocketURL(baseURL: URL(string: "http://kandev.local:38429")!)
        #expect(url.absoluteString == "ws://kandev.local:38429/ws")
    }

    @Test("keeps TLS when the base URL has it")
    func httpsBecomesSecureWebSocket() throws {
        let url = try KandevEndpoint.webSocketURL(baseURL: URL(string: "https://kandev.example.com")!)
        #expect(url.absoluteString == "wss://kandev.example.com/ws")
    }

    @Test("fills in the default port only for a plain http address")
    func defaultsThePort() throws {
        let plain = try KandevEndpoint.webSocketURL(baseURL: URL(string: "http://kandev.local")!)
        #expect(plain.port == KandevWireVersion.defaultPort)

        // A deployment behind TLS is on 443. Forcing Kandev's own port onto it
        // dials a port nothing is listening on, and the socket reports it as a
        // closed connection rather than as a wrong address.
        let secure = try KandevEndpoint.webSocketURL(baseURL: URL(string: "https://kandev.example.com")!)
        #expect(secure.port == nil, "so the standard port applies")

        let explicit = try KandevEndpoint.webSocketURL(
            baseURL: URL(string: "https://kandev.example.com:38429")!
        )
        #expect(explicit.port == 38429, "an explicit port is always kept")
    }

    @Test("replaces whatever path the user typed")
    func replacesPath() throws {
        let url = try KandevEndpoint.webSocketURL(baseURL: URL(string: "http://kandev.local:38429/somewhere/else")!)
        #expect(url.path == "/ws")
    }

    @Test("appends a token only when one is given")
    func appendsToken() throws {
        let withoutToken = try KandevEndpoint.webSocketURL(baseURL: URL(string: "http://kandev.local:38429")!)
        #expect(withoutToken.query == nil)

        let withToken = try KandevEndpoint.webSocketURL(
            baseURL: URL(string: "http://kandev.local:38429")!,
            token: "kandev_pat_abc"
        )
        #expect(withToken.query == "token=kandev_pat_abc")
    }

    @Test("refuses a scheme it cannot speak")
    func rejectsForeignScheme() {
        #expect(throws: KandevError.unsupportedScheme("ftp")) {
            try KandevEndpoint.webSocketURL(baseURL: URL(string: "ftp://kandev.local:38429")!)
        }
    }
}

/// The `Origin` header, which is not a detail: a server with authentication on
/// refuses the WebSocket upgrade without one, and says nothing about why.
@Suite("WebSocket origin")
struct WebSocketOriginTests {
    private func origin(_ string: String) -> String? {
        KandevEndpoint.webSocketOrigin(baseURL: URL(string: string)!)
    }

    @Test("a secure server gets a secure origin, and an insecure one does not")
    func scheme() {
        #expect(origin("https://kandev.example.com") == "https://kandev.example.com")
        #expect(origin("http://kandev.local:38429") == "http://kandev.local:38429")
        // `wss` is a socket scheme, not a web one: the origin it stands for is https.
        #expect(origin("wss://kandev.example.com") == "https://kandev.example.com")
    }

    @Test("a port is kept only when it is not the default for the scheme")
    func ports() {
        #expect(origin("https://kandev.example.com:443") == "https://kandev.example.com")
        #expect(origin("http://kandev.example.com:80") == "http://kandev.example.com")
        #expect(origin("http://kandev.example.com:38429") == "http://kandev.example.com:38429")
    }

    @Test("a host is required, and a path is not part of an origin")
    func hostOnly() {
        #expect(origin("https://kandev.example.com/some/path") == "https://kandev.example.com")
        #expect(origin("file:///tmp/thing") == nil)
    }
}
