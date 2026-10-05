import KandevKit
import SwiftUI

/// A task's workflow position, as a spine at the leading edge of its row.
///
/// A filled pill on every row is the default treatment and it costs a container
/// per row. A spine instead: colour becomes a column you can scan down the list,
/// and the step's name sits under the title where it reads as part of the
/// sentence about the task rather than as a badge attached to it.
///
/// The colour is the server's, unchanged. The palette maps tailwind class names,
/// which is what the server sends, onto system hues.
struct StepSpine: View {
    let colorToken: String?
    var state: SpineState = .quiet

    var body: some View {
        Rectangle()
            .fill(fill)
            .frame(width: state.width)
            .brightness(state.brightness)
            .workingPulse(state.isPulsing, period: state.pulsePeriod)
    }

    /// The workflow's colour, except when the task has failed — and then the one hue
    /// this app borrows, because it does not own it. A failed task's step colour is
    /// the least interesting thing about it.
    private var fill: Color {
        state == .failed ? .red : (StepPalette.color(forToken: colorToken) ?? Theme.muted)
    }
}

/// What a task's spine is saying.
///
/// The spine already carries the workflow's colour, so the only thing left for it to
/// say is the task's own condition — and it says it with motion and weight rather than
/// with a second mark beside it. A square in the corner said "attention" and nothing
/// else, and it read as a stray artefact rather than as part of the row.
enum SpineState: Equatable {
    /// Nothing is happening and nothing has been missed.
    case quiet
    /// Something has happened since this task was last opened, and nothing is happening
    /// now. Heavier than quiet: a mark to catch the eye rather than motion to hold it.
    case unread
    /// An agent is working. The slow pulse is what "is anything happening" looks like.
    case working
    /// An agent has asked a person something and cannot go on without the answer. The fast
    /// pulse, because "does anything need me" is a more urgent question than "is anything
    /// happening".
    case asking
    /// The server called the task failed.
    case failed

    /// Whether the mark breathes.
    ///
    /// Only work and a question do. Waiting to be read is not something to animate, and a row
    /// that blinks while nothing is happening is a row that lies about it: motion here means
    /// an agent is doing something, and nothing else may borrow it.
    var isPulsing: Bool {
        switch self {
        case .working, .asking: true
        case .quiet, .unread, .failed: false
        }
    }

    /// How long one breath takes. A question breathes at about twice the rate of work, which
    /// is what makes the two legible without a second colour or a second mark.
    var pulsePeriod: TimeInterval {
        self == .asking ? 0.55 : 1.1
    }

    /// A wider mark for what has not been read yet. Weight reads as importance without
    /// introducing a hue, and the spine is the one place on the row that is not text.
    var width: CGFloat {
        self == .unread ? Theme.Spine.width + 2 : Theme.Spine.width
    }

    /// And brighter, for the same reason. Small: the spine is the only colour on the row, and
    /// a large lift washes the hue out.
    var brightness: Double {
        self == .unread ? 0.12 : 0
    }
}

/// A step's name and colour, inline, for a header.
struct StepLabel: View {
    let name: String
    var colorToken: String?

    var body: some View {
        HStack(spacing: Theme.Space.hair + 2) {
            Rectangle()
                .fill(StepPalette.color(forToken: colorToken) ?? Theme.muted)
                .frame(width: Theme.Spine.width, height: 12)
            Text(name)
                .font(Theme.Face.chrome(.footnote, weight: .medium))
                .foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step: \(name)")
    }
}

/// The workflow's own colours.
///
/// The server sends tailwind class names because its web client is tailwind. The
/// mapping lives at the edge where that fact belongs, and an unknown class falls
/// back to muted rather than to an invented hue.
enum StepPalette {
    static func color(forToken token: String?) -> Color? {
        guard let token, token.hasPrefix("bg-") else { return nil }
        let family = token
            .dropFirst(3)
            .split(separator: "-")
            .first
            .map(String.init)

        switch family {
        case "slate", "gray", "zinc", "neutral", "stone": return .gray
        case "red", "rose": return .red
        case "orange": return .orange
        case "amber", "yellow": return .yellow
        case "lime", "green", "emerald", "teal": return .green
        case "cyan", "sky", "blue", "indigo": return .blue
        case "violet", "purple", "fuchsia", "pink": return .purple
        default: return nil
        }
    }
}

#Preview("Spines and labels") {
    VStack(alignment: .leading, spacing: Theme.Space.loose) {
        HStack(spacing: 0) {
            StepSpine(colorToken: "bg-blue-500", state: .working)
            Text("In Progress, working").padding(.leading, Theme.Spine.textInset)
        }
        HStack(spacing: 0) {
            StepSpine(colorToken: "bg-yellow-500", state: .unread)
            Text("Unread since you last looked").padding(.leading, Theme.Spine.textInset)
        }
        HStack(spacing: 0) {
            StepSpine(colorToken: "bg-blue-500", state: .asking)
            Text("Asked a question").padding(.leading, Theme.Spine.textInset)
        }
        HStack(spacing: 0) {
            StepSpine(colorToken: "bg-red-500", state: .failed)
            Text("Failed").padding(.leading, Theme.Spine.textInset)
        }
        HStack(spacing: 0) {
            StepSpine(colorToken: "bg-yellow-500")
            Text("Review").padding(.leading, Theme.Spine.textInset)
        }
        HStack(spacing: 0) {
            StepSpine(colorToken: nil)
            Text("An unknown step colour").padding(.leading, Theme.Spine.textInset)
        }
        StepLabel(name: "In Progress", colorToken: "bg-blue-500")
    }
    .padding()
    .background(Theme.paper)
}
