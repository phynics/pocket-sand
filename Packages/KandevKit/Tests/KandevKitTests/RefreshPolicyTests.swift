import Foundation
import Testing

@testable import KandevKit

/// The debounce in front of every automatic refresh.
@Suite("Refresh policy")
struct RefreshPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// An empty screen has nothing to be stale relative to.
    @Test("a read is due when nothing has been read")
    func firstReadIsDue() {
        #expect(RefreshPolicy().isDue(at: start))
    }

    /// The reason it exists. An interruption, the app switcher, and a notification
    /// banner are three scene changes in about a second.
    @Test("collapses a burst into one read")
    func burstsCollapse() {
        var policy = RefreshPolicy(minimumInterval: 20)
        policy.record(at: start)

        #expect(policy.isDue(at: start.addingTimeInterval(0.1)) == false)
        #expect(policy.isDue(at: start.addingTimeInterval(19)) == false)
        #expect(policy.isDue(at: start.addingTimeInterval(20)))
    }

    @Test("reads again after a night on the shelf")
    func longSleepIsDue() {
        var policy = RefreshPolicy(minimumInterval: 20)
        policy.record(at: start)
        #expect(policy.isDue(at: start.addingTimeInterval(8 * 3600)))
    }

    /// A device whose clock moves backwards must not turn into an endless run of
    /// reads, which is what a negative elapsed time would cause.
    @Test("a clock that went backwards is not due")
    func backwardsClock() {
        var policy = RefreshPolicy(minimumInterval: 20)
        policy.record(at: start)
        #expect(policy.isDue(at: start.addingTimeInterval(-500)) == false)
    }
}

@Suite("Reconnect backoff")
struct ReconnectBackoffTests {
    @Test("waits a moment, then doubles")
    func doubling() {
        #expect(ReconnectBackoff.delay(forAttempt: 0) == .milliseconds(500))
        #expect(ReconnectBackoff.delay(forAttempt: 1) == .seconds(1))
        #expect(ReconnectBackoff.delay(forAttempt: 2) == .seconds(2))
        #expect(ReconnectBackoff.delay(forAttempt: 5) == .seconds(16))
        #expect(ReconnectBackoff.delay(forAttempt: 6) == .seconds(30))
    }

    /// A server that is off is off for hours. An attempt counter that kept doubling
    /// would overflow into a wait that never ends.
    @Test("a long failure never waits past the ceiling")
    func ceilingHolds() {
        for attempt in [8, 20, 60, 10_000] {
            #expect(ReconnectBackoff.delay(forAttempt: attempt) <= ReconnectBackoff.ceiling)
        }
    }
}

/// The store's side of the same rule: what a burst costs the server.
@MainActor
@Suite("Refreshing on waking")
struct RefreshDueTests {
    @Test("a burst of scene changes is one read")
    func burstIsOneRead() async {
        let source = FakeTaskSource()
        await source.setWorkspaces([KandevWorkspace(id: "w", name: "W")])
        await source.setTasks([KandevTask(id: "t", title: "T")])
        let store = TaskListStore(source: source)
        await store.refresh()

        let reads = await source.requestedPages.count
        let now = Date()

        // Three wakes inside the window: a banner, the app switcher, and coming back.
        #expect(await store.refreshIfDue(at: now.addingTimeInterval(1)) == false)
        #expect(await store.refreshIfDue(at: now.addingTimeInterval(2)) == false)
        #expect(await store.refreshIfDue(at: now.addingTimeInterval(3)) == false)
        #expect(await source.requestedPages.count == reads, "the server was not asked")

        // A minute later it is worth asking again.
        #expect(await store.refreshIfDue(at: now.addingTimeInterval(60)))
        #expect(await source.requestedPages.count == reads + 1)
    }
}
