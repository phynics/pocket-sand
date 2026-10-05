import Foundation

/// One frame of the Kandev `/ws` protocol, in either direction.
///
/// The envelope is vendored from upstream at
/// `docs/reference/kandev-websocket-api.md` and was verified against
/// `KandevWireVersion.verifiedServerVersion`. `id` is present on requests and
/// responses and absent on notifications.
public struct KandevEnvelope: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case request
        case response
        case notification
        case error
    }

    public var id: String?
    public var type: Kind
    public var action: String?
    public var payload: JSONValue?
    public var timestamp: String?

    public init(
        id: String? = nil,
        type: Kind,
        action: String? = nil,
        payload: JSONValue? = nil,
        timestamp: String? = nil
    ) {
        self.id = id
        self.type = type
        self.action = action
        self.payload = payload
        self.timestamp = timestamp
    }
}

extension KandevEnvelope {
    /// Builds a request frame. The `id` correlates the eventual response.
    public static func request(
        id: String = UUID().uuidString,
        action: String,
        payload: JSONValue? = nil
    ) -> KandevEnvelope {
        KandevEnvelope(id: id, type: .request, action: action, payload: payload)
    }
}

/// The payload of an `error` frame.
///
/// Kandev sends `code`, `message`, and optional `details`. `code` is the stable
/// part: `VALIDATION_ERROR` for a bad payload, `UNKNOWN_ACTION` for an action the
/// server does not register, `FORBIDDEN` for the `mcp.` family the raw gateway
/// refuses.
public struct KandevErrorPayload: Sendable, Codable, Equatable {
    public var code: String
    public var message: String
    public var details: JSONValue?

    public init(code: String, message: String, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}
