import Foundation

/// Everything that can go wrong between this app and a Kandev server.
public enum KandevError: Error, Sendable, Equatable {
    /// The base URL could not be turned into a WebSocket URL.
    case invalidBaseURL(String)
    /// The base URL uses a scheme that is not http, https, ws, or wss.
    case unsupportedScheme(String)
    /// `send` was called before `connect`.
    case notConnected
    /// The socket closed while requests were in flight.
    case connectionClosed
    /// No response arrived in time. Named by action, because "which request" is
    /// the only question worth asking about a timeout.
    case timedOut(action: String)
    /// A request frame had no `id`, so its response could not be correlated.
    case missingRequestID
    /// A frame was not valid JSON in the documented envelope shape.
    case malformedFrame(String)
    /// The server answered with an `error` frame.
    case server(KandevErrorPayload)
    /// The server answered with a `response` frame whose payload reported
    /// `success: false`. A different shape from `.server`; see `KandevFailure`.
    case action(KandevActionFailure)
    /// An HTTP route answered with a non-success status.
    case http(status: Int, body: String?)
    /// The session's queue is at capacity, so the prompt was not accepted.
    ///
    /// A state and not a failure of the app: the server's limit is five, and the
    /// queue drains as turns finish.
    case queueFull(limit: Int)
}

extension KandevError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            "\(value) is not a usable server address."
        case .unsupportedScheme(let scheme):
            "\(scheme) is not a supported scheme. Use http, https, ws, or wss."
        case .notConnected:
            "Not connected to a Kandev server."
        case .connectionClosed:
            "The connection to the Kandev server closed."
        case .timedOut(let action):
            "\(action) did not answer in time."
        case .missingRequestID:
            "A request was sent without an id, so its response cannot be matched."
        case .malformedFrame(let detail):
            "The server sent a frame this client could not read: \(detail)"
        case .server(let payload):
            payload.message
        case .action(let failure):
            failure.message
        case .http(let status, let body):
            Self.phrase(inBody: body).map { "The server answered HTTP \(status): \($0)" }
                ?? "The server answered HTTP \(status)."
        case .queueFull(let limit):
            "This session's queue already holds \(limit) prompts. It clears as the agent finishes each one."
        }
    }

    /// The sentence inside an HTTP failure body, when it is a sentence at all.
    ///
    /// An HTTP failure body is JSON far more often than not, and what a person wants
    /// from it is the server's own words rather than the braces around them. Several
    /// key names are tried because the envelope is the server's business; a body that
    /// is not JSON, or JSON with nothing to say, is shown as it came — trimmed, and
    /// cut rather than allowed to flood the screen.
    static func phrase(inBody body: String?) -> String? {
        guard let body else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            for key in ["message", "detail", "error"] {
                if let text = value[key]?.stringValue, !text.isEmpty { return text }
            }
            if let text = value["error"]?["message"]?.stringValue, !text.isEmpty { return text }
        }

        return trimmed.count > 200 ? trimmed.prefix(200) + "…" : trimmed
    }

    /// The server's error code from an HTTP failure body, when one can be found.
    ///
    /// Several shapes are tried because the envelope is the server's business:
    /// `{"code": …}`, `{"error": "…"}`, and `{"error": {"code": …}}`. A shape
    /// this does not recognise yields `nil`, which degrades to showing the
    /// generic error rather than inventing a code.
    public var httpErrorCode: String? {
        guard case .http(_, let body) = self,
              let body,
              let data = body.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }

        if let code = value["code"]?.stringValue { return code }
        if let code = value["error"]?.stringValue { return code }
        if let code = value["error"]?["code"]?.stringValue { return code }
        return nil
    }

    /// A message fit to show someone, for any error at all.
    ///
    /// Every store needs this, and three of them had grown their own copy.
    public static func readableMessage(for error: any Error) -> String {
        if let kandev = error as? KandevError {
            return kandev.errorDescription ?? String(describing: kandev)
        }
        return error.localizedDescription
    }

    /// The server's error code when the failure came from the server, so callers
    /// can act on `UNKNOWN_ACTION` or `FORBIDDEN` without string matching.
    public var serverCode: String? {
        switch self {
        case .server(let payload): payload.code
        case .action(let failure): failure.code
        default: nil
        }
    }
}
