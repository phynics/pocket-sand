import Foundation
import Testing

@testable import KandevKit

@Suite("Previous replies")
struct PreviousRepliesTests {
    private func reply(_ id: String) -> TranscriptRow {
        TranscriptRow(id: id, kind: .reply, text: id)
    }

    private func prompt(_ id: String) -> TranscriptRow {
        TranscriptRow(id: id, kind: .prompt, text: id)
    }

    @Test("the first turn has nothing before it")
    func firstTurnHasNoPrevious() {
        let turns = [TranscriptTurn(id: "t1", rows: [prompt("p1"), reply("r1")])]
        #expect(turns.previousReplies() == [nil])
    }

    @Test("each turn sees the last reply of the turns before it")
    func eachTurnSeesLastReplyBefore() {
        let turns = [
            TranscriptTurn(id: "t1", rows: [prompt("p1"), reply("r1")]),
            TranscriptTurn(id: "t2", rows: [prompt("p2")]),
            TranscriptTurn(id: "t3", rows: [prompt("p3"), reply("r3a"), reply("r3b")]),
            TranscriptTurn(id: "t4", rows: [prompt("p4")]),
        ]
        let previous = turns.previousReplies().map { $0?.id }
        #expect(previous == [nil, "r1", "r1", "r3b"])
    }

    @Test("agrees with a per-turn search over the same turns")
    func matchesPerTurnSearch() {
        let turns = [
            TranscriptTurn(id: "t1", rows: [reply("a")]),
            TranscriptTurn(id: "t2", rows: []),
            TranscriptTurn(id: "t3", rows: [reply("b")]),
            TranscriptTurn(id: "t4", rows: [prompt("p")]),
        ]
        let expected = turns.indices.map { index -> String? in
            guard index > 0 else { return nil }
            for turn in turns[..<index].reversed() {
                if let row = turn.replyRow { return row.id }
            }
            return nil
        }
        #expect(turns.previousReplies().map { $0?.id } == expected)
    }
}
