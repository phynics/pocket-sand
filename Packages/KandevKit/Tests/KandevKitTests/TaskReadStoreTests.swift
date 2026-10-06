import Foundation
import Testing

@testable import KandevKit

/// The list's own read clock. Small, but it is the difference between a row that says
/// something is new and a row that blinks at nothing.
@MainActor
@Suite("TaskReadStore")
struct TaskReadStoreTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "task-read-\(UUID().uuidString)")!
    }

    /// A task nobody has opened is not unread: there is no baseline for anything to have
    /// passed, which is the server's own rule for a session's first visit.
    @Test("a task nobody has opened is not unread")
    func neverOpenedIsNotUnread() {
        let store = TaskReadStore(defaults: defaults())

        #expect(store.isUnread(taskID: "t1", lastActivity: .now) == false)
    }

    @Test("activity after the last look makes a task unread")
    func activityAfterTheLookIsUnread() {
        let store = TaskReadStore(defaults: defaults())
        let noon = Date(timeIntervalSince1970: 1_000_000)
        store.markSeen(taskID: "t1", activity: noon, now: noon)

        #expect(store.isUnread(taskID: "t1", lastActivity: noon) == false)
        #expect(store.isUnread(taskID: "t1", lastActivity: noon.addingTimeInterval(60)))
        #expect(store.isUnread(taskID: "t1", lastActivity: noon.addingTimeInterval(-60)) == false)
    }

    @Test("a task with no reported activity is never unread")
    func noActivityIsNotUnread() {
        let store = TaskReadStore(defaults: defaults())
        store.markSeen(taskID: "t1", activity: .now)

        #expect(store.isUnread(taskID: "t1", lastActivity: nil) == false)
    }

    /// The list keeps its own copy of the activity and refreshes it on its own schedule, so it can
    /// be a little ahead of what the conversation read. A row that stays marked after it has been
    /// read is the mark lying.
    @Test("looking at a task clears the mark even when the list counted later")
    func lookingClearsAMarkFromAhead() {
        let store = TaskReadStore(defaults: defaults())
        let opened = Date(timeIntervalSince1970: 1_000_000)

        store.markSeen(taskID: "t1", activity: opened.addingTimeInterval(-60), now: opened)

        #expect(store.isUnread(taskID: "t1", lastActivity: opened) == false)
    }

    @Test("it survives a restart")
    func survivesARestart() {
        let defaults = defaults()
        let noon = Date(timeIntervalSince1970: 1_000_000)
        TaskReadStore(defaults: defaults).markSeen(taskID: "t1", activity: noon, now: noon)

        let restarted = TaskReadStore(defaults: defaults)
        #expect(restarted.isUnread(taskID: "t1", lastActivity: noon.addingTimeInterval(60)))
        #expect(restarted.isUnread(taskID: "t1", lastActivity: noon) == false)
    }
}
