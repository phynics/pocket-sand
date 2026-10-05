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
        #expect(url.absoluteString == "wss://kandev.example.com:38429/ws")
    }

    @Test("fills in the default port")
    func defaultsThePort() throws {
        let url = try KandevEndpoint.webSocketURL(baseURL: URL(string: "http://kandev.local")!)
        #expect(url.port == KandevWireVersion.defaultPort)
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
