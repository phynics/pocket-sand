import Foundation

/// What a session's transcript needs from a server.
public protocol KandevTranscriptSource: Sendable {
    func task(id: String) async throws -> KandevTask
    func sessions(taskID: String) async throws -> [KandevSession]
    func messages(sessionID: String, limit: Int?, before: String?) async throws -> KandevMessagePage
}

extension KandevClient: KandevTranscriptSource {}

/// One row of a transcript.
///
/// The server's message kinds do not map one-to-one onto rows: `tool_execute`
/// and `script_execution` are not prose, and `thinking` hides its text in
/// metadata. This type is where that gets flattened, so the view only decides
/// how to draw four shapes.
public struct TranscriptRow: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A prompt the human wrote.
        case prompt
        /// Text an agent wrote, meant to be read.
        case reply
        /// A reasoning block. Collapsed by default.
        case thinking
        /// A tool call that ran a command. `text` is the command or target.
        case tool
        /// A tool call that read a file. `text` is the path.
        ///
        /// Separate from `tool` so a summary can tell reading from running: "Read 3
        /// files, ran 4 commands" is a description of the work, and a single count of
        /// "7 steps" is not.
        case read
        /// A lifecycle notice.
        case status
        /// A question an agent has asked and is blocked on.
        ///
        /// Not machine output: it is addressed to the reader and wants an answer, so it is
        /// never folded into a run's summary.
        case ask
        /// A setup or utility script.
        case script
    }

    public var id: String
    public var kind: Kind
    public var text: String
    /// The server's own status for a tool call, when it sent one.
    public var detail: String?
    /// When the server said this row happened.
    ///
    /// The wait between two rows is the part of a long task nobody can see: a turn that
    /// ran for half an hour whose messages span three minutes is a gap, and this is where
    /// that gap is read from. Nil when the server sent no date.
    public var at: Date?
    /// What the server says a shell call produced, without the output itself.
    ///
    /// The body is projected out of every message payload and fetched only when someone
    /// opens it; this is what the row can say without asking — that there is output, how
    /// much of it, and how the command ended.
    public var output: ToolOutputSummary?
    /// The question an agent is waiting on, when this row is one.
    public var ask: KandevClarification?

    public init(
        id: String,
        kind: Kind,
        text: String,
        detail: String? = nil,
        at: Date? = nil,
        output: ToolOutputSummary? = nil,
        ask: KandevClarification? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.detail = detail
        self.at = at
        self.output = output
        self.ask = ask
    }
}

/// What a shell command produced, as a message carries it.
///
/// The summary, not the body: the server projects the transcript out of every payload and
/// serves it from one route on demand, because it can run to a quarter of a megabyte and is
/// read in a minority of conversations.
public struct ToolOutputSummary: Sendable, Equatable {
    /// Absent means unknown, which is not the same as success.
    public var exitCode: Int?
    public var hasOutput: Bool
    public var stdoutBytes: Int
    public var stderrBytes: Int
    public var truncated: Bool

    public init(
        exitCode: Int? = nil,
        hasOutput: Bool = false,
        stdoutBytes: Int = 0,
        stderrBytes: Int = 0,
        truncated: Bool = false
    ) {
        self.exitCode = exitCode
        self.hasOutput = hasOutput
        self.stdoutBytes = stdoutBytes
        self.stderrBytes = stderrBytes
        self.truncated = truncated
    }

    /// The retained bytes, which is what a size says without the body.
    public var byteCount: Int { stdoutBytes + stderrBytes }

    /// Whether there is anything behind the disclosure.
    public var hasBody: Bool { hasOutput || byteCount > 0 }
}

extension ToolOutputSummary {
    /// Reads the summary a message carries, or nil when there is nothing to say: not a
    /// shell call, or one whose output the server did not report.
    init?(message: KandevMessage) {
        guard let raw = message.metadata?["normalized"]?["shell_exec"]?["output"] else {
            return nil
        }

        let summary = ToolOutputSummary(
            exitCode: raw["exit_code"]?.intValue,
            hasOutput: raw["has_output"]?.boolValue ?? false,
            stdoutBytes: raw["stdout_bytes"]?.intValue ?? 0,
            stderrBytes: raw["stderr_bytes"]?.intValue ?? 0,
            truncated: raw["truncated"]?.boolValue ?? false
        )
        guard summary.hasBody || summary.exitCode != nil || summary.truncated else { return nil }
        self = summary
    }
}

