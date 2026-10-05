import Foundation

/// Where a Kandev server lives, and how a base URL becomes a WebSocket URL.
///
/// Kept as pure functions so the mapping is testable without a socket.
public enum KandevEndpoint {
    /// The path the WebSocket gateway is mounted on.
    public static let webSocketPath = "/ws"

    /// The `Origin` a WebSocket upgrade has to carry.
    ///
    /// Kandev's origin gate compares the browser's `Origin` hostname with the
    /// request's `Host`, and ignores `X-Forwarded-Host`. `URLSession` is not a
    /// browser, so it sends no `Origin` at all — and a server with authentication
    /// on refuses the upgrade without one. That is every real deployment: the
    /// refusal looks like a socket that opens and closes, with nothing said about
    /// why.
    ///
    /// Verified against a live server: the same URL answers `101 Switching
    /// Protocols` with this header and `400` without it.
    public static func webSocketOrigin(baseURL: URL) -> String? {
        guard let host = baseURL.host, !host.isEmpty else { return nil }
        let isSecure = ["https", "wss"].contains(baseURL.scheme?.lowercased() ?? "")
        var origin = "\(isSecure ? "https" : "http")://\(host)"
        if let port = baseURL.port, port != 80, port != 443 {
            origin += ":\(port)"
        }
        return origin
    }

    /// Builds the WebSocket URL for a server.
    ///
    /// - `http` becomes `ws` and `https` becomes `wss`.
    /// - A missing port becomes `KandevWireVersion.defaultPort` **only for a plain
    ///   `http` address**, which is how a server on your own machine is written.
    ///   An `https` address keeps the standard port: a deployment behind TLS is
    ///   reached on 443, and forcing Kandev's own port onto it dials a port nothing
    ///   is listening on. An explicit port is always kept.
    /// - Any path on the base URL is replaced by `/ws`.
    /// - A token, when given, is appended as `?token=`. Kandev accepts this for
    ///   clients that cannot send an `Authorization` header during the upgrade.
    public static func webSocketURL(baseURL: URL, token: String? = nil) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw KandevError.invalidBaseURL(baseURL.absoluteString)
        }

        var isSecure = false
        switch components.scheme?.lowercased() {
        case "http", "ws", nil:
            components.scheme = "ws"
        case "https", "wss":
            components.scheme = "wss"
            isSecure = true
        case .some(let scheme):
            throw KandevError.unsupportedScheme(scheme)
        }

        guard let host = components.host, !host.isEmpty else {
            throw KandevError.invalidBaseURL(baseURL.absoluteString)
        }

        if components.port == nil, !isSecure {
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
