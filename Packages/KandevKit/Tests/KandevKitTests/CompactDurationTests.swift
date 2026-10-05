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
import Foundation
import Testing

@testable import KandevKit

/// The sentence form of a duration, for the line that says what a turn is doing.
@Suite("Duration in words")
struct SpokenDurationTests {
    @Test("seconds alone, spelled out and pluralised")
    func seconds() {
        #expect(CompactDuration.spoken(seconds: 0) == "0 seconds")
        #expect(CompactDuration.spoken(seconds: 1) == "1 second")
        #expect(CompactDuration.spoken(seconds: 45) == "45 seconds")
        #expect(CompactDuration.spoken(seconds: 59.4) == "59 seconds", "rounded, not truncated")
    }

    @Test("minutes and seconds, joined the way a person says them")
    func minutes() {
        #expect(CompactDuration.spoken(seconds: 60) == "1 minute")
        #expect(CompactDuration.spoken(seconds: 120) == "2 minutes")
        #expect(CompactDuration.spoken(seconds: 215) == "3 minutes and 35 seconds")
        #expect(CompactDuration.spoken(seconds: 181) == "3 minutes and 1 second")
    }

    @Test("the chip form stays short, because it is a label and not a sentence")
    func chipFormIsUnchanged() {
        #expect(CompactDuration.label(seconds: 215) == "3m 35s")
        #expect(CompactDuration.label(seconds: 60) == "1m")
        #expect(CompactDuration.label(seconds: 45) == "45s")
    }
}