/// A line of a turn as it is drawn: a row, or a run of machine rows folded into
/// one.
///
/// A run rather than a reordering. A turn is usually question, work, answer — but
/// not always, and a condensing that moved rows around would put the answer in the
/// wrong place the first time an agent spoke between tool calls. The run replaces
/// the rows where they stand.
public enum TranscriptItem: Sendable, Identifiable, Equatable {
    case row(TranscriptRow)
    /// A run of work, standing in for all of it. A control, not a row.
    ///
    /// It carries the run it stands for, so the sheet it opens holds exactly what the
    /// control said it would. A control that says "88 steps" and opens 95 is worse
    /// than one that says nothing.
    ///
    /// It opens those steps in a sheet rather than growing the transcript in place: a
    /// run can be eighty steps, and expanding it where it stands turns one screen into
    /// a scroll through somebody's search history.
    case stepsSummary(id: String, rows: [TranscriptRow], duration: TimeInterval?)
    /// One step an agent repeated. A loop of twenty identical commands is one line
    /// and a count, not twenty lines.
    case repeated(id: String, count: Int, row: TranscriptRow)
    /// The step being written right now.
    ///
    /// The one row in the transcript that is not a one-liner. It shows about a
    /// paragraph and it follows the tail as the text grows, so the newest words are
    /// the ones on screen — which is the only reason to show it at all, since the
    /// step before it is already a line.
    case liveStep(TranscriptRow)

    public var id: String {
        switch self {
        case .row(let row): row.id
        case .stepsSummary(let id, _, _): id
        case .repeated(let id, _, _): id
        case .liveStep(let row): row.id
        }
    }

    /// The run this control stands for, if it is one.
    public var stepsSummaryRows: [TranscriptRow]? {
        guard case .stepsSummary(_, let rows, _) = self else { return nil }
        return rows
    }

    /// What the control over a run of work calls itself.
    ///
    /// The work described rather than counted, falling back to the count when there
    /// is nothing to describe. "88 steps" is a number nobody can act on; "read 12
    /// files, ran 30 commands" is a picture of what happened.
    public var stepsSummaryLabel: String? {
        guard let rows = stepsSummaryRows else { return nil }
        return TranscriptRow.workSummary(rows) ?? countLabel(rows.count)
    }

    private func countLabel(_ count: Int) -> String {
        count == 1 ? "1 step" : "\(count) steps"
    }

    /// The length of the work, shown only where the summary is the whole story.
    public var stepsSummaryDuration: TimeInterval? {
        guard case .stepsSummary(_, _, let duration) = self else { return nil }
        return duration
    }

    /// When the run this control stands for began, so a view that is still counting can
    /// count from it. The same instant the duration is measured from.
    public var stepsSummaryStart: Date? {
        stepsSummaryRows?.first?.at
    }

    /// How many times the step was repeated.
    public var repeatedLabel: String? {
        guard case .repeated(_, let count, _) = self else { return nil }
        return "×\(count)"
    }

    public var isStepsSummary: Bool {
        if case .stepsSummary = self { return true }
        return false
    }
}

/// One prompt-and-response cycle.
///
/// Turns come from the server's `turn_id`, which every message carries, so a
/// boundary is read rather than guessed from content or timing.
public struct TranscriptTurn: Sendable, Identifiable, Equatable {
    public var id: String
    public var rows: [TranscriptRow]
    public var startedAt: Date?
    /// Elapsed time across the turn's messages, when the server dated them.
    public var duration: TimeInterval?

    public init(id: String, rows: [TranscriptRow], startedAt: Date? = nil, duration: TimeInterval? = nil) {
        self.id = id
        self.rows = rows
        self.startedAt = startedAt
        self.duration = duration
    }

