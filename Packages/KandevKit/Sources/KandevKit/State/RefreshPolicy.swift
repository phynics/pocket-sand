import Foundation

/// When a screen should read the server again.
///
/// Both of the events that ask for a refresh arrive in bursts. iOS sends
/// `.active` after every interruption — a notification banner, the app switcher, a
/// phone call — and a socket on a phone that keeps losing its network reconnects in
/// a loop. Without a floor, each burst is a request, and a screen that is opened and
/// closed ten times is ten reads of the same unchanged list.
///
/// So this is a debounce, not a schedule: nothing here refreshes on a timer. It only
/// decides whether an event that just happened is worth acting on, given when the
/// last read was.
public struct RefreshPolicy: Sendable, Equatable {
    /// The shortest gap between two reads.
    ///
    /// Twenty seconds: long enough that a burst of scene changes collapses to one
    /// read, short enough that a phone picked up after a minute shows what happened
    /// while it was down.
    public static let defaultInterval: TimeInterval = 20

    public let minimumInterval: TimeInterval
    public private(set) var lastRefreshAt: Date?

    public init(
        minimumInterval: TimeInterval = RefreshPolicy.defaultInterval,
        lastRefreshAt: Date? = nil
    ) {
        self.minimumInterval = minimumInterval
        self.lastRefreshAt = lastRefreshAt
    }

    /// Whether a read is due. Never read is always due, however recently the app
    /// started: an empty screen has nothing to be stale relative to.
    public func isDue(at now: Date) -> Bool {
        guard let lastRefreshAt else { return true }
        return now.timeIntervalSince(lastRefreshAt) >= minimumInterval
    }

    /// Records that a read happened, which is what starts the next interval.
    ///
    /// Called for reads the person asked for as well as the automatic ones: a pull
    /// to refresh is a read, and a scene change a second later should not repeat it.
    public mutating func record(at now: Date) {
        lastRefreshAt = now
    }
}

/// How long to wait before trying a dropped socket again.
///
/// Doubling, then flat. The first retry is quick because a socket that dropped while
/// the screen was locked is usually back the moment the app is awake. The ceiling
/// matters for the other case: a server that is off is off for hours, and a client
/// that retries it every second is a battery complaint from someone who never
/// notices it is working.
public enum ReconnectBackoff {
    public static let first: Duration = .milliseconds(500)
    public static let ceiling: Duration = .seconds(30)

    public static func delay(forAttempt attempt: Int) -> Duration {
        guard attempt > 0 else { return first }
        // Capped before the multiplication, so a long-lived failure cannot overflow
        // into a negative wait.
        let doubled = first * (1 << min(attempt, 8))
        return doubled > ceiling ? ceiling : doubled
    }
}
