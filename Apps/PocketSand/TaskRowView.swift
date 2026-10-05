import KandevKit
import SwiftUI

/// One task in the list.
///
/// A title you read, a step you scan, a time you compare. The title is set in a
/// serif at headline size so the list reads as a table of contents rather than as
/// rows of data — the question it answers is "which of these needs me", and that
/// is answered by reading, not by parsing.
///
/// The time is mono because it is a token, not prose, and right-aligned so the
/// column of times is comparable down the page without the eye jumping.
struct TaskRowView: View {
    let row: TaskRow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.hair) {
            // The whole width is the title's now. It is the content of this screen —
            // the question the list answers is "which of these needs me", and that is
            // answered by reading a sentence, so a column of times beside it was
            // trading reading room for a number.
            Text(row.title)
                .font(Theme.Face.prose(.body))
                .foregroundStyle(Theme.ink)
                // Three lines, because an ellipsis in the middle of a sentence is
                // worse than a slightly taller row.
                .lineLimit(3)

            HStack(spacing: Theme.Space.snug) {
                if let step = row.stepName {
                    Text(step)
                        .font(Theme.Face.chrome(.footnote))
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: Theme.Space.snug)
                if let activity = row.lastActivity {
                    // Still right-aligned, so the times stay comparable down the page
                    // without the eye jumping — but on the step's line, under the
                    // title's full width rather than beside it.
                    Text(CompactAge.label(for: activity))
                        .font(Theme.Face.machine(.caption))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .monospacedDigit()
                }
            }
        }
        // The padding is inside the background, so the spine spans the row's height
        // and starts at the very edge of the screen — which is what turns a column of
        // separate spines into one colour column. The gap is inside it too, so the
        // column keeps its rhythm and still stops at each row's edge.
        // The spine stays at the screen's edge whatever the depth, so the colour column
        // stays one column, and the indent is the whole of the hierarchy: a subtask's
        // text starts where its parent's step does. A rule in the gap said the same
        // thing a second time, and two vertical lines a few points apart read as one
        // line drawn badly.
        .padding(.leading, Theme.Space.loose + indent)
        .padding(.trailing, Theme.Space.loose)
        .padding(.vertical, Theme.Space.base + 2)
        .background(alignment: .leading) {
            StepSpine(colorToken: row.stepColor, state: spineState)
                .padding(.vertical, Theme.Spine.gap)
        }

        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// How far the content sits in from the spine.
    private var indent: CGFloat {
        row.depth > 0 ? Theme.Space.loose : 0
    }

    /// What the spine is saying, in the order the conditions exclude each other.
    ///
    /// A failed task is not also working, and a task waiting on an answer is not
    /// merely "waiting for you": one has stopped, the other has not.
    private var spineState: SpineState {
        if row.isFailed { return .failed }
        if row.isAwaitingAnswer { return .answering }
        if row.isWorking { return .working }
        if row.needsAttention { return .attention }
        return .quiet
    }

    /// A row said aloud, in the order a person would say it.
    private var accessibilityLabel: String {
        var parts = [row.title]
        if let step = row.stepName { parts.append("Step \(step)") }
        if row.isFailed { parts.append("Failed") }
        else if row.isAwaitingAnswer { parts.append("Waiting for your answer") }
        else if row.isWorking { parts.append("Agent working") }
        else if row.needsAttention { parts.append("Waiting for you") }
        if let activity = row.lastActivity {
            parts.append("Last activity \(activity.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: ", ")
    }
}

#Preview("Rows") {
    VStack(spacing: 0) {
        TaskRowView(row: TaskRow(
            id: "1", title: "Implement embedded Zenoh transport",
            stepName: "In Progress", stepColor: "bg-blue-500",
            isWorking: true, needsAttention: false,
            lastActivity: .now.addingTimeInterval(-90)
        ))
        Rule()
        TaskRowView(row: TaskRow(
            id: "2", title: "Zenoh device driver for C-only scenario",
            stepName: "Review", stepColor: "bg-yellow-500",
            isWorking: false, needsAttention: true,
            lastActivity: .now.addingTimeInterval(-7200)
        ))
        Rule()
        TaskRowView(row: TaskRow(
            id: "3", title: "A task whose step could not be resolved and whose title runs long enough to wrap onto a second line",
            stepName: nil, isWorking: false, needsAttention: false, lastActivity: nil
        ))
    }
    .background(Theme.paper)
}
