import Foundation

/// A server address, validated.
///
/// This is logic that used to live inside `ConnectView`, where nothing could
/// reach it. A view should be able to ask whether an address is usable and get a
/// yes or no, not own the rule.
///
/// The rule is deliberately strict: a scheme is required. Accepting a bare host
/// and assuming `http` would make `kandev.local` and `http://kandev.local` mean the same thing,
/// which hides the one decision the user has to make deliberately — whether this
/// server is reached over a plaintext connection.
public struct ServerAddress: Sendable, Equatable, Hashable {
    public let url: URL

    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else { return nil }
        self.url = url
    }

    public init?(_ url: URL) {
        self.init(string: url.absoluteString)
    }

    public var displayText: String { url.absoluteString }

    /// The host, which is what a token is keyed by and what a user recognises.
    public var host: String? { url.host }

    /// Identifies the server regardless of how it was typed.
    ///
    /// `http://kandev.local:38429` and `http://kandev.local:38429/` are the same server, and a
    /// user who types both should not end up with two bookmarks and two tokens.
    /// Only scheme, host, and port name a server: nothing after the port does.
    public var canonicalKey: String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    /// Explains the rule when it is not met, for the one place that shows it.
    public static let rejectionMessage =
        "Enter an address that starts with http:// or https:// and names a host."
}
