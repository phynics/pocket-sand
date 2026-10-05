import Foundation

/// How long a turn took, written for someone reading it.
///
/// Two reasons this is not `formatted()`. A locale-aware number formatter writes
/// 186.7 as "186,7" in half of Europe, which reads as a version number rather than
/// a duration; and 186.7 seconds is not a quantity anyone thinks in. "3m 7s" is.
public enum CompactDuration {
    public static func label(seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "\(total)s" }

        let minutes = total / 60
        let remainder = total % 60
        guard remainder > 0 else { return "\(minutes)m" }
        return "\(minutes)m \(remainder)s"
    }
}
