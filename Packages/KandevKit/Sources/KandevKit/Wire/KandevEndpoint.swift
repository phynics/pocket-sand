import Foundation

/// Where a Kandev server lives, and how a base URL becomes a WebSocket URL.
///
/// Kept as pure functions so the mapping is testable without a socket.
public enum KandevEndpoint {
    /// The path the WebSocket gateway is mounted on.
    public static let webSocketPath = "/ws"

    /// Builds the WebSocket URL for a server.
    ///
    /// - `http` becomes `ws` and `https` becomes `wss`.
    /// - A missing port becomes `KandevWireVersion.defaultPort`.
    /// - Any path on the base URL is replaced by `/ws`.
    /// - A token, when given, is appended as `?token=`. Kandev accepts this for
    ///   clients that cannot send an `Authorization` header during the upgrade.
    public static func webSocketURL(baseURL: URL, token: String? = nil) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw KandevError.invalidBaseURL(baseURL.absoluteString)
        }

        switch components.scheme?.lowercased() {
        case "http", "ws", nil:
            components.scheme = "ws"
        case "https", "wss":
            components.scheme = "wss"
        case .some(let scheme):
            throw KandevError.unsupportedScheme(scheme)
        }

        guard let host = components.host, !host.isEmpty else {
            throw KandevError.invalidBaseURL(baseURL.absoluteString)
        }

        if components.port == nil {
            components.port = KandevWireVersion.defaultPort
        }

        components.path = webSocketPath
        components.queryItems = token.map { [URLQueryItem(name: "token", value: $0)] }

        guard let url = components.url else {
            throw KandevError.invalidBaseURL(baseURL.absoluteString)
        }
        return url
    }
}
