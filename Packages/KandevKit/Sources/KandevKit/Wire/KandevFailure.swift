import Foundation

/// A failure an action reports *inside* a `response` frame.
///
/// Some Kandev actions answer with `{"success": false, "error": {...}}` in a
/// normal response, instead of sending an `error` frame. Verified against
/// `KandevWireVersion.verifiedServerVersion`: `session.conversation.subscribe`
/// with no `scope_id` answers
/// `{"success": false, "error": {"code": "invalid_request", ...}}`.
public struct KandevActionFailure: Sendable, Codable, Equatable {
    public var code: String
    public var message: String
    public var retryable: Bool?
    /// Extra facts a caller may need. `queue_full` reports the limit here, so a
    /// message string is never the only place the number lives.
    public var details: JSONValue?

    public init(
        code: String,
        message: String,
        retryable: Bool? = nil,
        details: JSONValue? = nil
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
    }
}

/// Kandev has two ways to say no, and they nest differently:
///
/// | Frame | Failure lives at |
/// | --- | --- |
/// | `type: "error"` | `payload.code`, `payload.message`, `payload.details` |
/// | `type: "response"` | `payload.success == false`, `payload.error.code` |
///
/// Both shapes are classified here and nowhere else, because a caller that has
/// to remember to check `success` is a caller that will eventually forget.
enum KandevFailure {
    static func failure(in envelope: KandevEnvelope) -> KandevError? {
        switch envelope.type {
        case .error:
            let payload = (try? envelope.payload?.decoded(as: KandevErrorPayload.self))
                ?? KandevErrorPayload(
                    code: "UNKNOWN",
                    message: "The server sent an error frame with no readable payload."
                )
            return .server(payload)

        case .response:
            guard let header = try? envelope.payload?.decoded(as: OutcomeHeader.self),
                  header.success == false
            else { return nil }
            return .action(
                header.error ?? KandevActionFailure(
                    code: "UNKNOWN",
                    message: "The server reported an unsuccessful result with no error detail."
                )
            )

        case .request, .notification:
            return nil
        }
    }

    private struct OutcomeHeader: Decodable {
        var success: Bool?
        var error: KandevActionFailure?
    }
}
