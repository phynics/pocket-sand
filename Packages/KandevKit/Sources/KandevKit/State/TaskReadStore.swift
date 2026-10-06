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

    /// Whether the task has anything in it that has not been read.
    ///
    /// A task nobody has opened is unread: none of it has been looked at, which is the same thing
    /// as activity arriving after the last look. A task with no activity at all is not unread —
    /// there is nothing to have missed.
    ///
    /// The consequence worth knowing: on a device that has never opened a list, every task in it
    /// starts unread and goes quiet as it is read. A task that arrives later — created here or
    /// elsewhere — is unread from its first appearance.
    public func isUnread(taskID: String, lastActivity: Date?) -> Bool {
        guard let lastActivity else { return false }
        guard let seen = seenAt[taskID] else { return true }
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
