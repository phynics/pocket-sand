import Foundation

/// A link into the app, so something outside it can open a task.
///
///     pocketsand://task/<task-id>
///
/// Worth having on its own terms — a notification or a shared link should land
/// on the task rather than the list — and it happens to make the app's
/// navigation drivable from a command line, which is how its screens get
/// verified.
public enum KandevDeepLink: Sendable, Equatable {
    public static let scheme = "pocketsand"
    /// `pocketsand://task` — the host carries the intent.
    public static let taskHost = "task"

    case task(id: String)

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        switch components.host?.lowercased() {
        case Self.taskHost:
            let id = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !id.isEmpty else { return nil }
            self = .task(id: id)
        default:
            return nil
        }
    }
}
