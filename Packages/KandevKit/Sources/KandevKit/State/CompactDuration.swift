import Foundation

/// How long a turn took, written for someone reading it.
///
/// Two reasons this is not `formatted()`. A locale-aware number formatter writes
/// 186.7 as "186,7" in half of Europe, which reads as a version number rather than
/// a duration; and 186.7 seconds is not a quantity anyone thinks in. "3m 7s" is.
public enum CompactDuration {
    /// The same length spelled out, for a sentence rather than a chip.
    ///
    /// "Running for 3 minutes and 35 seconds" is a sentence; "3m 35s" is a label. The
    /// sentence form is for the line that says what a turn is doing, where the words
    /// matter more than the space.
    public static func spoken(seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "\(total) \(plural(total, "second"))" }

        let minutes = total / 60
        let minutesPart = "\(minutes) \(plural(minutes, "minute"))"
        let remainder = total % 60
        guard remainder > 0 else { return minutesPart }
        return "\(minutesPart) and \(remainder) \(plural(remainder, "second"))"
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        count == 1 ? noun : "\(noun)s"
    }

    public static func label(seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "\(total)s" }

        let minutes = total / 60
        let remainder = total % 60
        guard remainder > 0 else { return "\(minutes)m" }
        return "\(minutes)m \(remainder)s"
    }
}
