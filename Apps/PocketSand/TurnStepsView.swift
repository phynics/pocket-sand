import KandevKit
import SwiftUI

/// One exchange, with room to read it.
///
/// The transcript shows the tail of a run and summarises the rest, because a panel
/// whose length is somebody's search history is a panel you scroll out of rather than
/// read. This is where the whole of it lives: what the agent said before, what the
/// person asked, the work, and what the agent said after.
///
/// Tapping a step opens it. That is the one interaction the transcript no longer has —
/// there, a step is a line in a log — so this is where a row is a control, and it is
/// the only place that needs the rule.
struct TurnStepsView: View {
    let content: TurnSheetContent
    /// The conversation's name, which is the task's title.
    ///
    /// A count of steps is a poor name for this: it says how long the work was, which is
    /// the one thing the person did not open this to find out.
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var expandedRows: Set<String>

    init(content: TurnSheetContent, title: String) {
        self.content = content
        self.title = title
        // The row that was tapped opens with the sheet. Anything else means tapping the
        // twentieth step of fifty and landing on step one.
        let focused = content.focus.flatMap { id in
            content.steps.first { $0.id == id }?.id
        }
        _expandedRows = State(initialValue: focused.map { [$0] } ?? [])
    }

    /// Where the sheet rests. `.presentationDetents` takes a `Set`, so which detent
    /// the sheet opens at is not the order of the set — it is this. Written as a
    /// comma-separated literal, "large, then medium" reads like it means something and
    /// does not.
    @State private var detent: PresentationDetent = .large