    /// How much recent work a run shows before the rest goes behind a count.
    ///
    /// Five, because a live turn produces a tool call every second or two and the
    /// interesting part is always the tail: what is happening now. The earlier
    /// steps are not hidden, they are one tap away.
    public static let recentMachineRowLimit = 5

    /// The rows in order, with each run of the turn's work folded as it finishes.
    ///
    /// A run is a stretch of machine rows with nothing readable between them, and a turn
    /// can hold several: the agent thinks, acts, explains itself, then acts again. Folding
    /// per turn put all of that behind one control, so a task that ran for half an hour
    /// read as a single count and one very long wait.
    ///
    /// A finished run is its summary line and nothing else, however short: the reader is past
    /// it, and the steps are one tap away. The run being written keeps its tail — the last
    /// `recentLimit` one-liners — with its summary underneath, and its newest step is drawn as
    /// `.liveStep`: a paragraph that follows the text as it grows, in addition to the tail's
    /// places rather than taking one of them. A short run being written is shown as it is,
    /// because there is nothing behind it to fold.
    ///
    /// `expanded` holds the ids of the loops the reader has opened out. An open loop shows
    /// all of its rows and keeps its line underneath as the control that closes it again.
    public func items(
        condensing: Bool,
        recentLimit: Int = TranscriptTurn.recentMachineRowLimit,
        generating: Bool = false,
        expanded: Set<String> = []
    ) -> [TranscriptItem] {
        let live = generating && !condensing && rows.last?.isMachineOutput == true
        let segments = workSegments()
        let liveRunIndex = live ? segments.lastIndex(where: { $0.isRun }) : nil

        var items: [TranscriptItem] = []
        for (index, segment) in segments.enumerated() {
            switch segment {
            case .prose(let row):
                items.append(.row(row))

            case .run(let run):
                let isLive = index == liveRunIndex
                let isOpen = expanded.contains("steps:\(run[0].id)")

                if isLive {
                    // A run being written keeps its tail — plus one place for the step
                    // arriving — unless the reader has opened it out. Either way its line
                    // stays underneath, as the control that closes it again.
                    if isOpen || run.count > recentLimit {
                        let shown = isOpen ? run : Array(run.suffix(recentLimit + 1))
                        items.append(contentsOf: shown.collapsedRepeats())
                        items.append(summary(for: run, live: true))
                    } else {
                        items.append(contentsOf: run.collapsedRepeats())
                    }
                } else {
                    // A finished loop is its line, however short: the reader is past it, and
                    // the steps are one tap away.
                    if isOpen {
                        items.append(contentsOf: run.collapsedRepeats())
                    }
                    items.append(summary(for: run, live: false))
                }            }
        }
        return live ? items.markingLiveStep() : items
    }

    /// The line under a run of work.
    ///
    /// Underneath, because it is a conclusion about steps that have happened rather than
    /// a claim about ones that have not, and its id is the run's first row so the line
    /// stands still while its numbers roll.
    ///
    /// A run being written carries no duration. Its length is still growing, and a value fixed
    /// here would be stale by the next frame; the view counts from `stepsSummaryStart` instead.
    private func summary(for run: [TranscriptRow], live: Bool) -> TranscriptItem {
        .stepsSummary(
            id: "steps:\(run[0].id)",
            rows: run,
            duration: live ? nil : runDuration(run)
        )
    }

    /// The turn's rows as the runs it is made of, with the prose between them left where
    /// it stands.
    private func workSegments() -> [WorkSegment] {
        var segments: [WorkSegment] = []
        var run: [TranscriptRow] = []
        for row in rows {
            if row.isMachineOutput {
                run.append(row)
            } else {
                if !run.isEmpty {
                    segments.append(.run(run))
                    run = []
                }
                segments.append(.prose(row))
            }
        }
        if !run.isEmpty { segments.append(.run(run)) }
        return segments
    }

    /// One thing a turn's rows are made of: work, or the words between it.
    private enum WorkSegment {
        case prose(TranscriptRow)
        case run([TranscriptRow])

        var isRun: Bool {
            if case .run = self { return true }
            return false
        }
    }

