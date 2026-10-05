import KandevKit
import SwiftUI

// MARK: - Rows

/// A row's kind, as a glyph.
///
/// The one thing a folded row could not say was what it *was* — a chevron says
/// "there is more here" and nothing else. The glyph says which voice it is, at a
/// glance, before you read a word of it: a thought, a command, a script. The
/// disclosure chevron moves to the trailing edge, so the left of the row is what
/// it is and the right is that it opens.
enum RowGlyph {
    static func symbol(for kind: TranscriptRow.Kind) -> String {
        switch kind {
        case .thinking: "brain"
        case .read: "doc.text.magnifyingglass"
        case .tool: "wrench.and.screwdriver"
        case .script: "terminal"
        case .prompt: "person"
        case .reply: "text.alignleft"
        case .status: "info.circle"
        }
    }

    /// Later work folds into a block; older work of a run folds into a count.
    /// A run of work, which opens a list rather than containing one.
    static let steps = "list.bullet.indent"
    static let repeated = "repeat"
}

/// A leading glyph and a label: the frame every folded line shares.
///
/// The chevron is optional, and most rows do not have one. It marks a *group* —
/// a finished turn's work, or the steps a run is not showing — where opening it
/// reveals structure. A row cut short is a different thing: it says so with an
/// ellipsis at the end of its own line, and seven chevrons down a screen of tool
/// calls were saying the same thing seven times.
private struct FoldedRowFrame<Label: View>: View {
    var symbol: String
    var tint: Color
    var isExpanded: Bool = false
    var showsDisclosure = false
    @ViewBuilder let label: () -> Label

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.snug) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                // Ink when open, muted when closed: some sign that a tap did
                // something, without a second glyph to do it.
                .foregroundStyle(isExpanded ? Theme.ink : tint)
                .frame(width: 14, alignment: .leading)
            label()
            Spacer(minLength: Theme.Space.snug)
            if showsDisclosure {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - A turn

/// One turn: what a person asked, and everything the agent did about it.
///
/// A finished turn folds its work away. The only turn whose work is on show is the
/// newest one, and even there only its last few steps are until asked for more.
///
/// Turns are separated by a rule rather than a label. The rule is a real boundary,
/// and a heading saying "Turn 4" would be a typographic device doing a rule's job.
struct TranscriptTurnView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let turn: TranscriptTurn
    let isCondensed: Bool
    /// Whether the agent is still writing this turn, which decides whether its newest
    /// step is drawn as a paragraph.
    var isWorking = false
    /// What the agent said last, before this turn. The sheet's context.
    var previousReply: TranscriptRow?
    @Binding var expandedRows: Set<String>
    /// Opens one run's steps somewhere with room to read them.
    let onShowSteps: (TurnSheetContent) -> Void

    var body: some View {
        // A running turn is timed as it goes, so its clock has to tick. Only a working
        // turn gets a timer: a finished one has nothing left to count, and one timer per
        // turn would be one per row of the transcript.
        if isWorking {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(now: context.date)
            }
        } else {
            content(now: Date())
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let items = turn.items(condensing: isCondensed, generating: isWorking, now: now)

        VStack(alignment: .leading, spacing: Theme.Space.base) {
            ForEach(itemGroups(items)) { group in
                switch group {
                case .single(let item):
                    itemView(item)
                        // A step leaving the tail slides down and out, and the one arriving
                        // slides up into place: that movement is the scroll, and it is what
                        // says the work is progressing rather than redrawing. The summary's
                        // own id never changes, so it stays put while its numbers roll.
                        .transition(.move(edge: .bottom).combined(with: .opacity))

                case .tail(let tail):
                    tailBlock(tail)
                }
            }

            // The turn's own length, on its boundary — but only when no run carries one.
            // A summary already says how long its run took, and a second number under it
            // was two clocks for one task: "running for 26 minutes" over "3m 26s".
            if !items.contains(where: \.isStepsSummary), let duration = turnLength(now: now) {
                HStack(spacing: Theme.Space.snug) {
                    Rule()
                    Text(CompactDuration.label(seconds: duration))
                        .font(Theme.Face.machine(.caption2))
                        .foregroundStyle(Theme.muted)
                        .monospacedDigit()
                }
                .padding(.top, Theme.Space.hair)
            }
        }
        // A step finishing pushes the tail up and lands in the summary line below it.
        // Animating the *set* of rows is what makes that read as one movement rather
        // than as two unrelated redraws.
        .animation(Motion.fold(reduceMotion: reduceMotion), value: items.map(\.id))
    }

    /// One item, drawn by what it is.
    @ViewBuilder private func itemView(_ item: TranscriptItem) -> some View {
        switch item {
        case .row(let row) where row.kind != .status:
            // Every row is a way into the exchange. A line grows into the sheet
            // rather than into the paragraph it was standing in for: tapping the
            // work to read the work is the whole gesture, and it cannot undo the
            // fold the way an in-place expansion did.
            Button {
                onShowSteps(exchange(id: item.id, steps: turn.machineRows, focus: item.id))
            } label: {
                TranscriptRowView(row: row, isExpanded: false)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens this exchange")

        case .row(let row):
            // A lifecycle notice is a fact about the session, not a thing to open.
            TranscriptRowView(row: row, isExpanded: false)

        case .liveStep(let row):
            Button {
                onShowSteps(exchange(id: item.id, steps: turn.machineRows, focus: item.id))
            } label: {
                LiveStepView(row: row)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens this exchange")

        case .stepsSummary:
            // Only the run still going says "running for"; the ones before it are done.
            StepsSummaryView(
                item: item,
                isRunning: item.id == turn.liveSummaryID(generating: isWorking)
            ) {
                // The whole exchange, not the one run: the sheet is where the work before
                // and after this loop lives, and a control onto one run would make a third
                // place to read the same steps.
                onShowSteps(exchange(id: item.id, steps: turn.machineRows, focus: nil))
            }

        case .repeated(let id, let count, let row):
            Button {
                onShowSteps(exchange(id: id, steps: turn.machineRows, focus: id))
            } label: {
                RepeatedStepsView(count: count, row: row)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens this exchange")
            .id(id)
        }
    }

    /// The items, with a run's tail grouped so a fade can sit on its top edge.
    ///
    /// Grouped whenever the tail exists, not only while the run is working: the container
    /// has to keep its identity when the turn ends, or the rows would be rebuilt and
    /// flash at the moment the work stops. What changes with the run is the mask.
    private func itemGroups(_ items: [TranscriptItem]) -> [ItemGroup] {
        let tailIDs = Set(turn.tailItems(generating: isWorking).map(\.id))
        let tailIndices = items.indices.filter { tailIDs.contains(items[$0].id) }

        guard let first = tailIndices.first, let last = tailIndices.last else {
            return items.map(ItemGroup.single)
        }

        var groups = items[..<first].map(ItemGroup.single)
        groups.append(.tail(Array(items[first...last])))
        groups.append(contentsOf: items[(last + 1)...].map(ItemGroup.single))
        return groups
    }

    /// The run's tail, its top edge fading while the run is still adding rows.
    @ViewBuilder private func tailBlock(_ tail: [TranscriptItem]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            ForEach(tail) { item in
                itemView(item)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Always masked, so only the gradient's stops change when the run ends and the
        // block is not rebuilt. The top edge fades while the run is adding rows: those
        // are the ones being pushed out by the ones arriving below, and the fade says a
        // call is hidden behind the fold rather than gone.
        .mask(
            LinearGradient(
                stops: isWorking
                    ? [.init(color: .clear, location: 0), .init(color: .black, location: 0.15)]
                    : [.init(color: .black, location: 0)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// The items of a turn, or the run's tail as one block.
    private enum ItemGroup: Identifiable {
        case single(TranscriptItem)
        case tail([TranscriptItem])

        var id: String {
            switch self {
            case .single(let item): item.id
            // Constant, not built from the rows: the tail keeps its identity as steps
            // arrive, so the rows inside it diff and slide rather than being rebuilt.
            case .tail: "tail"
            }
        }
    }

    /// How long the turn has been going, or took.
    ///
    /// To now while it is being written, because the server has not dated an end that has
    /// not come; the server's own count once it has finished.
    private func turnLength(now: Date) -> TimeInterval? {
        if isWorking, let startedAt = turn.startedAt {
            return max(0, now.timeIntervalSince(startedAt))
        }
        return turn.duration
    }

    /// One exchange, as the sheet wants it: what was said before, what was asked, the
    /// work, and what was said after.
    ///
    /// `focus` is the row that was tapped, so the sheet opens on it rather than at the
    /// top: tapping the twentieth step of fifty and landing on step one is a tap that
    /// did nothing useful.
    private func exchange(id: String, steps: [TranscriptRow], focus: String?) -> TurnSheetContent {
        TurnSheetContent(
            id: id,
            previousReply: previousReply,
            prompt: turn.promptRow,
            steps: steps,
            reply: turn.replyRow,
            focus: focus
        )
    }

    private func toggle(_ id: String) {
        withAnimation(Motion.fold(reduceMotion: reduceMotion)) {
            if expandedRows.contains(id) {
                expandedRows.remove(id)
            } else {
                expandedRows.insert(id)
            }
        }
    }

}

/// The step being written, in about a paragraph.
///
/// The one place in the transcript where a step's own text is on screen. A run's tail
/// says what the agent is doing; this says what it is saying, and it shows the *end* of
/// the text rather than the start, so the newest words are the ones you are reading.
/// Anything longer is a wall of reasoning that moves every time a token lands.
struct LiveStepView: View {
    let row: TranscriptRow

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.snug) {
            Image(systemName: RowGlyph.symbol(for: row.kind))
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .frame(width: 14, alignment: .leading)

            Text(text)
                .font(font)
                .italic(row.kind == .thinking)
                .foregroundStyle(row.kind == .thinking ? Theme.muted : Theme.ink)
                .lineSpacing(Theme.proseLineSpacing)
                // A thought is bounded by its content, a command by its lines. The tail
                // of a long command is pipes and flags — the beginning is the part that
                // says what it is, and eight wrapped lines of the rest is a wall where
                // the paragraph should be.
                .lineLimit(row.kind == .thinking ? nil : Self.commandLines)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Working: \(text)")
    }

    private static let commandLines = 3

    /// Two or three lines in the conversation. The sheet is where a thought gets a
    /// paragraph; here it is the one line the fold left open, and a paragraph in the
    /// panel is the thing the panel exists to avoid.
    private static let thoughtCharacters = 160

    /// Thinking follows its tail, because its newest words are the point. A command
    /// opens from the top, because its argument list is not a narrative.
    private var text: String {
        row.kind == .thinking ? row.closingParagraph(limit: Self.thoughtCharacters) : row.text
    }

    /// A size below the sheet's, on purpose: the same voice at two scales. The
    /// conversation is a log you scan, and the sheet is the page you read.
    private var font: Font {
        row.kind == .thinking ? Theme.Face.prose(.footnote) : Theme.Face.machine(.footnote)
    }
}

/// A run of work, folded into one line that opens it.
///
/// Tapping opens the turn's steps in a sheet rather than growing the transcript here.
/// A run can be eighty steps; expanding it where it stands turns one screen into a
/// scroll through somebody's search history, and the transcript is meant to stay the
/// length of the conversation.
struct StepsSummaryView: View {
    let item: TranscriptItem
    /// Whether the turn is still running, which decides the tense: a line that says
    /// "ran for" about work still in progress is a lie, and one that says "running
    /// for" about finished work is a worse one.
    var isRunning = false
    let open: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: open) {
            FoldedRowFrame(
                symbol: RowGlyph.steps,
                tint: Theme.muted,
                showsDisclosure: true
            ) {
                label
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint("Opens the full conversation around this work")
    }

    /// How long it has been going, then what it has done.
    ///
    /// The time leads because it is the one fact the rows underneath cannot tell you.
    /// Spelled out rather than as "3m 35s", because this is a sentence about work in
    /// progress and a chip is not: "Running for 3 minutes and 35 seconds".
    ///
    /// One string with two runs rather than two labels, so a long summary wraps to a
    /// second line instead of being cut off mid-phrase. "Read 9 files and ran 49…" reads
    /// as a bug; the same words on their own line read as a sentence.
    private var label: some View {
        Text(attributedLabel)
            .font(Theme.Face.chrome(.footnote))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            // The numbers roll rather than jump. This is the only thing on the screen
            // that changes without anyone touching it, and a counter that ticks is how
            // a line says "still working" without a spinner.
            .contentTransition(.numericText())
            .animation(Motion.fold(reduceMotion: reduceMotion), value: attributedLabel)
    }

    private var attributedLabel: AttributedString {
        var label = AttributedString()

        if let duration = item.stepsSummaryDuration {
            var time = AttributedString("\(timeLead(in: duration)) \(CompactDuration.spoken(seconds: duration))")
            time.font = Theme.Face.chrome(.footnote, weight: .medium)
            time.foregroundColor = Theme.ink
            label += time
        }

        if let summary = item.stepsSummaryLabel {
            var words = AttributedString(item.stepsSummaryDuration == nil ? summary : "; \(summary)")
            words.foregroundColor = Theme.muted
            label += words
        }

        return label
    }

    private func timeLead(in _: TimeInterval) -> String {
        isRunning ? "Running for" : "Ran for"
    }

    private var spokenLabel: String {
        var parts: [String] = []
        if let duration = item.stepsSummaryDuration {
            parts.append("\(timeLead(in: duration)) \(CompactDuration.spoken(seconds: duration))")
        }
        if let summary = item.stepsSummaryLabel { parts.append(summary) }
        return parts.joined(separator: ", ")
    }
}

/// One step an agent repeated, standing in for all of them.
///
/// The count is the information: an agent looping on one command is doing something
/// worth noticing, and twenty copies of the line do not say that any better than
/// "×20" does. Not expandable, because the rows behind it are identical by
/// construction — there is nothing in them that the one on screen is not showing.
struct RepeatedStepsView: View {
    let count: Int
    let row: TranscriptRow

    var body: some View {
        FoldedRowFrame(
            symbol: RowGlyph.repeated,
            tint: Theme.muted
        ) {
            HStack(alignment: .top, spacing: Theme.Space.snug) {
                Text(row.preview())
                    .font(row.kind == .thinking ? Theme.Face.prose(.footnote) : Theme.Face.machine(.footnote))
                    .italic(row.kind == .thinking)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Text("×\(count)")
                    .font(Theme.Face.machine(.caption))
                    .foregroundStyle(Theme.muted)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step repeated \(count) times: \(row.preview())")
    }
}

// MARK: - One row

/// One row of a transcript, drawn by whose voice it is.
///
/// - A person's words are prose and get a band, because they are the thing being
///   answered.
/// - The agent's words are prose and get nothing at all, because they are what you
///   are here to read and anything around them competes with reading.
/// - The machine's output is a token stream and gets monospace, an inset, and a
///   hairline to mark where it begins and ends. Anything long enough to swamp the
///   transcript folds, showing its first line.
struct TranscriptRowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let row: TranscriptRow
    let isExpanded: Bool
    /// What a tap does, where the row is a control at all.
    ///
    /// Nil in the transcript, where a run's tail is a log to read rather than a set of
    /// controls: one line per step is the whole point, and a tap that grew one of them
    /// would trade that for a paragraph nobody asked for. The sheet passes a closure
    /// and gets the same row as something you can open.
    var onToggle: (() -> Void)?
    /// How much of a step to show while it is closed.
    ///
    /// A log line in the transcript, where the tail of a run is a log and every row is
    /// the same height. A paragraph in the sheet, where a thought is the thing you came
    /// to read and a single line of it is a teaser rather than a text. Short rows come
    /// out the same either way, which is what makes this a display choice and not a
    /// hiding one: a model that sends three words of reasoning shows three words.
    enum StepDetail {
        case oneLine
        case paragraph
    }

    var stepDetail: StepDetail = .oneLine

    /// How much of a long message to show before it is asked for.
    ///
    /// Nil in the transcript, where a person's words *are* the content and cutting
    /// them would be cutting the conversation. The steps sheet is the other case: the
    /// message there is context for a list of work, and a nine-line brief pushes the
    /// work it explains off the bottom of the sheet.
    var prosePreviewLines: Int?

    var body: some View {
        switch row.kind {
        case .prompt:
            prose
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.base)
                .background(Theme.surface)

        case .reply:
            prose
                .frame(maxWidth: .infinity, alignment: .leading)

        case .thinking, .tool, .read, .script:
            // One line, always, and the row is the control that opens it where there
            // is one.
            //
            // This used to depend on whether the row was "long", so a command of
            // sixty characters wrapped to two lines and broke the rhythm of the list
            // the whole fold exists to keep. Uniform beats clever here: every step is
            // one line, and a tap gives it the room it needs.
            disclosure

        case .status:
            Text(row.text)
                .font(Theme.Face.chrome(.caption))
                .foregroundStyle(Theme.muted)
        }
    }

    /// A message, in full or in the first few lines of itself.
    ///
    /// Two voices, one for each end of the exchange: a person's question is prose in a
    /// serif at reading size, and the agent's answer is sans a size down. The question
    /// is what you came to the exchange for; the answer is long, and it should not
    /// shout over it.
    private var prose: some View {
        let text = Text(row.text)
            .font(row.kind == .reply ? Theme.Face.agent() : Theme.Face.prose(.body))
            .foregroundStyle(Theme.ink)
            .lineSpacing(row.kind == .reply ? Theme.agentLineSpacing : Theme.proseLineSpacing)

        guard let lines = prosePreviewLines, !isExpanded, let onToggle else {
            return AnyView(text.textSelection(.enabled))
        }
        return AnyView(
            Button {
                withAnimation(Motion.fold(reduceMotion: reduceMotion)) { onToggle() }
            } label: {
                text
                    .lineLimit(lines)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            // A hint, not a label: the label is the message, and replacing it would
            // hide the very words this button exists to reveal.
            .accessibilityHint("Shows the whole message")
        )
    }

    /// A row showing one line of itself, until asked — where there is anyone to ask.
    private var disclosure: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            if let onToggle {
                Button {
                    withAnimation(Motion.fold(reduceMotion: reduceMotion)) { onToggle() }
                } label: {
                    foldedLine
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(kindWord), \(isExpanded ? "expanded" : "collapsed")")

                if isExpanded {
                    body(for: row)
                        .padding(.leading, Theme.Space.base)
                }
            } else {
                foldedLine
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(kindWord): \(row.preview())")
            }
        }
    }

    private var foldedLine: some View {
        FoldedRowFrame(
            symbol: RowGlyph.symbol(for: row.kind),
            tint: Theme.muted,
            isExpanded: isExpanded
        ) {
            Text(isExpanded ? kindWord : closedText)
                .font(previewFont)
                .italic(previewIsItalic && !isExpanded)
                .foregroundStyle(Theme.muted)
                .lineSpacing(Theme.proseLineSpacing)
                // Only a thought in the sheet is allowed more than one line: that is the
                // paragraph this screen exists to give it. A command is one line
                // wherever it is, because a wrapped argument list is where a list stops
                // being scannable.
                .lineLimit(closedLineLimit)
                .truncationMode(.tail)
        }
    }

    /// One line, except for the one case with something to read.
    private var closedLineLimit: Int? {
        guard !isExpanded else { return 1 }
        return stepDetail == .paragraph && row.kind == .thinking ? nil : 1
    }

    /// What a closed row says about itself.
    ///
    /// A thought opens from the top in the sheet: the first line or two says what the
    /// thought was about, and the rest of a long one is working. Commands stay one line
    /// in both places — an argument list is not a narrative, and six lines of it is a
    /// wall.
    private var closedText: String {
        guard stepDetail == .paragraph, row.kind == .thinking, row.isLongerThanAParagraph else {
            return row.preview()
        }
        return row.openingParagraph()
    }

    /// What a row is called, folded and unfolded.
    ///
    /// Unfolded it is the whole of what the header says, because the body below it
    /// carries the text: a header that repeated the body's first line made the same
    /// sentence appear twice, one of them cut off.
    private var kindWord: String {
        switch row.kind {
        case .thinking: "Thought"
        case .read: "File read"
        case .tool: "Command"
        case .script: "Script"
        default: "Row"
        }
    }

    /// The face a folded row speaks in, which is the face it speaks in when open: a
    /// thought is prose even when you are only reading its first line, and a command
    /// is a token stream even at one line. Setting both in mono made a run of
    /// alternating thoughts and commands read as one flat grey block.
    private var previewFont: Font {
        switch row.kind {
        case .thinking:
            // Smaller in the conversation than anywhere else. A thought is the quietest
            // voice in a transcript of work, and at the sheet's size a run of them reads
            // as the transcript's content rather than as its margin.
            stepDetail == .paragraph ? Theme.Face.prose(.body) : Theme.Face.prose(.caption)
        case .tool, .read, .script: Theme.Face.machine(.footnote)
        default: Theme.Face.chrome(.footnote)
        }
    }

    private var previewIsItalic: Bool { row.kind == .thinking }

    /// A row's full self, in its own voice.
    @ViewBuilder
    private func body(for row: TranscriptRow) -> some View {
        switch row.kind {
        case .thinking:
            // The full text, which only the sheet asks for: in the transcript a step is a
            // log line and there is no control here to open one.
            Text(row.text)
                .font(Theme.Face.prose(.body))
                .italic()
                .foregroundStyle(Theme.muted)
                .lineSpacing(Theme.proseLineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool, .read, .script:
            machineText(row.text)
        default:
            EmptyView()
        }
    }

    /// A machine row's body: monospace, inset behind a hairline.
    private func machineText(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.snug + 2) {
            Rectangle()
                .fill(Theme.rule)
                .frame(width: 1)
            VStack(alignment: .leading, spacing: Theme.Space.hair) {
                Text(text)
                    .font(Theme.Face.machine(.footnote))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                if let detail = row.detail, detail != "completed" {
                    Text(detail)
                        .font(Theme.Face.machine(.caption2))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("Voices") {
    ScrollView {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            TranscriptTurnView(
                turn: TranscriptTurn(
                    id: "t1",
                    rows: [
                        TranscriptRow(id: "1", kind: .prompt, text: "Where is ObjectLifecycleController defined?"),
                        TranscriptRow(id: "2", kind: .thinking, text: "The workspace is a checkout of Gnostic, so I should search it rather than guess."),
                        TranscriptRow(id: "3", kind: .tool, text: "cd /data/tasks/implement-the-change_8jnpkykin/phynics-Gnostic && grep -rn \"class ObjectLifecycleController\" v0.7.0"),
                        TranscriptRow(id: "4", kind: .reply, text: "It is in Components/Container/ObjectLifecycle.swift."),
                    ],
                    duration: 187
                ),
                isCondensed: false,
                expandedRows: .constant([]),
                onShowSteps: { _ in }
            )

            TranscriptTurnView(
                turn: TranscriptTurn(
                    id: "t0",
                    rows: [
                        TranscriptRow(id: "a", kind: .prompt, text: "What does the CI check?"),
                        TranscriptRow(id: "b", kind: .tool, text: "ls -la"),
                        TranscriptRow(id: "c", kind: .tool, text: "cat .github/workflows/ci.yml"),
                        TranscriptRow(id: "d", kind: .reply, text: "It builds both images and runs the host check."),
                    ],
                    duration: 42
                ),
                isCondensed: true,
                expandedRows: .constant([]),
                onShowSteps: { _ in }
            )
        }
        .padding(Theme.Space.loose)
    }
    .background(Theme.paper)
}
