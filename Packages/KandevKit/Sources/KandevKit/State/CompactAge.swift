import Foundation

/// How long ago something happened, written for a dense list.
///
/// "43 minutes ago" costs a third of a phone's width and pushes the thing you are
/// actually reading into an ellipsis. Compact forms keep the column narrow enough
/// that a column of them is still scannable, and the full phrasing belongs in an
/// accessibility label where width is not a constraint.
public enum CompactAge {
    public static func label(for date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        if seconds < 2_592_000 { return "\(Int(seconds / 86_400))d" }
        if seconds < 31_536_000 { return "\(Int(seconds / 2_592_000))mo" }
        return "\(Int(seconds / 31_536_000))y"
    }
}
