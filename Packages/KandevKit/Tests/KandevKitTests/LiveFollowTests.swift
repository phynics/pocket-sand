import Foundation
import Testing

@testable import KandevKit

/// Watches a real session and checks that the conversation arrives on its own.
///
/// Off unless a scratch task and profile are named, like `LiveComposerTests`, and
/// for the same reason: it starts an agent.
@Suite(
    "Live follow",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["KANDEV_LIVE_WRITE"] != nil
        && ProcessInfo.processInfo.environment["KANDEV_LIVE_PROFILE"] != nil
        && ProcessInfo.processInfo.environment["KANDEV_LIVE"] != nil)
)
@MainActor
struct LiveFollowTests {
    private var taskID: String {
        ProcessInfo.processInfo.environment["KANDEV_LIVE_WRITE"] ?? "no-task-named"
    }

    /// The assertion that matters: the agent's reply reaches the transcript while
    /// the conversation revision advances, which only a live change can do. A
    /// refetch would leave the revision where the handshake put it.
    @Test("an agent reply arrives on the live stream, not from a refetch")
    func followsTheLatestMessage() async throws {
        let client = KandevClient(
            baseURL: URL(string: ProcessInfo.processInfo.environment["KANDEV_LIVE"] ?? "http://127.0.0.1:1")!
        )
        try await client.connect()

        let store = TaskConversationStore(
            transcriptSource: client,
            promptSource: client,
            conversationServer: client
        )
        await store.load(taskID: taskID)
        #expect(store.isFollowing, "the subscription never started")

        let handshakeRevision = try #require(store.appliedRevision)
        let session = try #require(store.transcript.selectedSession)
        let incarnation = try #require(session.queueIncarnationID)

        let marker = "FOLLOW \(UUID().uuidString.prefix(6))"
        _ = try await client.sendPrompt(
            "Reply with exactly: \(marker)",
            sessionID: session.id,
            taskID: taskID,
            sessionIncarnationID: incarnation,
            clientQueueID: UUID().uuidString
        )

        var sawReply = false
        var revisionAdvanced = false
        for _ in 0..<40 {
            let rows = store.transcript.turns.flatMap(\.rows)
            if rows.contains(where: { $0.text.contains(marker) }) { sawReply = true }
            if let now = store.appliedRevision, let before = Int(handshakeRevision),
               let current = Int(now), current > before {
                revisionAdvanced = true
            }
            if sawReply && revisionAdvanced { break }
            try await Task.sleep(for: .seconds(1))
        }

        #expect(sawReply, "the reply never appeared in the transcript")
        #expect(
            revisionAdvanced,
            "the conversation revision never moved past \(handshakeRevision), so the message did not arrive as a live change"
        )

        await store.stopFollowing()
        await client.close()
    }

    // A live "nothing should change for twelve seconds" test lived here and was
    // removed. It cannot be made reliable: another suite runs first and its turn
    // completion arrives during the window, so the revision advances for a
    // legitimate reason and the assertion fails for the wrong one. The property
    // it was reaching for — that a heartbeat is ignored — is proven
    // deterministically in KandevConversationChangeTests against a captured
    // heartbeat frame.
}
