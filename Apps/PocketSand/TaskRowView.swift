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
    /// Whether anything has happened since this task was last opened.
    var isUnread = false
    /// Whether the row has to say which repository it belongs to.
    ///
    /// It does in a flat list, where no section heading says it for the row.
    var showsRepository = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.hair) {
            if showsRepository, let repository = row.repositoryName {
                Text(repository)
                    .font(Theme.Face.chrome(.caption2))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }

            Text(row.title)
                .font(Theme.Face.prose(.body))
                .foregroundStyle(isUnread ? Theme.ink : Theme.muted)
                // Three lines, because an ellipsis in the middle of a sentence is
                // worse than a slightly taller row.
                .lineLimit(3)

            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.snug) {
                Text(fact)
                    .font(Theme.Face.chrome(.footnote, weight: wantsAPerson ? .medium : .regular))
                    .foregroundStyle(wantsAPerson ? Theme.ink : Theme.muted)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.snug)
                if let activity = row.lastActivity {
                    // Still right-aligned, so the times stay comparable down the page
                    // without the eye jumping — but on the fact's line, under the
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
            StepSpine(colorToken: row.stepColor, state: spineState, isSeen: !isUnread)
                .padding(.vertical, Theme.Spine.gap)
        }

        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// What the row says under its title: what it wants, or where it sits.
    ///
    /// State first, on purpose. The list answers "which of these needs me", and a step name says
    /// where the work is rather than what it wants — so a task that wants a person says so, and a
    /// task that wants nobody says where it is. Whether it has been read is the title's colour and
    /// the spine's weight, and is not repeated here.
    private var fact: String {
        if row.isFailed { return "Failed" }
        if row.isAwaitingAnswer { return "Asked you a question" }
        if row.needsAttention { return "Waiting for you" }
        if row.isWorking { return row.stepName.map { "Working · \($0)" } ?? "Working" }
        return row.stepName ?? "No step"
    }

    /// Whether the fact is about the reader rather than about the work.
    private var wantsAPerson: Bool {
        row.wantsAPerson || isUnread
    }

    /// How far the content sits in from the spine.
    private var indent: CGFloat {
        row.depth > 0 ? Theme.Space.loose : 0
    }

    /// What the spine is saying, in the order the conditions exclude each other.
    ///
    /// A failed task is not also working, and a task waiting on an answer is not merely waiting
    /// for input: one has stopped on a question, the other has finished its turn. Motion is kept
    /// for the two states where an agent is doing something; whether the row has been read is the
    /// spine's weight rather than a state here.
    private var spineState: SpineState {
        if row.isFailed { return .failed }
        if row.isWorking { return .working }
        if row.isAwaitingAnswer { return .asking }
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
        // Said whether or not the spine is marking it: the mark clears when it is read, and
        // "a person is needed here" does not.
        if isUnread { parts.append("New since you last looked") }
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
