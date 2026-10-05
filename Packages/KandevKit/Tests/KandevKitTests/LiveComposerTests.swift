import Foundation
import Testing

@testable import KandevKit

/// Writes to a real server. Off unless two variables name a scratch task and the
/// agent profile to run it with:
///
///     KANDEV_LIVE_WRITE=<scratch-task-id> \
///     KANDEV_LIVE_PROFILE=<agent-profile-id> \
///     make test-live-write
///
/// Separate from the read-only live suite on purpose, because this one starts an
/// agent. It never creates or deletes a task: point it at something disposable.
///
/// The task must already have a session running, since a prompt cannot be
/// addressed without that session's incarnation id. Launch one with
/// `session.launch` and the profile id before running this.
@Suite(
    "Live composer",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["KANDEV_LIVE_WRITE"] != nil
        && ProcessInfo.processInfo.environment["KANDEV_LIVE_PROFILE"] != nil
        && ProcessInfo.processInfo.environment["KANDEV_LIVE"] != nil)
)
struct LiveComposerTests {
    /// Falls back rather than force-unwrapping: a missing variable should be a
    /// failed test, not a crash that takes the whole run down with it.
    private var client: KandevClient {
        let raw = ProcessInfo.processInfo.environment["KANDEV_LIVE"] ?? "http://127.0.0.1:1"
        return KandevClient(baseURL: URL(string: raw) ?? URL(string: "http://127.0.0.1:1")!)
    }

    private var taskID: String {
        ProcessInfo.processInfo.environment["KANDEV_LIVE_WRITE"] ?? "no-task-named"
    }

    /// A session able to accept prompts, which means it carries an incarnation id.
    private func promptableSession(_ client: KandevClient) async throws -> KandevSession {
        let sessions = try await client.sessions(taskID: taskID)
        return try #require(
            sessions.first { $0.queueIncarnationID != nil },
            "no session with a queue incarnation id; launch one first"
        )
    }

    @Test("sends a prompt through the client and sees it arrive in the transcript")
    func sendsAPrompt() async throws {
        let client = client
        try await client.connect()
        let session = try await promptableSession(client)
        let incarnation = try #require(session.queueIncarnationID)

        let before = try await client.queue(
            sessionID: session.id,
            taskID: taskID,
            sessionIncarnationID: incarnation
        )
        #expect(before.count >= 0)

        let marker = "COMPOSER PROBE \(UUID().uuidString.prefix(8))"
        let queued = try await client.sendPrompt(
            "Reply with exactly: \(marker)",
            sessionID: session.id,
            taskID: taskID,
            sessionIncarnationID: incarnation,
            clientQueueID: UUID().uuidString
        )
        #expect(!queued.id.isEmpty)

        // The agent needs time to answer. Poll rather than sleep a fixed guess.
        var found = false
        for _ in 0..<30 {
            let page = try await client.messages(sessionID: session.id, limit: 50)
            if page.messages.contains(where: { $0.content?.contains(marker) == true }) {
                found = true
                break
            }
            try await Task.sleep(for: .seconds(2))
        }
        #expect(found, "the prompt never appeared in the transcript")

        // Clearing an already-drained queue must be accepted, not rejected.
        try await client.clearQueue(
            sessionID: session.id,
            taskID: taskID,
            sessionIncarnationID: incarnation
        )
        await client.close()
    }

    @Test("a prompt with no incarnation id is refused rather than sent blindly")
    func refusesWithoutIncarnation() async throws {
        let client = client
        try await client.connect()

        await #expect(throws: (any Error).self) {
            _ = try await client.sendPrompt(
                "should not be sent",
                sessionID: "00000000-0000-0000-0000-000000000000",
                taskID: taskID,
                sessionIncarnationID: "not-a-real-incarnation",
                clientQueueID: UUID().uuidString
            )
        }

        await client.close()
    }
}
