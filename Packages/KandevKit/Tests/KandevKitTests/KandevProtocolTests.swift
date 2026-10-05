import Foundation
import Testing

@testable import KandevKit

/// The wire contract, checked both ways.
///
/// Every action the client knows is pinned here against the server's own
/// registry, and every frame it reads is pinned against a shape it must refuse.
/// The second half is the point: a frame that is *almost* right — a notification
/// keyed by `id` instead of `task_id`, a list without its array — must throw
/// rather than build a half-filled value that renders as if it were real.
///
/// The envelope and the `error` frame come from the vendored reference at
/// `docs/reference/kandev-websocket-api.md`; the action surface was learned from
/// a live v0.96.0 server, which is why the two do not fully overlap.

private func decode<T: Decodable>(_ type: T.Type = T.self, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// Whether a payload is refused. A `nil` result means it decoded, which for the
/// cases below is the failure.
private func refuses<T: Decodable>(_ type: T.Type, _ json: String) -> Bool {
    (try? JSONDecoder().decode(T.self, from: Data(json.utf8))) == nil
}

private func failure(in json: String) throws -> KandevError? {
    let envelope = try JSONDecoder().decode(KandevEnvelope.self, from: Data(json.utf8))
    return KandevFailure.failure(in: envelope)
}

// MARK: - The action registry

/// `KandevAction.verified` is a written-down protocol, and until now nothing
/// read it. This suite reads it, so the list cannot quietly drift from the
/// constants beside it.
@Suite("KandevAction registry")
struct KandevActionRegistryTests {
    /// Swift cannot enumerate an enum's static members, so the list is written
    /// out. Adding a constant without adding it here is the one drift this
    /// cannot catch; everything else — a name dropped from `verified`, two
    /// constants that collide, a missing entry — it does.
    private var everyAction: [String] {
        [
            KandevAction.workspaceList,
            KandevAction.workflowList,
            KandevAction.workflowStepList,
            KandevAction.taskList,
            KandevAction.taskGet,
            KandevAction.messageList,
            KandevAction.sessionConversationSubscribe,
            KandevAction.sessionConversationUnsubscribe,
            KandevAction.sessionConversationChanged,
            KandevAction.sessionStop,
            KandevAction.sessionLaunch,
            KandevAction.messageQueueAdd,
            KandevAction.messageQueueSendNow,
            KandevAction.messageQueueCancel,
            KandevAction.messageQueueGet,
            KandevAction.taskCreate,
            KandevAction.taskDelete,
            KandevAction.taskUpdated,
            KandevAction.taskStateChanged,
            KandevAction.sessionStateChanged,
            KandevAction.taskCreated,
            KandevAction.taskDeleted,
            KandevAction.taskArchived,
            KandevAction.taskStatusSummaryUpdated,
        ]
    }

    @Test("the constants and the verified list name the same actions, once each")
    func verifiedListIsComplete() {
        #expect(Set(everyAction).count == everyAction.count, "two constants share a name")
        #expect(Set(everyAction) == Set(KandevAction.verified))
    }

    /// Kandev namespaces every action with its family, which is what makes an
    /// action string readable in a log without a lookup.
    @Test("every action is a lowercase, dotted name")
    func actionsAreNamespaced() {
        for action in everyAction {
            #expect(action.contains("."), "\(action) is not namespaced")
            #expect(action == action.lowercased(), "\(action) is not lowercase")
        }
    }
}

// MARK: - The documented error frame

/// The reference lists five codes and one place a failure can live. This pins
/// both: the codes survive into `serverCode`, and `details` survives for the
/// caller that needs the machine-readable half.
@Suite("The documented error frame")
struct DocumentedErrorFrameTests {
    @Test("every documented code is read as a server failure, with its sentence")
    func documentedCodes() throws {
        for code in ["BAD_REQUEST", "VALIDATION_ERROR", "NOT_FOUND", "INTERNAL_ERROR", "UNKNOWN_ACTION"] {
            let json = #"""
            {"id":"1","type":"error","action":"task.get","payload":{"code":"\#(code)","message":"no"}}
            """#

            let classified = try #require(try failure(in: json))
            #expect(classified.serverCode == code, "\(code) should survive as a code")
            #expect(classified.errorDescription == "no", "\(code) should keep the server's sentence")
        }
    }

    /// `VALIDATION_ERROR` names the missing field in `details`, and a caller that
    /// shows only `message` would make the person guess.
    @Test("the details object survives classification")
    func detailsSurvive() throws {
        let json = #"""
        {"id":"1","type":"error","action":"task.create",
         "payload":{"code":"VALIDATION_ERROR","message":"workflow_id is required",
                    "details":{"field":"workflow_id"}}}
        """#

        let classified = try #require(try failure(in: json))
        guard case .server(let payload) = classified else {
            Issue.record("expected a server failure, got \(classified)")
            return
        }
        #expect(payload.details?["field"] == .string("workflow_id"))
    }
}

// MARK: - The queue's error vocabulary

/// `queue_full` is the one failure the composer turns into a state rather than a
/// message, so the limit has to survive the trip from the server's `details`
/// object. These are the only tests that call the translation directly.
@Suite("KandevQueueFailure")
struct KandevQueueFailureTests {
    private func actionFailure(code: String, details: JSONValue? = nil) -> KandevError {
        .action(KandevActionFailure(code: code, message: "m", details: details))
    }

    @Test("a full queue becomes the server's own limit")
    func fullCarriesTheServerLimit() {
        let translated = KandevQueueFailure.translate(
            actionFailure(code: KandevQueueFailure.full, details: .object(["max": .integer(5)]))
        )

        #expect(translated == .queueFull(limit: 5))
    }

    /// Only a frame that omitted the number gets the fallback.
    @Test("a full queue with no number falls back to the capacity the server reported")
    func fullFallsBack() {
        let translated = KandevQueueFailure.translate(actionFailure(code: KandevQueueFailure.full))

        #expect(translated == .queueFull(limit: KandevQueueFailure.fallbackLimit))
    }

    @Test("a code that is not about a full queue is left for the caller to show")
    func otherCodesPassThrough() {
        let error = actionFailure(code: "invalid_request")

        #expect(KandevQueueFailure.translate(error) == error)
    }

    /// The translation is scoped to the `success: false` shape. A `type: error`
    /// frame is the server's words and is not rewritten.
    @Test("a server error frame is not rewritten")
    func serverFramesPassThrough() {
        let error = KandevError.server(
            KandevErrorPayload(code: "VALIDATION_ERROR", message: "no")
        )

        #expect(KandevQueueFailure.translate(error) == error)
    }

    @Test("a full queue asks the person to wait, not to rephrase")
    func fullHasItsOwnSentence() {
        #expect(KandevError.queueFull(limit: 5).errorDescription?.contains("5") == true)
    }
}

/// The translation only fires when the client goes through its own `sendPrompt`,
/// so one test drives a classifying transport all the way through it.
@Suite("A full queue reaches the composer as a limit")
struct QueueFullThroughTheClientTests {
    /// Answers the way `WebSocketTransport` does — classifying the frame before
    /// returning it — so the client's failure translation is exercised, not
    /// bypassed.
    private actor ClassifyingTransport: KandevTransport {
        nonisolated let notifications: AsyncStream<KandevEnvelope>
        private let reply: JSONValue

        init(reply: JSONValue) {
            let (stream, _) = AsyncStream<KandevEnvelope>.makeStream()
            self.notifications = stream
            self.reply = reply
        }

        func connect() async throws {}

        func send(_ envelope: KandevEnvelope) async throws -> KandevEnvelope {
            let frame = KandevEnvelope(
                id: envelope.id,
                type: .response,
                action: envelope.action,
                payload: reply
            )
            if let failure = KandevFailure.failure(in: frame) { throw failure }
            return frame
        }

        func close() async {}
    }

    @Test("queue_full with a max surfaces as queueFull(limit:), not as a decode error")
    func queueFullSurvivesTheClient() async throws {
        let transport = ClassifyingTransport(reply: .object([
            "success": .bool(false),
            "error": .object([
                "code": .string(KandevQueueFailure.full),
                "message": .string("queue is full"),
                "details": .object(["max": .integer(5)]),
            ]),
        ]))
        let client = KandevClient(
            transport: transport,
            http: KandevHTTPClient(configuration: .init(baseURL: URL(string: "http://localhost")!))
        )

        do {
            _ = try await client.sendPrompt(
                "hello",
                sessionID: "s1",
                taskID: "t1",
                sessionIncarnationID: "inc-1"
            )
            Issue.record("expected the queue-full failure to surface")
        } catch let error as KandevError {
            #expect(error == .queueFull(limit: 5))
        } catch {
            Issue.record("expected a KandevError, got \(error)")
        }
    }
}

// MARK: - Frames the client must refuse

/// The server always sends these fields, so a frame that omits one is a protocol
/// surprise. Decoding must throw: a half-built task or queue snapshot renders as
/// if it were real.
@Suite("A frame the client must refuse")
struct WireRefusalTests {
    @Test("a task without its id or its title is not a task")
    func taskRequiresIdentity() {
        #expect(refuses(KandevTask.self, #"{"title":"A title with no id"}"#))
        #expect(refuses(KandevTask.self, #"{"id":"t1"}"#))
    }

    /// `labels` is a JSON string, or an array, and nothing else. A number is the
    /// shape a server that changed its mind would send, and it must not quietly
    /// become an empty list.
    @Test("labels in a shape the server never sends are refused")
    func labelsAreStringOrArrayOnly() {
        #expect(refuses(KandevTask.self, #"{"id":"t1","title":"T","labels":3}"#))
    }

    @Test("a list container without its array or its total is refused")
    func listContainersRequireTheirContents() {
        #expect(refuses(KandevWorkspaceList.self, "{}"))
        #expect(refuses(KandevSessionList.self, "{}"))
        #expect(refuses(KandevTaskList.self, #"{"tasks":[]}"#))
        #expect(refuses(KandevTaskList.self, #"{"total":0}"#))
    }

    @Test("a message page without its has_more flag is refused")
    func messagePageRequiresHasMore() {
        #expect(refuses(KandevMessagePage.self, #"{"messages":[]}"#))
    }

    /// The trap this guards: the HTTP list spells the object `id`, the
    /// notification spells it `task_id`. Accepting one for the other would patch
    /// the wrong row, or none.
    @Test("a notification keyed by id rather than task_id is refused")
    func taskUpdateIsKeyedByTaskID() {
        #expect(refuses(KandevTaskUpdate.self, #"{"id":"t1"}"#))
    }

    @Test("a queue snapshot without its count or its entries is refused")
    func queueSnapshotRequiresCountAndEntries() {
        #expect(refuses(KandevQueueSnapshot.self, #"{"entries":[]}"#))
        #expect(refuses(KandevQueueSnapshot.self, #"{"count":0}"#))
    }

    @Test("a queued prompt without an id or content cannot be shown and is refused")
    func queuedPromptRequiresIdAndContent() {
        #expect(refuses(KandevQueuedPrompt.self, #"{"content":"hi"}"#))
        #expect(refuses(KandevQueuedPrompt.self, #"{"id":"q1"}"#))
    }

    @Test("a send-now result without its dispatch count is refused")
    func sendNowResultRequiresAllThree() {
        #expect(refuses(KandevSendNowResult.self, #"{"session_id":"s1"}"#))
        #expect(refuses(KandevSendNowResult.self, #"{"session_id":"s1","dispatched":true}"#))
    }

    @Test("a session launch with no session is not a launch")
    func launchRequiresASession() {
        #expect(refuses(KandevSessionLaunch.self, #"{"task_id":"t1"}"#))
    }

    @Test("a session state change names no session")
    func sessionStateChangeRequiresSession() {
        #expect(refuses(KandevSessionStateChange.self, #"{"task_id":"t1"}"#))
    }

    @Test("a conversation change with no operations list is refused")
    func conversationChangeRequiresOperations() {
        #expect(refuses(KandevConversationChange.self, #"{"revision":"1"}"#))
    }

    @Test("a conversation operation without its entity, id, or kind is refused")
    func conversationOperationRequiresItsThreeFields() {
        #expect(refuses(KandevConversationOperation.self, #"{"id":"m1","kind":"upsert"}"#))
        #expect(refuses(KandevConversationOperation.self, #"{"entity":"message","kind":"upsert"}"#))
        #expect(refuses(KandevConversationOperation.self, #"{"entity":"message","id":"m1"}"#))
    }
}

// MARK: - Frames the client must accept, even when they surprise it

/// The other half of tolerance: a value this client has never seen is a value to
/// render plainly, not a decode failure that loses the whole frame. These pin
/// the places where the model deliberately does not refuse.
@Suite("A frame the client must accept")
struct WireToleranceTests {
    @Test("labels arrive as a JSON string, as a real array, or as nonsense, and never lose the task")
    func labelShapes() throws {
        // The server sends the array with the quotes inside the string, so the
        // wire text is `"[\"a\",\"b\"]"`. Build it rather than fight escaping.
        let arrayInsideAString = String(decoding: try JSONEncoder().encode(#"["a","b"]"#), as: UTF8.self)
        #expect(try decode(KandevStringList.self, arrayInsideAString).values == ["a", "b"])

        // A real array is the other shape both sides accept.
        #expect(try decode(KandevStringList.self, #"["a","b"]"#).values == ["a", "b"])

        #expect(try decode(KandevStringList.self, #""not json""#).values == [])
        #expect(try decode(KandevStringList.self, #""""#).values == [])

        let literal: KandevStringList = ["a", "b"]
        #expect(literal.values == ["a", "b"])

        let encoded = try JSONEncoder().encode(KandevStringList(["a", "b"]))
        #expect(String(decoding: encoded, as: UTF8.self) == #"["a","b"]"#)
    }

    /// The nanosecond timestamp is kept raw, so a round trip must not lose digits
    /// to a formatter.
    @Test("a timestamp round-trips through its raw string")
    func timestampRoundTrip() throws {
        let stamp = KandevTimestamp(raw: "2026-10-04T18:07:04.074817797Z")

        let encoded = try JSONEncoder().encode(stamp)
        #expect(String(decoding: encoded, as: UTF8.self) == #""2026-10-04T18:07:04.074817797Z""#)

        let decoded = try JSONDecoder().decode(KandevTimestamp.self, from: encoded)
        #expect(decoded.raw == stamp.raw)
    }

    /// The queue limit arrives inside `details` as a number the server chose to
    /// type as a number or as a string. Either is a count.
    @Test("intValue reads a count however the server typed it")
    func intValue() {
        #expect(JSONValue.integer(5).intValue == 5)
        #expect(JSONValue.number(5.0).intValue == 5)
        #expect(JSONValue.number(5.4).intValue == 5)
        #expect(JSONValue.string("5").intValue == 5)

        #expect(JSONValue.string("five").intValue == nil)
        #expect(JSONValue.bool(true).intValue == nil)
        #expect(JSONValue.null.intValue == nil)
    }

    @Test("a search term travels as the server's query parameter, and an empty one does not")
    func searchParameter() {
        #expect(
            KandevTaskListQuery(search: "zenoh").queryItems
                .contains(URLQueryItem(name: "query", value: "zenoh"))
        )
        #expect(
            !KandevTaskListQuery(search: "").queryItems.contains { $0.name == "query" }
        )
    }

    @Test("a session waiting for input is not working")
    func idleSessionIsNotWorking() throws {
        let change = try decode(
            KandevSessionStateChange.self,
            #"{"session_id":"s1","new_state":"WAITING_FOR_INPUT"}"#
        )

        #expect(!change.isWorking)
    }

    /// The wire keeps the server's `type` verbatim, known or not, which is what lets
    /// the transcript decide what a row is without the wire having an opinion.
    @Test("a message keeps the server's raw type, known or not")
    func messageKeepsRawType() throws {
        let read = try decode(KandevMessage.self, #"{"id":"m1","type":"tool_read","content":"read"}"#)
        #expect(read.kind == .toolRead)
        #expect(read.type == "tool_read")

        let unseen = try decode(KandevMessage.self, #"{"id":"m2","type":"tool_frobnicate"}"#)
        #expect(unseen.kind == nil)
        #expect(unseen.type == "tool_frobnicate")
    }

    /// Same rule for a conversation op: the entity is a string so a new one is a
    /// value to judge in `decision`, not a lost change.
    @Test("a conversation entity this client has never seen still decodes")
    func unknownConversationEntityDecodes() throws {
        let operation = try decode(
            KandevConversationOperation.self,
            #"{"entity":"widget","id":"w1","kind":"upsert"}"#
        )

        #expect(operation.knownEntity == nil)
    }
}

// MARK: - HTTP routes

/// Part of the API is HTTP, and a route is only a path string until something
/// asks for it. A typo here is a 404 at runtime and nothing at compile time, so
/// the exact paths are pinned. These are also the routes nothing else exercises:
/// the stores call through a fake, so the real builders would otherwise be
/// unread.
@Suite("KandevHTTPRoute")
struct KandevHTTPRouteTests {
    @Test("the task list route names its workspace")
    func taskListPath() {
        #expect(KandevHTTPRoute.workspaceTasks(workspaceID: "w1") == "/api/v1/workspaces/w1/tasks")
    }

    @Test("the session list is HTTP, and names its task")
    func sessionsPath() {
        #expect(KandevHTTPRoute.taskSessions(taskID: "t1") == "/api/v1/tasks/t1/sessions")
    }

    @Test("a shell call's output lives under its session and message")
    func shellOutputPath() {
        #expect(
            KandevHTTPRoute.shellOutput(sessionID: "s1", messageID: "m1")
                == "/api/v1/task-sessions/s1/messages/m1/shell-output"
        )
    }

    @Test("a move preview and a commit are siblings")
    func movePaths() {
        #expect(KandevHTTPRoute.taskMove(taskID: "t1") == "/api/v1/tasks/t1/move")
        #expect(KandevHTTPRoute.taskMovePreview(taskID: "t1") == "/api/v1/tasks/t1/move-preview")
    }

    @Test("a board snapshot is per workflow")
    func snapshotPath() {
        #expect(KandevHTTPRoute.workflowSnapshot(workflowID: "wf1") == "/api/v1/workflows/wf1/snapshot")
    }

    @Test("archive and unarchive are separate paths, and delete is the task itself")
    func removalPaths() {
        #expect(KandevHTTPRoute.taskArchive(taskID: "t1") == "/api/v1/tasks/t1/archive")
        #expect(KandevHTTPRoute.taskUnarchive(taskID: "t1") == "/api/v1/tasks/t1/unarchive")
        #expect(KandevHTTPRoute.taskDelete(taskID: "t1") == "/api/v1/tasks/t1")
    }

    @Test("the fixed routes are the ones the server mounts")
    func fixedPaths() {
        #expect(KandevHTTPRoute.agents == "/api/v1/agents")
        #expect(KandevHTTPRoute.health == "/health")
        #expect(KandevHTTPRoute.features == "/api/v1/features")
    }
}

// MARK: - Failure phrasing

/// Every failure ends up in front of a person eventually, so every case needs a
/// sentence. `KandevFailureTests` covers the HTTP body and the two server shapes;
/// this covers the cases a store shows verbatim.
@Suite("A Kandev failure reads as a sentence")
struct KandevErrorPhrasingTests {
    @Test("every case has something to show")
    func everyCasePhrases() {
        let errors: [KandevError] = [
            .invalidBaseURL("http://"),
            .unsupportedScheme("ftp"),
            .notConnected,
            .connectionClosed,
            .timedOut(action: "task.get"),
            .missingRequestID,
            .malformedFrame("no payload"),
            .server(KandevErrorPayload(code: "NOT_FOUND", message: "no such task")),
            .action(KandevActionFailure(code: "invalid_request", message: "bad prompt")),
            .http(status: 500, body: nil),
            .queueFull(limit: 5),
        ]

        for error in errors {
            #expect(!(error.errorDescription ?? "").isEmpty, "\(error) has no sentence")
        }
    }

    @Test("the cases with their own words say them")
    func specificSentences() {
        #expect(KandevError.notConnected.errorDescription == "Not connected to a Kandev server.")
        #expect(
            KandevError.invalidBaseURL("http://")
                .errorDescription == "http:// is not a usable server address."
        )
        #expect(KandevError.timedOut(action: "task.get").errorDescription == "task.get did not answer in time.")
        #expect(
            KandevError.missingRequestID.errorDescription
                == "A request was sent without an id, so its response cannot be matched."
        )
    }

    @Test("an error from outside Kandev still has a readable message")
    func foreignError() {
        struct Boom: LocalizedError {
            var errorDescription: String? { "boom" }
        }

        #expect(KandevError.readableMessage(for: Boom()) == "boom")
    }
}
