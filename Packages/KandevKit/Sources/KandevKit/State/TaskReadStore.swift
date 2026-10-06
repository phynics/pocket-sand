import Foundation
import Observation

/// Which tasks have been looked at, so a row can say something is new without the server
/// saying it.
///
/// The server keeps a read cursor of its own — `last_read_message_id` on the session,
/// advanced by a route the first-party client calls — but a task list row does not carry it,
/// and fetching a session per row to get one is not a list's job. This is the list's own
/// answer: the moment a conversation was last opened, against the activity the server last
/// reported.
@MainActor
@Observable
public final class TaskReadStore {
    /// The activity each task was last looked at, by task id.
    private var seenAt: [String: Date]
    private let defaults: UserDefaults
    private static let key = "task-read-seen"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.seenAt = Self.load(from: defaults)
    }

    /// Whether the task has done anything since it was last opened.
    ///
    /// A task nobody has opened is **not** unread: there is no baseline for anything to have
    /// passed, which is the server's own rule for a session's first visit. A task with no
    /// reported activity is not unread either — there is nothing to have missed.
    public func isUnread(taskID: String, lastActivity: Date?) -> Bool {
        guard let lastActivity, let seen = seenAt[taskID] else { return false }
        return lastActivity > seen
    }

    /// Records that a task was looked at.
    ///
    /// Stamped with the later of the activity that was on screen and now. The list keeps its own
    /// copy of that activity and refreshes it on its own schedule, so it can be a little ahead of
    /// the conversation's — and a row that stays marked after it has been read is the mark lying.
    public func markSeen(taskID: String, activity: Date?, now: Date = Date()) {
        seenAt[taskID] = max(activity ?? .distantPast, now)
        save()
    }

    private static func load(from defaults: UserDefaults) -> [String: Date] {
        guard let data = defaults.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func save() {
        let raw = seenAt.mapValues(\.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(raw) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
