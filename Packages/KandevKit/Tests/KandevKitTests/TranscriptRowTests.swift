import Foundation
import Testing

@testable import KandevKit

/// The transcript mapping, checked against the message shapes a live v0.96.0
/// server produced during one real agent turn.
@Suite("Transcript mapping")
struct TranscriptRowTests {
    private func message(
        id: String = "m1",
        author: String,
        type: String?,
        content: String? = nil,
        metadata: JSONValue? = nil,
        turn: String? = "turn-1",
        at: String? = nil
    ) -> KandevMessage {
        KandevMessage(
            id: id,
            authorType: author,
            type: type,
            content: content,
            turnID: turn,
            createdAt: at.map { KandevTimestamp(raw: $0) },
            metadata: metadata
        )
    }

    @Test("maps each server kind onto a row kind")
    func mapsKinds() throws {
        let cases: [(String, String, TranscriptRow.Kind)] = [
            ("user", "message", .prompt),
            ("agent", "message", .reply),
            ("agent", "thinking", .thinking),
            ("agent", "tool_execute", .tool),
            ("agent", "tool_read", .read),
            ("agent", "script_execution", .script),
            ("agent", "status", .status),
        ]

        for (author, type, expected) in cases {
            let row = try #require(
                TranscriptRow(message: message(author: author, type: type, content: "text"))
            )
            #expect(row.kind == expected, "\(author)/\(type) should map to \(expected)")
        }
    }

    /// A user message stays a prompt even if the server types it oddly.
    @Test("authorship wins over the server's type for a human message")
    func authorshipWins() throws {
        let row = try #require(
            TranscriptRow(message: message(author: "user", type: "status", content: "hello"))
        )

        #expect(row.kind == .prompt)
    }

    /// The time the server sent with a row, which is how a long wait becomes visible.
    @Test("keeps the time the server sent with a row")
    func keepsTheTime() throws {
        let row = try #require(
            TranscriptRow(
                message: message(
                    author: "agent",
                    type: "tool_execute",
                    content: "ls",
                    at: "2026-10-04T21:38:07Z"
                )
            )
        )

        #expect(row.at != nil)
    }

    /// Captured from a live server. The message carries the *summary* of a command's output
    /// and never the output itself: the server projects the body out of every payload and
    /// serves it from one route on demand.
    @Test("a shell call carries the summary of its output, not the output")
    func shellCallSummary() throws {
        let message = try JSONDecoder().decode(
            KandevMessage.self,
            from: Data(#"""
{"author_type": "agent", "content": "git status", "id": "a2cb1c4e", "metadata": {"normalized": {"kind": "shell_exec", "shell_exec": {"command": "", "output": {"exit_code": 0, "has_output": true, "stderr_bytes": 0, "stdout_bytes": 760, "truncated": false}}}, "status": "complete", "title": "git status", "tool_call_id": "call_00"}, "type": "tool_execute"}
"""#.utf8)
        )

        let row = try #require(TranscriptRow(message: message))
        let output = try #require(row.output)
        #expect(output.exitCode == 0)
        #expect(output.stdoutBytes == 760)
        #expect(output.byteCount == 760)
        #expect(output.hasBody)
        #expect(row.text == "git status")
    }

    /// A command with nothing retained carries no summary, so the row offers nothing to open.
    @Test("a shell call with no retained output carries no summary")
    func shellCallWithoutOutput() throws {
        let message = try JSONDecoder().decode(
            KandevMessage.self,
            from: Data(#"{"id":"m1","type":"tool_execute","content":"ls","metadata":{"normalized":{"shell_exec":{"output":{"stdout_bytes":0,"stderr_bytes":0}}}}}"#.utf8)
        )

        #expect(TranscriptRow(message: message)?.output == nil)
    }

    /// A question an agent is blocked on, in the shape the server sends it: one message per
    /// question, carrying the question and its options under `metadata`.
    @Test("a clarification maps to an ask row carrying its question")
    func clarificationMapsToAnAskRow() throws {
        let message = try JSONDecoder().decode(
            KandevMessage.self,
            from: Data(#"""
{"id":"m1","type":"clarification_request","author_type":"agent","content":"Which database should this use?","metadata":{"pending_id":"p1","session_id":"s1","question":{"id":"q1","title":"Database","prompt":"Which database should this use?","options":[{"option_id":"o1","label":"Postgres","description":"The one already running"},{"option_id":"o2","label":"SQLite","description":""}],"allow_custom_text":true},"question_index":1,"question_total":1,"status":"pending"}}
"""#.utf8)
        )

        let row = try #require(TranscriptRow(message: message))
        #expect(row.kind == .ask)
        #expect(row.isMachineOutput == false, "a question is addressed to the reader, not folded away")

        let ask = try #require(row.ask)
        #expect(ask.pendingID == "p1")
        #expect(ask.questionID == "q1")
        #expect(ask.options.map(\.id) == ["o1", "o2"])
        #expect(ask.options.first?.description == "The one already running")
        #expect(ask.allowsCustomText)
        #expect(ask.isOpen)
    }

    @Test("an answered clarification carries what was chosen")
    func answeredClarification() throws {
        let message = try JSONDecoder().decode(
            KandevMessage.self,
            from: Data(#"""
{"id":"m1","type":"clarification_request","author_type":"agent","content":"Which database?","metadata":{"pending_id":"p1","question":{"id":"q1","title":"Database","prompt":"Which database?","options":[{"option_id":"o1","label":"Postgres"},{"option_id":"o2","label":"SQLite"}]},"status":"answered","response":{"question_id":"q1","selected_options":["o1"]}}}
"""#.utf8)
        )

        let ask = try #require(TranscriptRow(message: message)?.ask)
        #expect(ask.answer?.selectedOptions == ["o1"])
        #expect(ask.isOpen == false)
    }

    /// Captured from a live server while an agent worked. `tool_read` was a kind
    /// this client had never seen, and treating it as unknown rendered the word
    /// "read" as a serif headline in the middle of a transcript.
    @Test("a file read is a read row that names the file")
    func fileReadIsAToolRow() throws {
        let message = try JSONDecoder().decode(
            KandevMessage.self,
            from: Data(#"""
{"author_type": "agent", "content": "read", "created_at": "2026-10-04T22:39:33.126955505Z", "id": "5c4e2c1d-4fcd-43a8-9e59-71292c510a9e", "metadata": {"normalized": {"kind": "read_file", "read_file": {"file_path": "/data/tasks/implement-the-change_8jnpykin/phynics-Gnostic/Sources/GnosticCLI/Config/BackendComposition.swift"}}, "status": "complete", "title": "read", "tool_call_id": "call_00_4icze64tj6h25iyy5z2nz91n"}, "requests_input": false, "session_id": "2c603f5c-547b-441d-9779-11ca4144b46f", "task_id": "6dc2abca-9edd-4afa-821b-694cbcd19bfe", "turn_id": "391f51b6-e74a-4b07-b97f-c7e48401c9de", "type": "tool_read", "updated_at": "2026-10-04T22:39:33.153563508Z"}
"""#.utf8)
        )

        let row = try #require(TranscriptRow(message: message))
        #expect(row.kind == .read, "a tool is never prose, and a read is not a command")
        #expect(row.text.hasSuffix("BackendComposition.swift"))
        #expect(row.isMachineOutput)
    }

    /// A read whose content is only the word "read" still names the file: the title
    /// is the fallback when there is no normalised path.
    @Test("a file read falls back to its title when it has no path")
    func fileReadFallsBackToTheTitle() throws {
        let row = try #require(
            TranscriptRow(
                message: message(
                    author: "agent",
                    type: "tool_read",
                    content: "",
                    metadata: .object(["title": .string("ran the test suite")])
                )
            )
        )

        #expect(row.kind == .read)
        #expect(row.text == "ran the test suite")
    }

    /// The rule behind that bug: an unknown kind must not claim to be prose.
    @Test("an unrecognised kind is machine output, not a headline")
    func unknownKindIsMachineOutput() throws {
        let row = try #require(
            TranscriptRow(message: message(author: "agent", type: "tool_teleport", content: "zap"))
        )

        #expect(row.kind == .tool)
        #expect(row.isMachineOutput)
    }

    @Test("drops a message with nothing to show")
    func dropsEmptyRows() {
        #expect(TranscriptRow(message: message(author: "agent", type: "status", content: "")) == nil)
        #expect(TranscriptRow(message: message(author: "agent", type: "thinking", content: "  ")) == nil)
    }

    /// This test used to assert the opposite, and the opposite was a bug: an
    /// unknown kind drawn as prose rendered `tool_read` as a serif headline saying
    /// "read". A kind nobody has seen is drawn as machine output, which keeps it
    /// visible without claiming a person should read it.
    @Test("draws an unknown kind as machine output, not as prose")
    func unknownKindIsKeptAsMachineOutput() throws {
        let row = try #require(
            TranscriptRow(message: message(author: "agent", type: "some_new_kind", content: "payload"))
        )

        #expect(row.kind == .tool)
        #expect(row.isMachineOutput)
        #expect(row.text == "payload")
    }

    /// The command is the content, not the title. On a live server the title of a
    /// shell call repeats the same string, so preferring it would be preference
    /// without a difference — and an invented title would win over the real command.
    @Test("takes a tool row's text from its content")
    func toolRowTakesTextFromContent() throws {
        let row = try #require(
            TranscriptRow(
                message: message(
                    author: "agent",
                    type: "tool_execute",
                    content: "ls -la; pwd",
                    metadata: .object(["status": .string("completed"), "title": .string("Run command")])
                )
            )
        )

        #expect(row.kind == .tool)
        #expect(row.text == "ls -la; pwd")
    }

    /// A failure is worth a line; success is not. This used to assert that a
    /// successful call showed "completed" under it, which was a line saying nothing.
    @Test("says nothing about a tool that succeeded and something about one that did not")
    func toolRowCarriesOnlyNotableStatus() throws {
        let succeeded = try #require(
            TranscriptRow(
                message: message(
                    author: "agent",
                    type: "tool_execute",
                    content: "ls",
                    metadata: .object(["status": .string("completed")])
                )
            )
        )
        #expect(succeeded.detail == nil)

        let failed = try #require(
            TranscriptRow(
                message: message(
                    author: "agent",
                    type: "tool_execute",
                    content: "ls",
                    metadata: .object(["status": .string("failed")])
                )
            )
        )
        #expect(failed.detail == "failed")
    }

    @Test("groups messages into turns by turn id, keeping the server's order")
    func groupsIntoTurns() {
        let turns = TranscriptTurn.grouping([
            message(id: "1", author: "user", type: "message", content: "first", turn: "a"),
            message(id: "2", author: "agent", type: "message", content: "reply", turn: "a"),
            message(id: "3", author: "user", type: "message", content: "second", turn: "b"),
            message(id: "4", author: "agent", type: "message", content: "again", turn: "b"),
        ])

        #expect(turns.map(\.id) == ["a", "b"])
        #expect(turns[0].rows.map(\.text) == ["first", "reply"])
        #expect(turns[1].rows.map(\.text) == ["second", "again"])
    }

    @Test("gives a message with no turn id its own turn instead of merging it")
    func ungroupedMessageGetsItsOwnTurn() {
        let turns = TranscriptTurn.grouping([
            message(id: "1", author: "agent", type: "message", content: "orphan", turn: nil),
        ])

        #expect(turns.count == 1)
        #expect(turns[0].id == "message:1")
    }

    @Test("computes a turn's duration from its dated messages")
    func computesDuration() {
        let turns = TranscriptTurn.grouping([
            message(id: "1", author: "user", type: "message", content: "go", turn: "a",
                    at: "2026-10-04T18:24:56.417151677Z"),
            message(id: "2", author: "agent", type: "message", content: "done", turn: "a",
                    at: "2026-10-04T18:25:10.973847882Z"),
        ])

        let duration = try? #require(turns.first?.duration)
        #expect(abs((duration ?? 0) - 14.5) < 1.0)
    }

    @Test("skips a turn whose messages are all undrawable")
    func skipsEmptyTurns() {
        let turns = TranscriptTurn.grouping([
            message(id: "1", author: "agent", type: "status", content: "", turn: "a"),
            message(id: "2", author: "user", type: "message", content: "real", turn: "b"),
        ])

        #expect(turns.map(\.id) == ["b"])
    }
}

@Suite("Condensing a transcript")
struct TranscriptCondensingTests {
    private func row(_ id: String, _ kind: TranscriptRow.Kind, _ text: String = "x") -> TranscriptRow {
        TranscriptRow(id: id, kind: kind, text: text)
    }

    private func turn(_ rows: [TranscriptRow]) -> TranscriptTurn {
        TranscriptTurn(id: "t1", rows: rows)
    }

    private func steps(_ count: Int, startingAt offset: Int = 0) -> [TranscriptRow] {
        (0..<count).map { row("s\(offset + $0)", .tool, "step \(offset + $0)") }
    }

    /// A run long enough to summarise becomes one control **under** the work it
    /// stands for: it is a conclusion about those steps, and a conclusion goes last.
    @Test("summarises a long run underneath it")
    func summarisesUnderneath() {
        let items = turn(
            [row("p", .prompt)] + steps(8) + [row("r", .reply)]
        ).items(condensing: true)

        #expect(items.count == 3)
        #expect(items[0].id == "p")
        #expect(items[1].isStepsSummary, "the steps it stands for come first")
        #expect(items[1].stepsSummaryLabel == "Ran 8 commands")
        #expect(items[2].id == "r", "and prose the agent wrote mid-turn keeps its place")
    }

    /// The reason the work is folded rather than reordered: an agent that speaks between
    /// tool calls would otherwise have its words moved past them.
    @Test("keeps the order when prose sits inside the work")
    func proseInsideWorkStaysPut() {
        let items = turn(
            [row("1", .prompt)]
                + steps(7, startingAt: 10)
                + [row("9", .reply)]
                + steps(7, startingAt: 20)
                + [row("99", .reply)]
        ).items(condensing: true)

        // Each run folds where it stands, so the words between two of them keep their
        // places, and the answer written after the last stays below it.
        #expect(items.map(\.id) == ["1", "steps:s10", "9", "steps:s20", "99"])
    }

    /// One control per run. Folding a turn's work together made a long task read as a
    /// single count, and put one run's length on another run's line.
    @Test("a turn with two runs gets one control per run")
    func oneControlPerRun() {
        let rows = [row("1", .prompt)] + steps(7, startingAt: 10) + [row("9", .reply)]
            + steps(7, startingAt: 20)
        let items = TranscriptTurn(id: "t1", rows: rows, duration: 187).items(condensing: true)

        let summaries = items.filter { $0.isStepsSummary }
        #expect(summaries.count == 2)
        #expect(summaries.map { $0.stepsSummaryRows?.count } == [7, 7])
    }

    /// A run is timed from its own messages: the span includes the time the tools it
    /// called spent working, which is the part of a long task nobody can see. A run being
    /// written is timed to now, because the server has not dated an end that has not come.
    @Test("a run is timed from its own messages, and to now while it runs")
    func timesARunFromItsMessages() {
        let start = Date(timeIntervalSince1970: 1_000_000)

        let finished = [timestamped("s0", start), timestamped("s1", start.addingTimeInterval(90))]
        #expect(
            TranscriptTurn(id: "t1", rows: finished).items(condensing: false).last?.stepsSummaryDuration == 90
        )

        let running = (0..<6).map { timestamped("r\($0)", start.addingTimeInterval(Double($0) * 5)) }
        let live = TranscriptTurn(id: "t1", rows: running)
            .items(condensing: false, generating: true, now: start.addingTimeInterval(215))
            .first { $0.isStepsSummary }
        #expect(live?.stepsSummaryDuration == 215)
    }

    private func timestamped(_ id: String, _ at: Date) -> TranscriptRow {
        TranscriptRow(id: id, kind: .tool, text: id, at: at)
    }

    /// A turn with no work in it is left as it is: there is nothing to fold.
    @Test("a turn with no work is left as it is")
    func noWorkIsLeftAlone() {
        let items = turn([row("1", .prompt), row("3", .reply)]).items(condensing: true)

        #expect(items.map(\.id) == ["1", "3"])
        #expect(items.contains(where: \.isStepsSummary) == false)
    }

    /// A finished turn's work folds even when it is one step: the reader is past it, and the
    /// step is one tap away.
    @Test("a finished turn's single step folds to its line")
    func singleStepFolds() {
        let items = turn([row("1", .prompt), row("2", .thinking), row("3", .reply)])
            .items(condensing: true)

        #expect(items.map(\.id) == ["1", "steps:2", "3"])
        #expect(items[1].isStepsSummary)
    }

    @Test("says so when there is nothing to fold")
    func reportsNothingToFold() {
        #expect(turn([row("1", .prompt), row("2", .reply)]).hasMachineOutput == false)
        #expect(turn([row("1", .prompt), row("2", .tool)]).hasMachineOutput)
    }
}

@Suite("Summarising a run")
struct RunSummaryTests {
    private func machineRows(_ count: Int) -> [TranscriptRow] {
        (0..<count).map { TranscriptRow(id: "m\($0)", kind: .tool, text: "step \($0)") }
    }

    private func turn(_ rows: [TranscriptRow], condensed: Bool = false) -> TranscriptTurn {
        TranscriptTurn(id: "t1", rows: rows, duration: 187)
    }

    /// During a live run the last few steps answer "what is it doing", so they stay on
    /// screen. The rest is a count. The tail keeps one extra place for the step being
    /// written, which is why it shows six rows and not five.
    @Test("a live run shows its tail and summarises the rest")
    func liveRunShowsItsTail() {
        let items = turn(machineRows(20)).items(condensing: false, generating: true)

        #expect(items.count == 7, "six one-liners and the line under them")
        #expect(items[0].id == "m14", "the tail starts where the six shown begin")
        #expect(items.last?.isStepsSummary == true)
        #expect(items.last?.stepsSummaryLabel == "Ran 20 commands", "the line goes underneath the work")
    }

    /// The rows the fade is drawn over are exactly the rows the tail shows, so the
    /// view and the fold cannot disagree about which calls are leaving.
    @Test("the tail is the last few rows, and empty when nothing is hidden")
    func theTailIsTheLastFewRows() {
        #expect(
            turn(machineRows(20)).tailItems(generating: true).map(\.id)
                == ["m14", "m15", "m16", "m17", "m18", "m19"]
        )
        #expect(turn(machineRows(5)).tailItems(generating: true).isEmpty, "a run that fits has nothing behind it")
        #expect(turn(machineRows(20)).tailItems().isEmpty, "a turn nobody is writing has no tail")
    }

    /// The tense lands on the run still going, not on the ones before it.
    @Test("only the run being written says it is running")
    func onlyTheLiveRunIsRunning() {
        let live = turn(machineRows(20))

        #expect(live.liveSummaryID(generating: true) == "steps:m0")
        #expect(live.liveSummaryID(generating: false) == nil)
        #expect(turn(machineRows(5)).liveSummaryID(generating: true) == nil, "a run that fits has no line")
    }

    /// What `items` draws and what `tailItems` describes have to be the same rows, or
    /// the fade would sit over the wrong ones.
    @Test("the tail the view fades is the tail the turn draws")
    func theDrawnTailMatchesTheDescribedOne() {
        let rows = machineRows(20)
        let drawn = turn(rows).items(condensing: false, generating: true)
            .filter { !$0.isStepsSummary }
            .map(\.id)
        #expect(drawn == turn(rows).tailItems(generating: true).map(\.id))
    }

    /// A finished turn shows the summary alone. The work is done, and the gist is
    /// what it is worth.
    @Test("a finished turn shows only the summary")
    func finishedTurnIsOneLine() {
        let items = turn(machineRows(20), condensed: true).items(condensing: true)

        #expect(items.count == 1)
        #expect(items[0].stepsSummaryLabel == "Ran 20 commands")
    }

    /// The run being written is shown while it fits: a control reading "5 commands" above
    /// the five commands it stands for is a door onto the room you are already in.
    @Test("the run being written is shown while it fits")
    func liveShortRunIsShown() {
        let live = turn(machineRows(5)).items(condensing: false, generating: true)

        #expect(live.count == 5)
        #expect(live.contains(where: \.isStepsSummary) == false)
    }

    /// A finished loop of one folds like any other: the reader is past it, and its command is
    /// one tap away. A loop of one still being written is shown, because there is nothing
    /// behind it to fold.
    @Test("a finished run of one folds, a live one is shown")
    func finishedRunOfOneFolds() {
        let finished = turn(machineRows(1)).items(condensing: false)
        #expect(finished.count == 1)
        #expect(finished[0].isStepsSummary)
        #expect(finished[0].stepsSummaryLabel == "Ran 1 command")

        let live = turn(machineRows(1)).items(condensing: false, generating: true)
        #expect(live.count == 1)
        #expect(live[0].isStepsSummary == false, "a run being written is shown while it fits")
    }

    /// A finished loop collapses, however short, because that is what finishing means: the
    /// gist is what it is worth, and the detail is one tap away.
    @Test("a finished loop is its summary line")
    func finishedLoopCollapses() {
        let items = turn(machineRows(3), condensed: true).items(condensing: true)

        #expect(items.count == 1)
        #expect(items[0].stepsSummaryLabel == "Ran 3 commands")
    }

    /// A tap opens a finished loop where it stands, and its line stays under the rows as
    /// the control that closes it again.
    @Test("an open run shows its rows and keeps its line")
    func openRunShowsItsRows() {
        let closed = turn(machineRows(6)).items(condensing: false)
        #expect(closed.count == 1, "a finished loop of more than one is its line")
        #expect(closed[0].isStepsSummary)

        let open = turn(machineRows(6)).items(condensing: false, expanded: ["steps:m0"])
        #expect(open.map(\.id) == ["m0", "m1", "m2", "m3", "m4", "m5", "steps:m0"])
        #expect(open.last?.isStepsSummary == true, "the line is still the way to close it")
    }

    /// Opening the run being written shows the whole of it rather than the tail.
    @Test("an open live run shows every row")
    func openLiveRunShowsEveryRow() {
        let items = turn(machineRows(20))
            .items(condensing: false, generating: true, expanded: ["steps:m0"])

        #expect(items.count == 21, "all twenty rows and the line under them")
        #expect(items.first?.id == "m0")
        #expect(items.last?.isStepsSummary == true)
    }

    /// A folded repeat still knows the rows it covers, so the sheet can say how long the
    /// loop took rather than only when it started.
    @Test("a folded repeat keeps the rows behind it")
    func repeatKeepsItsRows() {
        let rows = (0..<3).map { TranscriptRow(id: "r\($0)", kind: .tool, text: "same") }

        let steps = rows.drawnSteps()
        #expect(steps.count == 1)
        #expect(steps[0].rows.map(\.id) == ["r0", "r1", "r2"])
    }

    /// What the sheet needs from the turn: the message the work answers.
    @Test("the turn knows the message that asked for it")
    func theTurnKnowsItsPrompt() {
        let rows = [TranscriptRow(id: "p", kind: .prompt, text: "ask")] + machineRows(3)
        #expect(turn(rows).promptRow?.id == "p")
        #expect(turn(machineRows(3)).promptRow == nil, "a turn with nothing said has no prompt")
    }

    /// The control carries the run it stands for, so the sheet holds exactly what the
    /// control said. A control reading "88 steps" that opens 95 is worse than one
    /// reading nothing.
    @Test("the summary carries the steps it counted")
    func theSummaryCarriesItsSteps() {
        let items = turn(machineRows(20)).items(condensing: false)

        let summary = items.last
        let rows = summary?.stepsSummaryRows
        #expect(rows?.count == 20)
        #expect(summary?.stepsSummaryLabel == "Ran 20 commands")
        #expect(rows?.first?.id == "m0", "all of them, not only the five on screen")
    }

    /// The count on a summary frame is what you cannot otherwise see, and it is why
    /// the sheet is worth opening.
    @Test("the summary counts every step of the run, not the ones on screen")
    func theSummaryCountsTheWholeRun() {
        let items = turn(machineRows(83)).items(condensing: false)
        #expect(items.last?.stepsSummaryLabel == "Ran 83 commands")
    }

    @Test("one step is one step, not one steps")
    func singularLabel() {
        let items = turn([TranscriptRow(id: "p", kind: .prompt, text: "ask")] + machineRows(6))
            .items(condensing: false)
        #expect(items.last?.stepsSummaryLabel == "Ran 6 commands")
    }

    /// The step being written is drawn as a paragraph, in addition to the five
    /// one-liners above it rather than in place of one of them.
    @Test("a generating turn ends with its current step")
    func generatingTurnEndsWithItsCurrentStep() {
        let items = turn(machineRows(20)).items(condensing: false, generating: true)

        #expect(items.count == 7, "five one-liners, the step being written, and the line under them")
        #expect(items[0].id == "m14", "the tail keeps all five of its places")
        guard case .liveStep(let row) = items[5] else {
            Issue.record("the newest step should be the live one")
            return
        }
        #expect(row.id == "m19")
        #expect(items[6].isStepsSummary, "and the summary still ends the turn")
    }

    /// A step is only "current" while it is the newest thing: once the agent has gone
    /// back to prose, the work behind it is finished work.
    @Test("a turn that has moved on to prose has no current step")
    func proseEndsTheLiveStep() {
        let rows = machineRows(20) + [TranscriptRow(id: "r", kind: .reply, text: "done")]
        let items = turn(rows).items(condensing: false, generating: true)

        #expect(items.contains(where: { if case .liveStep = $0 { true } else { false } }) == false)
    }

    /// A finished turn is not generating one whatever the caller says, because its
    /// work is over.
    @Test("a condensed turn has no current step")
    func condensedTurnHasNoLiveStep() {
        let items = turn(machineRows(20)).items(condensing: true, generating: true)
        #expect(items.count == 1)
        #expect(items[0].isStepsSummary)
    }

    @Test("a short run being written is shown with its current step")
    func shortGeneratingRun() {
        let items = turn(machineRows(3)).items(condensing: false, generating: true)

        #expect(items.count == 3)
        #expect(items.contains(where: \.isStepsSummary) == false, "three steps is not worth a control")
        guard case .liveStep(let row) = items[2] else {
            Issue.record("the newest step should be the live one")
            return
        }
        #expect(row.id == "m2")
    }
}

@Suite("Describing a run")
struct WorkSummaryTests {
    private func row(_ id: String, _ kind: TranscriptRow.Kind, _ text: String = "x") -> TranscriptRow {
        TranscriptRow(id: id, kind: kind, text: text)
    }

    /// A number says how much happened and nothing about what. The counts by kind are
    /// the description, which is the thing a fold is for.
    @Test("says what the work was, not how much of it there was")
    func describesTheKinds() {
        let rows = [
            row("a", .read), row("b", .read),
            row("c", .tool), row("d", .tool), row("e", .script),
            row("f", .thinking), row("g", .thinking),
        ]

        #expect(
            TranscriptRow.workSummary(rows) == "Read 2 files and ran 3 commands",
            "reads, then commands, as one sentence"
        )
    }

    /// The thoughts clause is dropped when there is real work to name, because the line
    /// it made was long enough to be cut off mid-phrase.
    @Test("names the thoughts only when there is nothing else to name")
    func thoughtsAreTheFallback() {
        let thinking = [row("a", .thinking), row("b", .thinking), row("c", .thinking)]
        #expect(TranscriptRow.workSummary(thinking) == "Thought ×3")
        #expect(TranscriptRow.workSummary(thinking + [row("d", .tool)]) == "Ran 1 command")
    }

    @Test("counts a single one in the singular and keeps the first word capitalised")
    func singulars() {
        #expect(TranscriptRow.workSummary([row("a", .read)]) == "Read 1 file")
        #expect(TranscriptRow.workSummary([row("a", .tool)]) == "Ran 1 command")
        #expect(TranscriptRow.workSummary([row("a", .thinking)]) == "Thought")
        #expect(TranscriptRow.workSummary([row("a", .tool), row("b", .read)]) == "Read 1 file and ran 1 command")
    }

    @Test("says nothing about a run with nothing in it to describe")
    func nothingToSay() {
        #expect(TranscriptRow.workSummary([]) == nil)
        #expect(TranscriptRow.workSummary([row("a", .status)]) == nil)
    }
}

@Suite("A paragraph of a long row")
struct ParagraphTests {
    private func long(_ prefix: String) -> TranscriptRow {
        // Comfortably past the limit, with spaces to cut at.
        let body = (0..<80).map { "\(prefix)\($0)" }.joined(separator: " ")
        return TranscriptRow(id: "1", kind: .thinking, text: body)
    }

    @Test("shows the opening of a finished thought")
    func opening() {
        let row = long("word")
        #expect(row.isLongerThanAParagraph)
        #expect(row.openingParagraph().hasSuffix("…"))
        #expect(row.openingParagraph().hasPrefix("word0"), "from the start")
        #expect(row.openingParagraph().count <= TranscriptRow.paragraphCharacters + 1)
    }

    /// The reason the tail exists: a step being written has its newest words at the
    /// end, and showing the opening instead would freeze the part that is moving.
    @Test("shows the end of a thought being written")
    func closing() {
        let row = long("word")
        #expect(row.closingParagraph().hasPrefix("…"))
        #expect(row.closingParagraph().hasSuffix("word79"), "up to the newest word")
    }

    /// Short thinking is the normal case for models that do not send reasoning.
    @Test("leaves a short row exactly as it is")
    func shortRowsUntouched() {
        let row = TranscriptRow(id: "1", kind: .thinking, text: "I should look at the config.")
        #expect(row.isLongerThanAParagraph == false)
        #expect(row.openingParagraph() == row.text)
        #expect(row.closingParagraph() == row.text)
    }

    @Test("cuts at a word rather than through one")
    func cutsAtAWord() {
        let row = long("word")
        let lastWord = row.openingParagraph()
            .dropLast()
            .split(separator: " ")
            .last
            .map(String.init) ?? ""

        #expect(lastWord.hasPrefix("word"), "a whole token, not half of one: got \(lastWord)")
        #expect(Int(lastWord.dropFirst(4)) != nil, "and not a truncated number: got \(lastWord)")
    }
}

@Suite("Loops")
struct LoopFoldingTests {
    private func tool(_ id: String, _ text: String) -> TranscriptRow {
        TranscriptRow(id: id, kind: .tool, text: text)
    }

    private func thinking(_ id: String, _ text: String) -> TranscriptRow {
        TranscriptRow(id: id, kind: .thinking, text: text)
    }

    /// The case this exists for: an agent looping on one command produces the same
    /// row twenty times, and twenty identical lines say nothing that one line and a
    /// count does not.
    @Test("folds consecutive identical steps into one with a count")
    func foldsRepeats() {
        let items = [
            tool("1", "grep -rn Foo"),
            tool("2", "grep -rn Foo"),
            tool("3", "grep -rn Foo"),
            thinking("4", "Still nothing"),
        ].collapsedRepeats()

        #expect(items.count == 2)
        #expect(items[0].repeatedLabel == "×3")
        #expect(items[1].id == "4")
    }

    /// Only consecutive, and only identical. Two bursts of the same command either
    /// side of a different step are two events, and folding them would misreport how
    /// the agent worked.
    @Test("does not fold a repeat broken by a different step")
    func repeatsMustBeConsecutive() {
        let items = [
            tool("1", "grep -rn Foo"),
            thinking("2", "Hmm"),
            tool("3", "grep -rn Foo"),
        ].collapsedRepeats()

        #expect(items.count == 3)
        #expect(items.map(\.repeatedLabel) == [nil, nil, nil])
    }

    @Test("does not fold two steps of the same kind with different text")
    func differentTextIsNotARepeat() {
        let items = [tool("1", "ls"), tool("2", "pwd")].collapsedRepeats()
        #expect(items.count == 2)
    }

    @Test("an unbroken loop inside a long run still folds")
    func loopsFoldInsideRuns() {
        let loop = (0..<9).map { tool("l\($0)", "grep -rn Foo") }
        let items = (loop + [tool("after", "ls")]).collapsedRepeats()

        #expect(items.count == 2)
        #expect(items[0].repeatedLabel == "×9")
    }
}
