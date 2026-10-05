import Foundation
import Testing

@testable import KandevKit

/// The frames in this suite were captured from a live v0.96.0 server, not
/// written from the documentation. Where the two disagree, these win.
@Suite("KandevFailure")
struct KandevFailureTests {
    private func envelope(_ json: String) throws -> KandevEnvelope {
        try JSONDecoder().decode(KandevEnvelope.self, from: Data(json.utf8))
    }

    @Test("classifies an error frame")
    func errorFrame() throws {
        let frame = try envelope(#"""
        {"id":"1","type":"error","action":"task.get",
         "payload":{"code":"VALIDATION_ERROR","message":"id is required"}}
        """#)

        let failure = try #require(KandevFailure.failure(in: frame))

        #expect(failure == .server(KandevErrorPayload(code: "VALIDATION_ERROR", message: "id is required")))
        #expect(failure.serverCode == "VALIDATION_ERROR")
        #expect(failure.errorDescription == "id is required")
    }

    /// Captured verbatim: `session.conversation.subscribe` with only a
    /// `session_id`. Note that this arrives as `type: "response"`.
    @Test("classifies a failure reported inside a response frame")
    func successFalseInsideResponse() throws {
        let frame = try envelope(#"""
        {"id":"E347A7BA-7F37-45BB-A6A7-710382332A54","type":"response",
         "action":"session.conversation.subscribe",
         "payload":{"success":false,
                    "error":{"code":"invalid_request","message":"session_id and scope_id are required","retryable":false},
                    "session_id":"e6f2afa1-6ba9-45b4-807e-f143fd28a217"}}
        """#)

        let failure = try #require(KandevFailure.failure(in: frame))

        #expect(
            failure == .action(
                KandevActionFailure(
                    code: "invalid_request",
                    message: "session_id and scope_id are required",
                    retryable: false
                )
            )
        )
        #expect(failure.serverCode == "invalid_request")
    }

    @Test("treats an ordinary response as a success")
    func ordinaryResponseIsNotAFailure() throws {
        let frame = try envelope(#"""
        {"id":"1","type":"response","action":"workspace.list","payload":{"total":1,"workspaces":[]}}
        """#)

        #expect(KandevFailure.failure(in: frame) == nil)
    }

    /// The guard that matters: content the app cares about must not be mistaken
    /// for a failure merely because a field is named `error`.
    @Test("a session's own error field is not a transport failure")
    func sessionErrorFieldIsNotAFailure() throws {
        let frame = try envelope(#"""
        {"id":"1","type":"response","action":"session.get",
         "payload":{"id":"s1","last_agent_error":{"message":"rate limited"}}}
        """#)

        #expect(KandevFailure.failure(in: frame) == nil)
    }

    @Test("an explicitly successful result with an error field is not a failure")
    func successTrueWins() throws {
        let frame = try envelope(#"""
        {"id":"1","type":"response","action":"session.ensure",
         "payload":{"success":true,"error":null,"session_id":"s1"}}
        """#)

        #expect(KandevFailure.failure(in: frame) == nil)
    }

    @Test("reports an unreadable error frame instead of crashing")
    func unreadableErrorFrame() throws {
        let frame = try envelope(#"{"id":"1","type":"error","action":"task.get","payload":null}"#)

        let failure = try #require(KandevFailure.failure(in: frame))

        #expect(failure.serverCode == "UNKNOWN")
    }

    @Test("reports an unreadable success:false frame instead of crashing")
    func unreadableActionFailure() throws {
        let frame = try envelope(#"{"id":"1","type":"response","action":"session.focus","payload":{"success":false}}"#)

        let failure = try #require(KandevFailure.failure(in: frame))

        #expect(failure.serverCode == "UNKNOWN")
    }

    @Test("never classifies a notification as a failure")
    func notificationsAreNotFailures() throws {
        let frame = try envelope(#"{"type":"notification","action":"acp.progress","payload":{"error":"agent said error"}}"#)

        #expect(KandevFailure.failure(in: frame) == nil)
    }
}

@Suite("An HTTP failure's words")
struct HTTPFailurePhrasingTests {
    @Test("reads the server's sentence out of a JSON body")
    func readsTheSentence() {
        let cases: [(String, String)] = [
            (#"{"detail": "task_delete_dirty_worktree"}"#, "task_delete_dirty_worktree"),
            (#"{"message": "Worktree is dirty"}"#, "Worktree is dirty"),
            (#"{"error": "Nope"}"#, "Nope"),
            (#"{"error": {"message": "Deep"}}"#, "Deep"),
        ]

        for (body, expected) in cases {
            let error = KandevError.http(status: 400, body: body)
            #expect(error.errorDescription == "The server answered HTTP 400: \(expected)")
        }
    }

    /// A body with nothing to say is shown as it came rather than swallowed, and a body
    /// that would flood the screen is cut.
    @Test("falls back to the body, trimmed and cut")
    func fallsBackToTheBody() {
        let plain = KandevError.http(status: 500, body: "  upstream exploded  ")
        #expect(plain.errorDescription == "The server answered HTTP 500: upstream exploded")

        let long = KandevError.http(status: 500, body: String(repeating: "x", count: 400))
        #expect(long.errorDescription?.hasSuffix("…") == true)
        #expect(long.errorDescription?.count == 200 + "…".count + "The server answered HTTP 500: ".count)

        let empty = KandevError.http(status: 404, body: "   ")
        #expect(empty.errorDescription == "The server answered HTTP 404.")
        let absent = KandevError.http(status: 404, body: nil)
        #expect(absent.errorDescription == "The server answered HTTP 404.")
    }

    /// JSON that is not about a failure — a bare array, or an object with no words in
    /// it — is the body, not a message.
    @Test("does not invent a message out of JSON that has none")
    func noInventedMessages() {
        let array = KandevError.http(status: 400, body: #"[1, 2, 3]"#)
        #expect(array.errorDescription == "The server answered HTTP 400: [1, 2, 3]")

        let quiet = KandevError.http(status: 400, body: #"{"code": "MEDIUM"}"#)
        #expect(quiet.errorDescription == "The server answered HTTP 400: {\"code\": \"MEDIUM\"}")
    }
}