    /// How long a finished run took.
    ///
    /// From the run's own messages: the span between its first and its last includes the
    /// time the tools it called spent working, which is the part of a long task nobody
    /// can see.
    private func runDuration(_ run: [TranscriptRow]) -> TimeInterval? {
        guard let start = run.first?.at else { return nil }
        guard let end = run.last?.at, end > start else { return nil }
        return end.timeIntervalSince(start)
    }

    /// The rows of the run being written, if the agent is writing one.
    public var liveRunRows: [TranscriptRow]? {
        guard rows.last?.isMachineOutput == true else { return nil }
        var start = rows.count - 1
        while start > 0, rows[start - 1].isMachineOutput { start -= 1 }
        return Array(rows[start...])
    }

    /// The summary line the run being written carries, so the tense lands on the right
    /// one: a turn can hold several summaries, and only the last is still going.
    public func liveSummaryID(
        generating: Bool = true,
        recentLimit: Int = TranscriptTurn.recentMachineRowLimit
    ) -> String? {
        guard generating, let run = liveRunRows, run.count > recentLimit else { return nil }
        return "steps:\(run[0].id)"
    }

    /// The rows a run keeps on screen while the rest of it is folded into the summary.
    ///
    /// Empty when the work fits, or when no run is being written: there is no tail because
    /// there is nothing behind it. This is the one definition of what that block holds —
    /// `items` draws it, and the view fades its top edge — so the two cannot drift apart.
    public func tailItems(
        generating: Bool = false,
        recentLimit: Int = TranscriptTurn.recentMachineRowLimit
    ) -> [TranscriptItem] {
        guard generating, let run = liveRunRows, run.count > recentLimit else { return [] }
        return run.suffix(recentLimit + 1).collapsedRepeats()
    }

    /// Whether there is any machine output at all.
    public var hasMachineOutput: Bool {
        rows.contains(where: \.isMachineOutput)
    }

    /// The message that asked for this turn's work.
    ///
    /// What a sheet of steps needs for context: the steps mean little without the
    /// thing they were answering. The first row from a person, because a turn begins
    /// with one.
    public var promptRow: TranscriptRow? {
        rows.first { $0.kind == .prompt }
    }

    /// What the agent answered in this turn, if it has answered.
    public var replyRow: TranscriptRow? {
        rows.last { $0.kind == .reply }
    }

    /// Every step of the turn, in order.
    ///
    /// What a prompt opens: the person asked one question, and the answer is everything
    /// the agent did about it — not one run of it.
    public var machineRows: [TranscriptRow] {
        rows.filter(\.isMachineOutput)
    }
}

extension Array where Element == TranscriptTurn {
    /// The last thing the agent said before each turn, found in one pass.
    ///
    /// Element `i` is the reply that precedes turn `i`, nil for the first turn. One message,
    /// not a history: the sheet is about one exchange, and the agent's last words are what the
    /// person was answering when they wrote the prompt. Computing it per turn walked back through
    /// every earlier turn each time, which is quadratic in the length of the conversation.
    public func previousReplies() -> [TranscriptRow?] {
        var replies: [TranscriptRow?] = []
        var last: TranscriptRow?
        for turn in self {
            replies.append(last)
            if let reply = turn.replyRow { last = reply }
        }
        return replies
    }
}

extension Array where Element == TranscriptItem {
    /// The newest machine row, drawn as the step being written.
    ///
    /// Only a plain row: a repeat stands for several rows at once, and there is no
    /// single text to show growing.
    func markingLiveStep() -> [TranscriptItem] {
        guard let index = lastIndex(where: { item in
            guard case .row(let row) = item else { return false }
            return row.isMachineOutput
        }), case .row(let row) = self[index] else { return self }

        var marked = self
        marked[index] = .liveStep(row)
        return marked
    }
}

extension Array where Element == TranscriptRow {
    /// Consecutive identical steps, folded into one line each, with the rows behind them.
    ///
    /// Only consecutive, and only identical: two runs of the same command either side
    /// of a different step are two events, and folding them would misreport how the
    /// agent worked. The rows are kept because a line that cannot say when its last
    /// occurrence happened cannot say how long the loop took.
    public func drawnSteps() -> [TranscriptDrawnStep] {
        var steps: [TranscriptDrawnStep] = []
        var index = 0

        while index < count {
            let first = self[index]
            var end = index + 1
            while end < count, self[end].repeats(first) { end += 1 }

            let rows = Array(self[index..<end])
            let item: TranscriptItem = rows.count > 1
                ? .repeated(id: "repeat:\(first.id)", count: rows.count, row: first)
                : .row(first)
            steps.append(TranscriptDrawnStep(item: item, rows: rows))
            index = end
        }
        return steps
    }

