import Foundation
import Observation

/// Answering the questions an agent is blocked on.
///
/// The server takes a whole bundle at once — an answer per question, or a rejection of all of
/// them — so a per-question tap is collected here and sent when the bundle is finished. The
/// server's own client does the same for the same reason: an agent that asked three questions
/// waits for all three.
@MainActor
@Observable
public final class ClarificationStore {
    public enum Phase: Equatable {
        case idle
        /// Sending the answers to this bundle.
        case sending(String)
        case failed(String, String)
    }

    /// What has been chosen so far, by pending id and then question id.
    public private(set) var selections: [String: [String: KandevClarificationAnswer]] = [:]
    public private(set) var phase: Phase = .idle
    /// Bundles already answered, so a card stops offering the question again while the server's
    /// own update is on its way back.
    public private(set) var settled: Set<String> = []

    private let source: any KandevClarificationResponding

    public init(source: any KandevClarificationResponding) {
        self.source = source
    }

    /// Records one question's answer, and sends the bundle once every question has one.
    public func answer(_ clarification: KandevClarification, with answer: KandevClarificationAnswer) async {
        guard clarification.isOpen else { return }

        var draft = selections[clarification.pendingID] ?? [:]
        draft[clarification.questionID] = answer
        selections[clarification.pendingID] = draft

        guard draft.count >= clarification.bundleSize else { return }
        await send(pendingID: clarification.pendingID, answers: Array(draft.values), rejected: false)
    }

    /// Rejects the whole bundle: the question is dismissed rather than answered.
    public func reject(_ pendingID: String) async {
        await send(pendingID: pendingID, answers: [], rejected: true)
    }

    /// What has been chosen for one question, while a bundle is still being filled in.
    public func selection(pendingID: String, questionID: String) -> KandevClarificationAnswer? {
        selections[pendingID]?[questionID]
    }

    private func send(pendingID: String, answers: [KandevClarificationAnswer], rejected: Bool) async {
        phase = .sending(pendingID)
        do {
            try await source.respondToClarification(
                pendingID: pendingID,
                answers: answers,
                rejected: rejected
            )
            settled.insert(pendingID)
            selections[pendingID] = nil
            phase = .idle
        } catch {
            // The draft is kept, so a refusal can be tried again: re-picking every option because
            // the network blinked would be its own small cruelty.
            phase = .failed(pendingID, KandevError.readableMessage(for: error))
        }
    }
}
