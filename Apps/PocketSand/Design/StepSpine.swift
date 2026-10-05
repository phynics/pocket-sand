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
    /// Nothing is happening and nobody is needed.
    case quiet
    /// An agent is working.
    case working
    /// The ball is in a person's court: a review gate, or a session that finished its
    /// turn and is waiting for someone to say what next.
    case attention
    /// An agent has asked for something and work has stopped on the answer. Thicker,
    /// because this is the one state where a person is the blocker.
    case answering
    /// The server called the task failed.
    case failed

    /// How long one breath takes, or nil for a mark that holds still.
    ///
    /// Attention breathes at about twice the rate of work: "does anything need me" is a
    /// more urgent question than "is anything happening", and the difference in rate is
    /// what makes it legible without a second colour or a second mark.
    var pulsePeriod: TimeInterval {
        switch self {
        case .working: 1.1
        case .attention, .answering: 0.55
        case .quiet, .failed: 1.1
        }
    }

    var isPulsing: Bool {
        switch self {
        case .working, .attention, .answering: true
        case .quiet, .failed: false
        }
    }

    /// A wider mark when a person is the blocker. Weight reads as importance without
    /// introducing a hue, and the spine is the one place on the row that is not text.
    var width: CGFloat {
        self == .answering ? Theme.Spine.width + 2 : Theme.Spine.width
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
            StepSpine(colorToken: "bg-yellow-500", state: .attention)
            Text("Review, waiting for you").padding(.leading, Theme.Spine.textInset)
        }
        HStack(spacing: 0) {
            StepSpine(colorToken: "bg-blue-500", state: .answering)
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
