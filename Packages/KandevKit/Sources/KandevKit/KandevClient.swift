import Foundation

/// Everything this app knows how to ask a Kandev server for.
///
/// One type, two transports inside. The WebSocket carries requests and live
/// notifications; HTTP carries the list endpoints the socket does not serve.
/// Callers never choose, because *which transport* is an implementation fact of
/// the server, not a decision the UI should be making.
public struct KandevClient: Sendable {
    public let http: KandevHTTPClient
    /// The single reader of the notification stream.
    ///
    /// One per client, so every screen on one connection shares it. A second
    /// reader would silently split the stream between them.
    public let hub: KandevNotificationHub
    private let transport: any KandevTransport

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        let configuration = WebSocketTransport.Configuration(baseURL: baseURL, token: token)
        let transport = WebSocketTransport(configuration: configuration, session: session)
        self.transport = transport
        self.http = KandevHTTPClient(
            configuration: .init(baseURL: baseURL, token: token),
            session: session
        )
        self.hub = KandevNotificationHub(source: TransportNotifications(transport: transport))
    }

    /// For tests, and for driving the client against recorded frames.
    public init(transport: any KandevTransport, http: KandevHTTPClient) {
        self.transport = transport
        self.http = http
        self.hub = KandevNotificationHub(source: TransportNotifications(transport: transport))
    }

    /// Prefer the hub. This is for a caller that genuinely wants raw frames and
    /// promises to be the only reader.
    public var notifications: AsyncStream<KandevEnvelope> { transport.notifications }

    public func connect() async throws {
        try await transport.connect()
        // Started after the socket is up so no frame is read before the hub is
        // ready to hold it.
        await hub.start()
    }

    public func close() async {
        await hub.stop()
        await transport.close()
    }

    // MARK: - Board

    public func workspaces() async throws -> [KandevWorkspace] {
        try await request(KandevAction.workspaceList, as: KandevWorkspaceList.self).workspaces
    }

    public func workflows(workspaceID: String) async throws -> [KandevWorkflow] {
        try await request(
            KandevAction.workflowList,
            payload: .object(["workspace_id": .string(workspaceID)]),
            as: KandevWorkflowList.self
        ).workflows
    }

    public func workflowSteps(workflowID: String) async throws -> [KandevWorkflowStep] {
        try await request(
            KandevAction.workflowStepList,
            payload: .object(["workflow_id": .string(workflowID)]),
            as: KandevWorkflowStepList.self
        ).steps
    }

    /// The flat task list: every task in a workspace, across every workflow.
    ///
    /// One HTTP request, not one per workflow. The server returns each task's
    /// full description whether or not it is wanted, so keep the page small.
    public func tasks(
        workspaceID: String,
        query: KandevTaskListQuery = .init()
    ) async throws -> KandevTaskList {
        try await http.get(
            KandevHTTPRoute.workspaceTasks(workspaceID: workspaceID),
            query: query.queryItems,
            as: KandevTaskList.self
        )
    }

    // MARK: - One task

    public func task(id: String) async throws -> KandevTask {
        try await request(
            KandevAction.taskGet,
            payload: .object(["id": .string(id)]),
            as: KandevTask.self
        )
    }

    /// Creates a task. The response is the task itself, so the caller can go
    /// straight to it rather than refetching the list to find it.
    public func createTask(_ draft: KandevTaskDraft) async throws -> KandevTask {
        try await request(
            KandevAction.taskCreate,
            payload: draft.payload,
            as: KandevTask.self
        )
    }

    /// Starts a chat, which the server answers with the task and the session it
    /// made.
    ///
    /// Two requests for one object, because the server has two routes for it: a
    /// chat is created with a session already attached, unlike a task, which is
    /// created empty and launched later. The repositories are left off rather than
    /// sent empty, so the workspace's own are used.
    public func startChat(
        kind: KandevChatKind,
        workspaceID: String,
        agentProfileID: String,
        title: String?,
        repositories: [String]
    ) async throws -> KandevChat {
        var members: [String: JSONValue] = ["agent_profile_id": .string(agentProfileID)]
        if let title, !title.isEmpty { members["title"] = .string(title) }
        if !repositories.isEmpty {
            members["repositories"] = .array(repositories.map { .string($0) })
        }
        return try await http.post(
            kind.route(workspaceID),
            body: .object(members),
            as: KandevChat.self
        )
    }

    public func repositories(workspaceID: String) async throws -> [KandevRepository] {
        try await http.get(
            KandevHTTPRoute.workspaceRepositories(workspaceID: workspaceID),
            as: KandevRepositoryList.self
        ).repositories
    }

    public func sessions(taskID: String) async throws -> [KandevSession] {
        try await http.get(
            KandevHTTPRoute.taskSessions(taskID: taskID),
            as: KandevSessionList.self
        ).sessions
    }

    /// One shell tool call's full output.
    ///
    /// Fetched rather than listed: the body is left out of every message payload because it
    /// can run to a quarter of a megabyte, and only a reader who opens the disclosure wants
    /// it. A running command is polled by the caller; this is one snapshot.
    public func shellOutput(sessionID: String, messageID: String) async throws -> KandevShellOutput {
        try await http.get(
            KandevHTTPRoute.shellOutput(sessionID: sessionID, messageID: messageID),
            as: KandevShellOutput.self
        )
    }

    // MARK: - A conversation

    public func messages(
        sessionID: String,
        limit: Int? = nil,
        before: String? = nil
    ) async throws -> KandevMessagePage {
        var payload: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let limit { payload["limit"] = .integer(limit) }
        if let before { payload["before"] = .string(before) }
        return try await request(
            KandevAction.messageList,
            payload: .object(payload),
            as: KandevMessagePage.self
        )
    }

    /// Stops the active turn in a session. The session itself survives; this
    /// cancels the work, not the conversation.
    public func stopTurn(sessionID: String) async throws {
        _ = try await transport.send(
            .request(
                action: KandevAction.sessionStop,
                payload: .object(["session_id": .string(sessionID)])
            )
        )
    }

    /// Starts an agent on a task.
    public func launchSession(
        taskID: String,
        agentProfileID: String
    ) async throws -> KandevSessionLaunch {
        try await request(
            KandevAction.sessionLaunch,
            payload: .object([
                "task_id": .string(taskID),
                "agent_profile_id": .string(agentProfileID),
            ]),
            as: KandevSessionLaunch.self
        )
    }

    /// Sends a prompt to a session.
    ///
    /// This *enqueues*. The server's queue dispatches it when it can — on a live
    /// server `auto_run` was true, so prompt, dispatch, and reply all happened
    /// without a second call — but the only thing this method promises is that
    /// the prompt is in the queue.
    ///
    /// `sessionIncarnationID` is `KandevSession.queueIncarnationID`, which is why
    /// the caller has to hold the session before it can speak to it.
    public func sendPrompt(
        _ content: String,
        sessionID: String,
        taskID: String,
        sessionIncarnationID: String,
        clientQueueID: String? = nil
    ) async throws -> KandevQueuedPrompt {
        var payload: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "task_id": .string(taskID),
            "session_incarnation_id": .string(sessionIncarnationID),
            "content": .string(content),
        ]
        // Naming the prompt makes a retry safe: the server can recognise the
        // duplicate rather than queue the same prompt twice.
        if let clientQueueID { payload["client_queue_id"] = .string(clientQueueID) }

        do {
            return try await request(
                KandevAction.messageQueueAdd,
                payload: .object(payload),
                as: KandevQueuedPrompt.self
            )
        } catch let error as KandevError {
            throw KandevQueueFailure.translate(error)
        }
    }

    /// Interrupts the turn that is running and sends a queue selection.
    ///
    /// This cancels the agent's current work, which is why it is a separate call
    /// from sending. `entryID` names one queued prompt; passing `nil` sends all.
    public func sendQueuedNow(
        sessionID: String,
        taskID: String,
        sessionIncarnationID: String,
        entryID: String? = nil
    ) async throws -> KandevSendNowResult {
        var payload: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "task_id": .string(taskID),
            "session_incarnation_id": .string(sessionIncarnationID),
            "scope": .string(entryID == nil ? "all" : "entry"),
        ]
        if let entryID { payload["entry_id"] = .string(entryID) }

        return try await request(
            KandevAction.messageQueueSendNow,
            payload: .object(payload),
            as: KandevSendNowResult.self
        )
    }

    /// Drops every pending prompt for a session.
    public func clearQueue(
        sessionID: String,
        taskID: String,
        sessionIncarnationID: String
    ) async throws {
        _ = try await transport.send(
            .request(
                action: KandevAction.messageQueueCancel,
                payload: .object([
                    "session_id": .string(sessionID),
                    "task_id": .string(taskID),
                    "session_incarnation_id": .string(sessionIncarnationID),
                ])
            )
        )
    }



    /// Every agent profile this server can run.
    ///
    /// HTTP, not the socket: the profile catalogue is not a `/ws` action.
    /// Flattened from its runtimes, because which agent to run is one choice.
    public func agentProfiles() async throws -> [KandevAgentProfile] {
        try await http.get(KandevHTTPRoute.agents, as: KandevAgentCatalogue.self)
            .selectableProfiles
    }

    /// What a move would do, before doing it.
    public func previewMove(
        taskID: String,
        toWorkflowID: String,
        stepID: String
    ) async throws -> KandevTaskMovePreview {
        try await http.post(
            KandevHTTPRoute.taskMovePreview(taskID: taskID),
            body: Self.movePayload(workflowID: toWorkflowID, stepID: stepID),
            as: KandevTaskMovePreview.self
        )
    }

    /// Moves a task to a step.
    ///
    /// `workflow_id` is required as well as the step, because the two can belong
    /// to different workflows: a move can cross from one workflow to another.
    ///
    /// The answer is not read. What the task looks like afterwards is the
    /// server's to say, and the caller refetches rather than trusting a copy
    /// assembled from a response nobody modelled.
    public func moveTask(taskID: String, toWorkflowID: String, stepID: String) async throws {
        try await http.post(
            KandevHTTPRoute.taskMove(taskID: taskID),
            body: Self.movePayload(workflowID: toWorkflowID, stepID: stepID)
        )
    }

    private static func movePayload(workflowID: String, stepID: String) -> JSONValue {
        .object([
            "workflow_id": .string(workflowID),
            "workflow_step_id": .string(stepID),
        ])
    }

    /// Takes a task off the active board.
    public func archiveTask(id: String, cascadeSubTasks: Bool = false) async throws {
        try await http.post(
            KandevHTTPRoute.taskArchive(taskID: id),
            query: cascadeSubTasks ? [URLQueryItem(name: "cascade", value: "true")] : []
        )
    }

    /// Puts an archived task back on the board.
    public func unarchiveTask(id: String) async throws {
        try await http.post(KandevHTTPRoute.taskUnarchive(taskID: id), query: [])
    }

    /// Deletes a task.
    ///
    /// Refused with `task_delete_dirty_worktree` when a worktree holds
    /// uncommitted work, unless discarding it is asked for explicitly.
    public func deleteTask(
        id: String,
        cascadeSubTasks: Bool = false,
        discardWorktreeChanges: Bool = false
    ) async throws {
        var query: [URLQueryItem] = []
        if cascadeSubTasks { query.append(URLQueryItem(name: "cascade", value: "true")) }
        if discardWorktreeChanges {
            query.append(URLQueryItem(name: "discard_worktree_changes", value: "true"))
        }
        try await http.delete(KandevHTTPRoute.taskDelete(taskID: id), query: query)
    }

    /// Watches a session's conversation.
    ///
    /// The answer is a handshake: the conversation log's `epoch` and the
    /// `revision` it stood at. Later changes report which revision they build on,
    /// so a missed one can be detected rather than silently skipped.
    public func subscribeToConversation(
        sessionID: String,
        scopeID: String
    ) async throws -> KandevConversationSubscription {
        try await request(
            KandevAction.sessionConversationSubscribe,
            payload: .object([
                "session_id": .string(sessionID),
                "scope_id": .string(scopeID),
                "consumer_kind": .string("core"),
            ]),
            as: KandevConversationSubscription.self
        )
    }

    /// Stops watching.
    public func unsubscribeFromConversation(sessionID: String, scopeID: String) async throws {
        _ = try await transport.send(
            .request(
                action: KandevAction.sessionConversationUnsubscribe,
                payload: .object([
                    "session_id": .string(sessionID),
                    "scope_id": .string(scopeID),
                ])
            )
        )
    }

    /// What is waiting in a session's queue.
    public func queue(
        sessionID: String,
        taskID: String,
        sessionIncarnationID: String
    ) async throws -> KandevQueueSnapshot {
        try await request(
            KandevAction.messageQueueGet,
            payload: .object([
                "session_id": .string(sessionID),
                "task_id": .string(taskID),
                "session_incarnation_id": .string(sessionIncarnationID),
            ]),
            as: KandevQueueSnapshot.self
        )
    }

    // MARK: - Plumbing

    private func request<Response: Decodable>(
        _ action: String,
        payload: JSONValue? = nil,
        as type: Response.Type
    ) async throws -> Response {
        let envelope = try await transport.send(.request(action: action, payload: payload))
        guard let payload = envelope.payload else {
            throw KandevError.malformedFrame("\(action) answered without a payload")
        }
        do {
            return try payload.decoded(as: Response.self)
        } catch {
            throw KandevError.malformedFrame("\(action) did not match \(Response.self): \(error)")
        }
    }
}


/// The transport's notifications, shaped as the hub's source.
private struct TransportNotifications: KandevNotificationHub.Source {
    let transport: any KandevTransport
    var notifications: AsyncStream<KandevEnvelope> { transport.notifications }
}
