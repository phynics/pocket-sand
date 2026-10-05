import Foundation
import Testing

@testable import KandevKit

@Suite("CompactAge")
struct CompactAgeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func label(afterSeconds seconds: TimeInterval) -> String {
        CompactAge.label(for: now.addingTimeInterval(-seconds), now: now)
    }

    /// The boundaries, because an off-by-one here shows a wrong number rather
    /// than failing loudly.
    @Test("changes unit at the boundary, not a second later")
    func boundaries() {
        #expect(label(afterSeconds: 0) == "now")
        #expect(label(afterSeconds: 59) == "now")
        #expect(label(afterSeconds: 60) == "1m")
        #expect(label(afterSeconds: 3_599) == "59m")
        #expect(label(afterSeconds: 3_600) == "1h")
        #expect(label(afterSeconds: 86_399) == "23h")
        #expect(label(afterSeconds: 86_400) == "1d")
        #expect(label(afterSeconds: 2_591_999) == "29d")
        #expect(label(afterSeconds: 2_592_000) == "1mo")
        #expect(label(afterSeconds: 31_535_999) == "12mo")
        #expect(label(afterSeconds: 31_536_000) == "1y")
    }

    /// A clock that disagrees with the server should not produce "-3m".
    @Test("a future timestamp reads as now rather than as a negative")
    func futureIsNow() {
        #expect(CompactAge.label(for: now.addingTimeInterval(120), now: now) == "now")
    }
}
