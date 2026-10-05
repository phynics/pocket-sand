import Foundation

/// The queue's own error vocabulary.
///
/// Every code here comes from the server, read off the first-party client rather
/// than guessed from a message string: message text is for humans and changes,
/// and a limit parsed out of prose is a latent bug. A full queue arrives as a
/// rejected admission carrying `details.max`, so it is translated into a state
/// the composer can explain instead of a generic failure.
public enum KandevQueueFailure {
    /// Rejected because the session's queue is at capacity.
    public static let full = "queue_full"
    /// The prompt named a `client_queue_id` the server has already seen.
    public static let idConflict = "queue_id_conflict"
    /// The session cannot accept prompts right now.
    public static let sessionUnavailable = "queue_session_unavailable"
    /// Admission is temporarily unavailable; the same request is worth retrying.
    public static let admissionUnavailable = "queue_admission_unavailable"

    /// Send-now refused to claim the selection the user made.
    public static let sendNowCodes: Set<String> = [
        "queue_empty",
        "queue_changed",
        "send_now_conflict",
        "turn_changed",
        "send_now_attachment_overflow",
        "send_now_reference_overflow",
    ]

    /// The capacity to show when the server does not state one.
    ///
    /// Not a guess about the server's configuration: the queue reported `max: 5`
    /// on a live server, and this is only the fallback for a frame that omits it.
    public static let fallbackLimit = 5

    public static func translate(_ error: KandevError) -> KandevError {
        guard case .action(let failure) = error else { return error }
        if failure.code == full {
            return .queueFull(limit: failure.details?["max"]?.intValue ?? fallbackLimit)
        }
        return error
    }
}