    /// Four lines of brief is enough to say what the work was for. The whole message
    /// is one tap away, and on the screen behind this sheet.
    private static let promptPreviewLines = 4

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.base) {
                        let steps = content.steps.drawnSteps()

                        // The message that asked for the work, for context: steps on their
                        // own say what happened and not what it was for.
                        // The rules are the exchange's joints: what was said before the
                        // question, and what was said after the work. Without them the four
                        // parts read as one run-on page.
                        if let previous = content.previousReply {
                            TranscriptRowView(row: previous, isExpanded: false, stepDetail: .paragraph)
                                .id(previous.id)
                            Rule()
                        }

                        if let prompt = content.prompt {
                            TranscriptRowView(
                                row: prompt,
                                isExpanded: expandedRows.contains(prompt.id),
                                onToggle: { toggle(prompt.id) },
                                prosePreviewLines: Self.promptPreviewLines
                            )
                            .id(prompt.id)
                        }

                        workSummary

                        // Every step, one line each, repeats folded. Nothing is summarised
                        // away here, because this *is* the summary. A long wait between two
                        // of them is drawn, so the time a task spent inside one tool call is
                        // on the page rather than hidden in a gap nobody can see.
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                            if let gap = wait(before: index, in: steps) {
                                WaitingLine(seconds: gap)
                            }
                            stepView(step.item)
                        }

                        if let reply = content.reply {
                            if let gap = waitBeforeReply {
                                WaitingLine(seconds: gap)
                            }
                            Rule()
                            TranscriptRowView(row: reply, isExpanded: false)
                                .id(reply.id)
                        }
                    }
                    .padding(Theme.Space.loose)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .paperBackground()
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .font(Theme.Face.chrome(.callout, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                }
            // After layout, not during it: scrolling to a row that has not been placed
            // yet does nothing at all.
            .task {
                guard let focus = content.focus else { return }
                try? await Task.sleep(for: .milliseconds(50))
                proxy.scrollTo(focus, anchor: .center)
            }
            }
        }
        // On the sheet's root, not on the scroll view inside it. They appeared to work
        // a level down, which is the kind of almost-working that only shows up on the
        // platform nobody ran.
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }



    private func toggle(_ id: String) {
        if expandedRows.contains(id) {
            expandedRows.remove(id)
        } else {
            expandedRows.insert(id)
        }
    }

    // MARK: - The work

    /// One line of work, drawn by what it is.
    @ViewBuilder private func stepView(_ item: TranscriptItem) -> some View {
        switch item {
        case .row(let row):
            TranscriptRowView(
                row: row,
                isExpanded: expandedRows.contains(row.id),
                onToggle: { toggle(row.id) },
                stepDetail: .paragraph
            )
        case .repeated(let id, let count, let row):
            RepeatedStepsView(count: count, row: row)
                .id(id)
        case .liveStep(let row):
            // Not a state the sheet has: a step is only "live" in the transcript. Drawn as
            // the row it is, because dropping a step would make the list a lie about what
            // happened.
            TranscriptRowView(
                row: row,
                isExpanded: expandedRows.contains(row.id),
                onToggle: { toggle(row.id) },
                stepDetail: .paragraph
            )
        case .stepsSummary:
            EmptyView()
        }
    }

    /// What the work added up to, and how long the whole of it took.
    ///
    /// The transcript's folded line says this about one run; this says it about the
    /// exchange the sheet is, which is what someone opening it came for.
    @ViewBuilder private var workSummary: some View {
        if let label = TranscriptRow.workSummary(content.steps) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.snug) {
                Text(label)
                    .font(Theme.Face.chrome(.footnote, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let span = workSpan {
                    Text(CompactDuration.label(seconds: span))
                        .font(Theme.Face.machine(.caption2))
                        .foregroundStyle(Theme.muted)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The span of the work's own messages: the time the exchange spent on it.
    private var workSpan: TimeInterval? {
        guard let first = content.steps.first?.at,
              let last = content.steps.last?.at,
              last > first
        else { return nil }
        return last.timeIntervalSince(first)
    }

    /// The pause before the line at `index`, when it was long enough to be worth saying.
    private func wait(before index: Int, in steps: [TranscriptDrawnStep]) -> TimeInterval? {
        let previousAt = index > 0 ? steps[index - 1].rows.last?.at : content.prompt?.at
        guard let from = previousAt, let to = steps[index].rows.first?.at else { return nil }
        return Self.noticeableWait(from: from, to: to)
    }

    /// The pause between the last step and the answer.
    private var waitBeforeReply: TimeInterval? {
        guard let from = content.steps.last?.at, let to = content.reply?.at else { return nil }
        return Self.noticeableWait(from: from, to: to)
    }

    /// A gap worth drawing, or nil.
    ///
    /// One minute. Below that a pause reads as the work continuing; above it, it is the
    /// thing a long task is made of and the reason a two-line exchange can have taken
    /// half an hour.
    private static func noticeableWait(from: Date, to: Date) -> TimeInterval? {
        let gap = to.timeIntervalSince(from)
        return gap >= 60 ? gap : nil
    }
}

/// A long pause between two steps, drawn so the time that went past is on the page.
private struct WaitingLine: View {
    let seconds: TimeInterval

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            Rule()
            Text("Waited \(CompactDuration.label(seconds: seconds))")
                .font(Theme.Face.machine(.caption2))
                .foregroundStyle(Theme.muted)
                .monospacedDigit()
                .fixedSize()
            Rule()
        }
        .accessibilityLabel("Waited \(CompactDuration.spoken(seconds: seconds))")
    }
}

/// What the sheet is opened with: one exchange, and what was said around it.
///
/// The work is the middle of it. What the agent said before is what the prompt was
/// answering, and what it said after is what the work was for — without one end or the
/// other, a list of steps is a list of tool calls with no reason attached.
struct TurnSheetContent: Identifiable, Equatable {
    let id: String
    let previousReply: TranscriptRow?
    let prompt: TranscriptRow?
    let steps: [TranscriptRow]
    let reply: TranscriptRow?
    /// The row that was tapped to open this, if a row was.
    let focus: String?
}

#Preview("Steps sheet") {
    TurnStepsView(
        content: TurnSheetContent(
            id: "steps:1",
            previousReply: TranscriptRow(id: "prev", kind: .reply, text: "Both images build and the host check passes."),
            prompt: TranscriptRow(
                id: "p",
                kind: .prompt,
                text: "Where is ObjectLifecycleController defined?"
            ),
            steps: [
                TranscriptRow(id: "1", kind: .thinking, text: "The workspace is a checkout of Gnostic."),
                TranscriptRow(id: "2", kind: .tool, text: "grep -rn \"class ObjectLifecycleController\" v0.7.0"),
                TranscriptRow(id: "3", kind: .read, text: "Sources/GnosticCore/Container/ObjectLifecycle.swift"),
            ],
            reply: TranscriptRow(id: "last", kind: .reply, text: "It is in Components/Container/ObjectLifecycle.swift."),
            focus: "s1"
        ),
        title: "Implement the changes described in the issue"
    )
}
