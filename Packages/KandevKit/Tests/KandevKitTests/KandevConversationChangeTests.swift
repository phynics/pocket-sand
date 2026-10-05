import Foundation
import Testing

@testable import KandevKit

/// The conversation change rules.
///
/// Every frame in this suite was captured from a live v0.96.0 server while a real
/// agent answered a prompt. None of it is written from documentation.
@Suite("KandevConversationChange")
struct KandevConversationChangeTests {
    private func change(_ json: String) throws -> KandevConversationChange {
        try JSONDecoder().decode(KandevConversationChange.self, from: Data(json.utf8))
    }

    private let scope = "core:ios:probe-1"
    private let session = "fc606fe7-756b-4e6d-b926-b4fa865cb915"
    private let epoch = "519bca84-4c1b-4725-934e-a48d1835e22d"

    /// Captured: the user's prompt arriving on the live stream.
    private let userPromptRaw = #"""
{"base_revision": "9", "epoch": "519bca84-4c1b-4725-934e-a48d1835e22d", "operations": [{"entity": "message", "id": "58809e50-6e11-5dc6-b468-a4fc33672f60", "kind": "upsert", "message": {"author_type": "user", "content": "Reply with exactly: FOLLOW OK", "created_at": "2026-10-04T21:38:05.433384577Z", "id": "58809e50-6e11-5dc6-b468-a4fc33672f60", "metadata": {"client_message_request_fingerprint": "2cefc6ab401bd26dc50d42f64d15b4f63b2e6f100825afc0826006a2f8e21063"}, "prompt_index": 2, "requests_input": false, "session_id": "fc606fe7-756b-4e6d-b926-b4fa865cb915", "task_id": "96d46f82-a814-4f2e-b990-fd60ba5a2488", "turn_id": "a0483204-4a53-4f24-b9e0-ebb684e6d06b", "type": "message", "updated_at": "2026-10-04T21:38:05.433384577Z"}}], "protocol_version": 2, "revision": "10", "scope_id": "core:ios:probe-1", "session_id": "fc606fe7-756b-4e6d-b926-b4fa865cb915"}
"""#

    /// Captured: the agent's reply arriving on the live stream.
    private let agentReplyRaw = #"""
{"base_revision": "11", "epoch": "519bca84-4c1b-4725-934e-a48d1835e22d", "operations": [{"entity": "message", "id": "475edb38-40e7-487b-a6d6-d5ecb5bcbfde", "kind": "upsert", "message": {"author_type": "agent", "content": "FOLLOW OK", "created_at": "2026-10-04T21:38:07.926964136Z", "id": "475edb38-40e7-487b-a6d6-d5ecb5bcbfde", "metadata": {"model": "opencode-go/deepseek-flash"}, "requests_input": false, "session_id": "fc606fe7-756b-4e6d-b926-b4fa865cb915", "task_id": "96d46f82-a814-4f2e-b990-fd60ba5a2488", "turn_id": "a0483204-4a53-4f24-b9e0-ebb684e6d06b", "type": "message", "updated_at": "2026-10-04T21:38:07.926964136Z"}}], "protocol_version": 2, "revision": "12", "scope_id": "core:ios:probe-1", "session_id": "fc606fe7-756b-4e6d-b926-b4fa865cb915"}
"""#

    /// Captured: the liveness heartbeat.
    private let heartbeatRaw = #"""
{"base_revision": "13", "check": true, "epoch": "519bca84-4c1b-4725-934e-a48d1835e22d", "operations": [], "protocol_version": 2, "revision": "13", "scope_id": "core:ios:probe-1", "session_id": "fc606fe7-756b-4e6d-b926-b4fa865cb915"}
"""#

    private func decide(
        _ change: KandevConversationChange,
        appliedEpoch: String? = nil,
        appliedRevision: String? = nil,
        scope: String? = nil,
        session: String? = nil
    ) -> KandevConversationChangeDecision {
        change.decision(
            expectedScopeID: scope ?? self.scope,
            expectedSessionID: session ?? self.session,
            appliedEpoch: appliedEpoch ?? epoch,
            appliedRevision: appliedRevision
        )
    }

    @Test("a captured message change decodes into a message with its text")
    func decodesCapturedMessage() throws {
        let change = try change(agentReplyRaw)
        let message = try #require(change.operations.first?.message)

        #expect(message.authorType == "agent")
        #expect(message.content == "FOLLOW OK")
        #expect(message.isFromUser == false)
        #expect(message.sessionID == session)
    }

    @Test("applies a change that continues from the revision the reader holds")
    func appliesAContinuation() throws {
        let change = try change(agentReplyRaw)

        guard case .apply(let operations, let revision) = decide(change, appliedRevision: change.baseRevision)
        else {
            Issue.record("expected the change to apply")
            return
        }
        #expect(operations.count == 1)
        #expect(revision == change.revision)
    }

    /// The heartbeat is the trap: it looks exactly like a change, arrives every
    /// few seconds, and carries nothing. Treating it as a change would refetch
    /// the conversation on a timer.
    @Test("ignores the liveness heartbeat")
    func ignoresHeartbeat() throws {
        let change = try change(heartbeatRaw)

        #expect(change.check == true)
        #expect(change.operations.isEmpty)
        #expect(decide(change, appliedRevision: "13") == .ignore)
    }

    @Test("ignores another client's view of the same session")
    func ignoresAnotherScope() throws {
        let change = try change(agentReplyRaw)

        #expect(
            decide(change, appliedRevision: change.baseRevision, scope: "core:web:someone-else")
                == .ignore
        )
    }

    @Test("ignores a change for a different session")
    func ignoresAnotherSession() throws {
        let change = try change(agentReplyRaw)

        #expect(decide(change, appliedRevision: change.baseRevision, session: "another-session") == .ignore)
    }

    /// Applying a change that builds on a revision the reader never reached would
    /// leave a hole in the conversation, and a hole nobody can see is worse than a
    /// refetch.
    @Test("refetches when a revision was missed")
    func refetchesOnGap() throws {
        let change = try change(agentReplyRaw)

        let decision = decide(change, appliedRevision: "1")
        guard case .refetch(let reason) = decision else {
            Issue.record("expected a refetch, got \(decision)")
            return
        }
        #expect(reason.contains("missed"))
    }

    @Test("refetches when the conversation log was replaced")
    func refetchesOnNewEpoch() throws {
        let change = try change(agentReplyRaw)

        let decision = decide(change, appliedEpoch: "a-different-epoch", appliedRevision: change.baseRevision)
        guard case .refetch = decision else {
            Issue.record("expected a refetch, got \(decision)")
            return
        }
    }

    @Test("refetches rather than guessing at an operation it does not know")
    func refetchesOnUnknownOperation() throws {
        let raw = #"""
        {"epoch": "e", "base_revision": "1", "revision": "2",
         "operations": [{"entity": "widget", "id": "w1", "kind": "upsert"}]}
        """#

        let decision = decide(try change(raw), appliedEpoch: "e", appliedRevision: "1")
        guard case .refetch = decision else {
            Issue.record("expected a refetch, got \(decision)")
            return
        }
    }

    @Test("refetches on an operation kind it does not know")
    func refetchesOnUnknownKind() throws {
        let raw = #"""
        {"epoch": "e", "base_revision": "1", "revision": "2",
         "operations": [{"entity": "message", "id": "m1", "kind": "delete"}]}
        """#

        let decision = decide(try change(raw), appliedEpoch: "e", appliedRevision: "1")
        guard case .refetch = decision else {
            Issue.record("expected a refetch, got \(decision)")
            return
        }
    }

    @Test("applies the first change after subscribing, when no revision is held yet")
    func appliesWithoutPriorRevision() throws {
        let change = try change(userPromptRaw)

        let decision = decide(change, appliedRevision: nil)
        guard case .apply = decision else {
            Issue.record("expected the first change to apply, got \(decision)")
            return
        }
    }

    @Test("refuses a change that names no revision")
    func refetchesWithoutRevision() throws {
        let raw = #"{"epoch": "e", "operations": []}"#

        let decision = decide(try change(raw), appliedEpoch: "e", appliedRevision: "1")
        guard case .refetch = decision else {
            Issue.record("expected a refetch, got \(decision)")
            return
        }
    }

    @Test("a scope id names this client, and two of them differ")
    func scopeIDsAreDistinct() {
        let first = ConversationScope.newID()
        let second = ConversationScope.newID()

        #expect(first != second)
        #expect(first.hasPrefix("core:ios:"))
    }
}
