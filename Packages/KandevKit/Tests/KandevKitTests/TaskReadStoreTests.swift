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
        store.markSeen(taskID: "t1", activity: noon)

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

    @Test("it survives a restart")
    func survivesARestart() {
        let defaults = defaults()
        let noon = Date(timeIntervalSince1970: 1_000_000)
        TaskReadStore(defaults: defaults).markSeen(taskID: "t1", activity: noon)

        let restarted = TaskReadStore(defaults: defaults)
        #expect(restarted.isUnread(taskID: "t1", lastActivity: noon.addingTimeInterval(60)))
        #expect(restarted.isUnread(taskID: "t1", lastActivity: noon) == false)
    }
}
