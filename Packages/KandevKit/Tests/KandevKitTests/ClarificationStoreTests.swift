import Foundation
import Testing

@testable import KandevKit

private final class StubResponder: KandevClarificationResponding, @unchecked Sendable {
    var sent: [(pendingID: String, answers: [KandevClarificationAnswer], rejected: Bool)] = []
    var failure: (any Error)?

    func respondToClarification(
        pendingID: String,
        answers: [KandevClarificationAnswer],
        rejected: Bool
    ) async throws {
        if let failure {
            self.failure = nil
            throw failure
        }
        sent.append((pendingID, answers, rejected))
    }
}

/// The server takes a whole bundle at once, so the store's job is deciding *when* a request is
/// made: one question sends on its own, a bundle waits for its last one.
@MainActor
@Suite("ClarificationStore")
struct ClarificationStoreTests {
    private func clarification(question: String = "q1", total: Int = 1) -> KandevClarification {
        KandevClarification(
            pendingID: "p1",
            sessionID: "s1",
            taskID: "t1",
            questionID: question,
            title: "A question",
            prompt: "Which one?",
            options: [
                KandevClarification.Option(id: "o1", label: "One"),
                KandevClarification.Option(id: "o2", label: "Two"),
            ],
            allowsCustomText: false,
            index: 1,
            total: total,
            context: nil,
            status: .pending,
            answer: nil,
            agentDisconnected: false
        )
    }

    @Test("a lone question is sent as soon as it is answered")
    func singleQuestionSends() async {
        let responder = StubResponder()
        let store = ClarificationStore(source: responder)

        await store.answer(
            clarification(),
            with: KandevClarificationAnswer(questionID: "q1", selectedOptions: ["o1"])
        )

        #expect(responder.sent.count == 1)
        #expect(responder.sent.first?.answers.first?.selectedOptions == ["o1"])
        #expect(responder.sent.first?.rejected == false)
        #expect(store.settled.contains("p1"))
    }

    @Test("a bundle waits for its last question")
    func bundleWaits() async {
        let responder = StubResponder()
        let store = ClarificationStore(source: responder)

        await store.answer(
            clarification(question: "q1", total: 2),
            with: KandevClarificationAnswer(questionID: "q1", selectedOptions: ["o1"])
        )
        #expect(responder.sent.isEmpty, "one answer out of two is not the bundle")

        await store.answer(
            clarification(question: "q2", total: 2),
            with: KandevClarificationAnswer(questionID: "q2", selectedOptions: ["o2"])
        )
        #expect(responder.sent.count == 1)
        #expect(responder.sent.first?.answers.count == 2)
    }

    @Test("rejecting sends no answers")
    func rejectingSendsNoAnswers() async {
        let responder = StubResponder()
        let store = ClarificationStore(source: responder)

        await store.reject("p1")

        #expect(responder.sent.first?.rejected == true)
        #expect(responder.sent.first?.answers.isEmpty == true)
    }

    /// A refusal is something to try again, and re-picking every option because the network
    /// blinked would be its own small cruelty.
    @Test("a refused answer keeps the choice")
    func refusedAnswerKeepsTheChoice() async {
        let responder = StubResponder()
        responder.failure = KandevError.connectionClosed
        let store = ClarificationStore(source: responder)

        await store.answer(
            clarification(),
            with: KandevClarificationAnswer(questionID: "q1", selectedOptions: ["o1"])
        )

        #expect(store.selection(pendingID: "p1", questionID: "q1") != nil)
        if case .failed = store.phase {} else {
            Issue.record("expected a failure, got \(store.phase)")
        }
        #expect(store.settled.isEmpty)
    }
}
