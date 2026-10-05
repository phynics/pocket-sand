import Foundation
import Testing

@testable import KandevKit

@Suite("CompactDuration")
struct CompactDurationTests {
    @Test("seconds below a minute")
    func seconds() {
        #expect(CompactDuration.label(seconds: 0) == "0s")
        #expect(CompactDuration.label(seconds: 14.4) == "14s")
        #expect(CompactDuration.label(seconds: 59.4) == "59s")
        // Rounds up into a minute, which is where the unit changes.
        #expect(CompactDuration.label(seconds: 59.6) == "1m")
    }

    /// The case that made this type necessary: a turn of three minutes read as
    /// "186,7s" on a device with a decimal comma.
    @Test("minutes and seconds past a minute")
    func minutes() {
        #expect(CompactDuration.label(seconds: 60) == "1m")
        #expect(CompactDuration.label(seconds: 90) == "1m 30s")
        #expect(CompactDuration.label(seconds: 186.7) == "3m 7s")
        #expect(CompactDuration.label(seconds: 600) == "10m")
    }

    @Test("stays with minutes rather than inventing an hours unit")
    func longTurns() {
        #expect(CompactDuration.label(seconds: 3600) == "60m")
    }

    @Test("never writes a decimal separator")
    func noDecimalSeparator() {
        for seconds in [14.4, 90.5, 186.7, 3599.9] {
            let label = CompactDuration.label(seconds: seconds)
            #expect(!label.contains(",") && !label.contains("."), "\(label) has a separator")
        }
    }
}