    /// Consecutive identical steps, folded into one with a count.
    public func collapsedRepeats() -> [TranscriptItem] {
        drawnSteps().map(\.item)
    }
}

/// One line the sheet draws: a step, or a run of identical steps folded into one, and
/// the rows it stands for.
public struct TranscriptDrawnStep: Sendable, Identifiable, Equatable {
    public var item: TranscriptItem
    /// Every row this line covers, in order. A repeat covers all of them, which is what
    /// lets a reader see how long a loop took rather than only when it started.
    public var rows: [TranscriptRow]

    public var id: String { item.id }

    public init(item: TranscriptItem, rows: [TranscriptRow]) {
        self.item = item
        self.rows = rows
    }
}

extension TranscriptRow {
    /// Whether this row is machine output rather than something a person reads.
    ///
    /// The distinction drives condensing: a turn is worth collapsing when the work
    /// the agent did between the question and the answer is longer than the
    /// exchange itself, and that work is exactly the machine rows.
    public var isMachineOutput: Bool {
        switch kind {
        case .thinking, .tool, .read, .script: true
        case .prompt, .reply, .status, .ask: false
        }
    }

    /// What a run of work was, in the words a person would use.
    ///
    /// "88 steps" says how much happened and nothing about what happened, which is
    /// the one thing worth knowing about a fold. Counting by kind instead: reading and
    /// running are different work, and a thought is not work you can see at all.
    ///
    /// Reads, then commands. The visible actions, in the order they are worth knowing.
    ///
    /// Thoughts are named only when there is nothing else to name. A run of forty tool
    /// calls and forty thoughts is described by its tool calls, and the thoughts are on
    /// screen in the run's own tail either way; adding "and thought ×40" made the line
    /// long enough that it was cut off mid-phrase, which reads as a bug rather than as
    /// brevity.
    public static func workSummary(_ rows: [TranscriptRow]) -> String? {
        let reads = rows.filter { $0.kind == .read }.count
        let commands = rows.filter { $0.kind == .tool || $0.kind == .script }.count
        let thoughts = rows.filter { $0.kind == .thinking }.count

        var parts: [String] = []
        if reads > 0 { parts.append("Read \(reads) \(reads == 1 ? "file" : "files")") }
        if commands > 0 { parts.append("Ran \(commands) \(commands == 1 ? "command" : "commands")") }
        if parts.isEmpty, thoughts > 0 {
            parts.append(thoughts == 1 ? "Thought" : "Thought ×\(thoughts)")
        }
        return sentence(parts)
    }

    /// "A". "A and b". "A, b, and c".
    ///
    /// One sentence rather than a list, so only the first part keeps its capital: the
    /// rest are continuing it.
    private static func sentence(_ parts: [String]) -> String? {
        let continued = parts.enumerated().map { index, part -> String in
            guard index > 0, let first = part.first else { return part }
            return first.lowercased() + part.dropFirst()
        }

        switch continued.count {
        case 0: return nil
        case 1: return continued[0]
        case 2: return "\(continued[0]) and \(continued[1])"
        default:
            let head = continued.dropLast().joined(separator: ", ")
            return "\(head), and \(continued[continued.count - 1])"
        }
    }

    /// About a paragraph, which is how much of a long row is worth showing unasked.
    ///
    /// Roughly six lines of prose at body size on a phone's measure. Long enough to
    /// carry an argument, short enough that eighty of them do not become the
    /// transcript.
    public static let paragraphCharacters = 320

    /// The opening of a long row, cut at about a paragraph.
    ///
    /// For a finished thought: the first line or two usually says what the thought was
    /// about, and the rest is working.
    public func openingParagraph(limit: Int = TranscriptRow.paragraphCharacters) -> String {
        paragraph(fromEnd: false, limit: limit)
    }

    /// The end of a long row, cut at about a paragraph.
    ///
    /// For a step that is still being written: the newest words are the ones worth
    /// showing, and showing the opening instead would freeze the one part of the
    /// screen that is moving.
    ///
    /// The limit is a parameter because the same thought has two sizes: a line or two
    /// in the conversation, where it is a log, and a paragraph in the sheet, where it is
    /// what you opened the sheet to read.
    public func closingParagraph(limit: Int = TranscriptRow.paragraphCharacters) -> String {
        paragraph(fromEnd: true, limit: limit)
    }

    /// Whether any of this is being held back.
    public var isLongerThanAParagraph: Bool {
        text.count > TranscriptRow.paragraphCharacters
    }

    private func paragraph(fromEnd: Bool, limit: Int) -> String {
        guard text.count > limit else { return text }

        if fromEnd {
            let tail = String(text.suffix(limit))
            // Start at a word rather than inside one. A tail with no space in it at
            // all is long enough to be its own word, and cutting it is the honest
            // thing to do with it.
            let fromWord = tail.drop { !$0.isWhitespace && !$0.isNewline }
            let body = fromWord.isEmpty ? tail : String(fromWord)
            return "…" + body.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let head = String(text.prefix(limit))
        guard let cut = head.lastIndex(where: { $0.isWhitespace || $0.isNewline }) else {
            return head + "…"
        }
        return head[..<cut].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// The first line with something on it.
    ///
    /// A collapsed row should still tell you what it is. "Thinking, collapsed"
    /// says nothing; the first line of the thought usually says everything.
    public var firstLine: String {
        text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// Whether another row is this one repeated.
    ///
    /// Same kind and same text. An agent looping on one command produces the same
    /// row twenty times, and twenty identical lines say nothing that one line and a
    /// count does not.
    public func repeats(_ other: TranscriptRow) -> Bool {
        kind == other.kind && text == other.text
    }

    /// Whether showing all of this would swamp the transcript.
    ///
    /// A command of three hundred characters is one line and five wrapped lines,
    /// so length is about how much room it takes, not about newlines.
    public var isLong: Bool {
        !isSingleShortLine
    }

    private var isSingleShortLine: Bool {
        guard !text.contains("\n") else { return false }
        return text.count <= TranscriptRow.collapseThreshold
    }

    /// Where a single line stops being worth showing in full.
    public static let collapseThreshold = 72

    /// A tool's status, when it is worth the line it takes.
    ///
    /// The guard this replaced was written against "completed" and the server sends
    /// "complete", so every successful call carried a line saying nothing. The
    /// ordinary outcomes are listed rather than the failures, because a status this
    /// client has never seen is more likely to be worth showing than not.
    public static func notableStatus(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let ordinary = ["complete", "completed", "success", "ok", "succeeded"]
        return ordinary.contains(raw.lowercased()) ? nil : raw
    }

    /// A short form for a collapsed row.
    ///
    /// Always ends in an ellipsis when there is more to see — a cut line, or more
    /// lines below it. That ellipsis is what tells you a row can be opened, so the
    /// row does not also need a chevron: a screen of tool calls carried seven of
    /// them, all saying the same thing six times over.
    public func preview(limit: Int = TranscriptRow.collapseThreshold) -> String {
        let line = firstLine
        guard line.count > limit else {
            return isLong && text.contains("\n") ? line + "…" : line
        }
        return String(line.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Returns `nil` for a message that carries nothing worth drawing.
    ///
    /// Dropping is deliberate but narrow: only messages with no displayable text
    /// are dropped, because a transcript that hides rows lies about what the
    /// agent did.
    init?(message: KandevMessage) {
        guard let text = message.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }

        let kind = message.transcriptKind

        // A tool says what it did, not what it was called: `tool_read` carries the
        // word "read", and the file it read is the interesting part.
        let label = kind == .tool || kind == .read ? (message.transcriptLabel ?? text) : text

        self.init(
            id: message.id,
            kind: kind,
            text: label,
            detail: Self.notableStatus(message.metadata?["status"]?.stringValue),
            at: message.createdAt?.date,
            output: ToolOutputSummary(message: message),
            ask: KandevClarification(message: message)
        )
    }
}

/// What a message is, as a row.
///
/// The wire type records what the server sent. This is where the app decides what a
/// person reads: which row a message becomes, and what that row says. Keeping the
/// decision here means a new server kind is handled in one place, beside the rows it
/// has to sit among.
private extension KandevMessage {
    /// The row this message becomes.
    ///
    /// Authorship wins over the server's type for a human message. Then the tool
    /// family, which is open: any `tool_*` is a tool, including one this client has
    /// never seen, and `tool_read` is the one kind worth telling apart, because
    /// reading and running are different work.
    var transcriptKind: TranscriptRow.Kind {
        if isFromUser { return .prompt }
        guard isToolCall else {
            switch kind {
            case .message: return .reply
            case .thinking: return .thinking
            case .scriptExecution: return .script
            case .status: return .status
            case .clarificationRequest: return .ask
            // A permission prompt is still a prompt, but its options are shaped differently
            // and the app cannot answer it yet. Left as machine output so it is not lost.
            case .permissionRequest: return .tool
            // An unrecognised kind is drawn as machine output, not as prose. Prose
            // is a claim that a person should read this, and that is not a claim to
            // make about a kind nobody has seen yet; machine output stays visible
            // without making it.
            default: return .tool
            }
        }
        return kind == .toolRead ? .read : .tool
    }

    /// Whether this is a tool call, of any tool.
    ///
    /// The server names them by family — `tool_execute`, `tool_read` — so the
    /// prefix is the reliable signal, and a tool this client has never seen is still
    /// a tool.
    var isToolCall: Bool { type?.hasPrefix("tool_") == true }

    /// What a tool call was doing, as well as the message says.
    ///
    /// A read carries only the word "read" in its content, which tells you nothing;
    /// the file it read is in the normalised payload. Everything else keeps its
    /// content, which for a command is the command — on a live server the `title` of
    /// a shell call repeats the same string, so preferring it would be preference
    /// without a difference.
    var transcriptLabel: String? {
        if let path = metadata?["normalized"]?["read_file"]?["file_path"]?.stringValue,
           !path.isEmpty
        {
            return path
        }
        if let content, !content.isEmpty { return content }
        if let title = metadata?["title"]?.stringValue, !title.isEmpty { return title }
        return nil
    }

    /// Text worth showing as a transcript row.
    ///
    /// `tool_execute` carries its command in `content`, and `thinking` carries its
    /// text in metadata, so neither is plain prose.
    var transcriptText: String? {
        switch kind {
        case .message, .status, .toolExecute:
            content
        case .toolRead:
            transcriptLabel
        case .clarificationRequest, .permissionRequest:
            content?.isEmpty == false ? content : metadata?["question"]?["prompt"]?.stringValue
        case .thinking, .scriptExecution, nil:
            content?.isEmpty == false ? content : metadata?["thinking"]?.stringValue
        }
    }
}

extension TranscriptTurn {
    /// Groups messages into turns, preserving the server's order.
    ///
    /// A message with no `turn_id` gets a turn of its own keyed by its id, so
    /// nothing is silently merged into an unrelated turn.
    static func grouping(_ messages: [KandevMessage]) -> [TranscriptTurn] {
        var order: [String] = []
        var grouped: [String: [KandevMessage]] = [:]

        for message in messages {
            let key = message.turnID ?? "message:\(message.id)"
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = []
            }
            grouped[key]?.append(message)
        }

        return order.compactMap { key -> TranscriptTurn? in
            let messages = grouped[key] ?? []
            let rows = messages.compactMap(TranscriptRow.init(message:))
            guard !rows.isEmpty else { return nil }

            let dates = messages.compactMap { $0.createdAt?.date }
            let duration: TimeInterval? = {
                guard let first = dates.min(), let last = dates.max(), last > first else { return nil }
                return last.timeIntervalSince(first)
            }()
            return TranscriptTurn(
                id: key,
                rows: rows,
                startedAt: dates.min(),
                duration: duration
            )
        }
    }
}
