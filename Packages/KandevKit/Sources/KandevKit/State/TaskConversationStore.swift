import Foundation
import Observation

/// One task's conversation, read and written.
///
/// Owns the transcript and the composer, and — the reason it exists — the order
/// in which they are used. Sending a prompt then refetching the transcript is a
/// sequence, and a sequence spread across a view body cannot be tested. Here it
/// is one call.
@MainActor
@Observable
public final class TaskConversationStore {
    public let transcript: TranscriptStore
    public let composer: ComposerStore
    /// The task this screen is about, once loaded.
    public private(set) var taskID: String?
    /// What the server said this caller may do, which the composer obeys.
    public let permissions: ConversationPermissions
    /// The debounce in front of every automatic refresh. See `RefreshPolicy`.
    private var refreshPolicy = RefreshPolicy()
    /// The profiles that can be started on this task, once they have been asked
    /// for. Loaded on demand: a task that already has a session never needs them.
    public private(set) var startableProfiles: [KandevAgentProfile] = []
    public private(set) var isLoadingProfiles = false
    /// Set while an agent is being started, so a second tap cannot start another.
    public private(set) var isStartingSession = false
    public private(set) var sessionStartFailure: String?
    /// Whether a live subscription is running.
    public private(set) var isFollowing = false

    /// Whether the open session is working, from the session's own state changes.
    ///
    /// The task read at load goes stale the moment an agent starts — which is the
    /// ordinary case, because the person prompts from this screen — and nothing else
    /// here updates it. This is the direct signal the server sends as a session's state
    /// changes, and it is what the live tail, the fold's tense, and the composer's Stop
    /// button read.
    public private(set) var isWorking = false

    private let conversationServer: (any KandevLiveConversations)?
    private let sessionStarter: (any KandevSessionStarting)?
    private var follower: ConversationFollower?
    private var followTask: Task<Void, Never>?
    /// The session-state subscription, which is separate from the conversation one.
    private var stateWatchTask: Task<Void, Never>?
    /// The task subscription, which is how a rename reaches the title.
    private var taskWatchTask: Task<Void, Never>?
    /// The revision of the conversation log this screen has applied.
    ///
    /// Observable on purpose: it is where the live stream has got to, and a screen
    /// showing a conversation that is quietly behind is worth being able to see.
    public private(set) var appliedRevision: String?

    /// Where the conversation log stood when the subscription began. Every change
    /// says which revision it builds on, which is how a missed one is caught.
    private var appliedEpoch: String?

    public init(
        transcript: TranscriptStore,
        composer: ComposerStore,
        permissions: ConversationPermissions = .default,
        conversationServer: (any KandevLiveConversations)? = nil,
        sessionStarter: (any KandevSessionStarting)? = nil
    ) {
        self.transcript = transcript
        self.composer = composer
        self.permissions = permissions
        self.conversationServer = conversationServer
        self.sessionStarter = sessionStarter
    }

    public convenience init(
        transcriptSource: any KandevTranscriptSource,
        promptSource: any KandevPromptSource,
        steps: [String: KandevWorkflowStep] = [:],
        permissions: ConversationPermissions = .default,
        conversationServer: (any KandevLiveConversations)? = nil,
        sessionStarter: (any KandevSessionStarting)? = nil,
        initialDraft: String = ""
    ) {
        let composer = ComposerStore(source: promptSource)
        // A chat arrives here with the sentence that started it, the way the
        // first-party client pre-fills a chat's input: a prompt cannot be addressed
        // until the session record has been read, so the words wait in the field
        // rather than being sent into a session that does not exist yet.
        composer.draft = initialDraft
        self.init(
            transcript: TranscriptStore(source: transcriptSource, stepNames: steps.mapValues(\.name)),
            composer: composer,
            permissions: permissions,
            conversationServer: conversationServer,
            sessionStarter: sessionStarter
        )
    }

    // MARK: - Starting a session

    /// Whether starting an agent is both possible and permitted.
    public var canStartSession: Bool {
        sessionStarter != nil && !isStartingSession && permissions.canControlSessions
    }

    /// Asks for the profiles a session could be started with.
    ///
    /// Separate from starting, because the choice has to be shown before it can
    /// be made, and a list of profiles is not needed on a task that already runs.
    public func loadStartableProfiles() async {
        guard let sessionStarter, startableProfiles.isEmpty, !isLoadingProfiles else { return }
        isLoadingProfiles = true
        defer { isLoadingProfiles = false }
        do {
            startableProfiles = try await sessionStarter.agentProfiles()
        } catch {
            sessionStartFailure = KandevError.readableMessage(for: error)
        }
    }

    /// Starts an agent on this task and reloads, so the transcript and the
    /// composer both pick up the session that now exists.
    @discardableResult
    public func startSession(agentProfileID: String) async -> Bool {
        guard let sessionStarter, let taskID, canStartSession else { return false }
        isStartingSession = true
        sessionStartFailure = nil
        defer { isStartingSession = false }

        do {
            _ = try await sessionStarter.launchSession(
                taskID: taskID,
                agentProfileID: agentProfileID
            )
            // Reloading is what binds the composer and begins following: the
            // session's incarnation id only exists now that it has been launched.
            await load(taskID: taskID)
            return true
        } catch {
            sessionStartFailure = KandevError.readableMessage(for: error)
            return false
        }
    }

    // MARK: - Following

    /// Watches the open session so the transcript keeps up with the agent.
    ///
    /// Always moves to the session now open. It used to bail when a follower was
    /// already running, which meant a switch to another session kept delivering
    /// the one just left.
    ///
    /// Failure is not fatal: the screen still works, it just refetches rather
    /// than following. A subscription is an enhancement to a working screen, and
    /// putting an error in front of someone because a live update could not start
    /// would be the wrong trade.
    public func startFollowing() async {
        guard let server = conversationServer,
              let sessionID = transcript.selectedSessionID
        else {
            await stopFollowing()
            return
        }

        await stopFollowing()
        watchSessionState(server: server)
        watchTask(server: server)
        let follower = ConversationFollower(
            client: server,
            hub: server.hub,
            sessionID: sessionID
        )
        do {
            let (subscription, changes) = try await follower.start()
            self.follower = follower
            appliedEpoch = subscription.epoch
            appliedRevision = subscription.revision
            isFollowing = true
            followTask = Task { [weak self] in
                for await change in changes {
                    await self?.apply(change)
                }
            }
        } catch {
            isFollowing = false
        }
    }

    public func stopFollowing() async {
        followTask?.cancel()
        followTask = nil
        stateWatchTask?.cancel()
        stateWatchTask = nil
        taskWatchTask?.cancel()
        taskWatchTask = nil
        isFollowing = false
        appliedEpoch = nil
        appliedRevision = nil
        await follower?.stop()
        follower = nil
    }

    /// Follows the open session's state, which is how this screen learns an agent
    /// started: the task is read once at load, and a turn begun from this screen
    /// changes nothing about it.
    ///
    /// Independent of the conversation subscription on purpose. A subscription that
    /// failed leaves a screen that still works by refetching, and the state signal is
    /// true regardless.
    private func watchSessionState(server: any KandevLiveConversations) {
        let hub = server.hub
        stateWatchTask = Task { [weak self] in
            for await change in await hub.sessionStateChanges() {
                self?.applySessionState(change)
            }
        }
    }

    /// Applies one session's state to the screen, if it is the session on screen.
    ///
    /// Matched by session rather than by primary: the switcher can put a secondary
    /// session in front of the reader, and then its state is this screen's business.
    func applySessionState(_ change: KandevSessionStateChange) {
        guard change.sessionID == transcript.selectedSessionID else { return }
        isWorking = change.isWorking
    }

    /// Follows changes to this task, which is how a rename reaches the title.
    ///
    /// The server renames a task shortly after it is created — an agent replaces the provisional
    /// title taken from the first sentence — and the task is read once when the screen opens, so
    /// without this the screen keeps the name the work had for its first few seconds.
    private func watchTask(server: any KandevLiveConversations) {
        let hub = server.hub
        taskWatchTask = Task { [weak self] in
            for await signal in await hub.taskSignals() {
                self?.applyTaskSignal(signal)
            }
        }
    }

    /// Applies a change to the task this screen is about, and ignores every other.
    func applyTaskSignal(_ signal: KandevTaskSignal) {
        guard signal.update.taskID == taskID else { return }
        transcript.apply(signal.update)
    }

    func apply(_ change: KandevConversationChange) async {
        guard let follower, let sessionID = transcript.selectedSessionID else { return }

        switch change.decision(
            expectedScopeID: follower.scopeID,
            expectedSessionID: sessionID,
            appliedEpoch: appliedEpoch,
            appliedRevision: appliedRevision
        ) {
        case .ignore:
            return

        case .apply(let operations, let revision):
            for operation in operations {
                if let message = operation.message {
                    transcript.upsert(message)
                }
            }
            appliedRevision = revision

        case .refetch:
            // Resubscribe as well as refetch: after a gap, the revision the
            // stream is on is unknown, and only a fresh handshake can say.
            await stopFollowing()
            await reloadTranscript()
            await startFollowing()
        }
    }

    /// Loads the task, then points the composer at whichever session was chosen.
    public func load(taskID: String) async {
        self.taskID = taskID
        await transcript.load(taskID: taskID)
        // The state stream only reports changes, so the read that just happened is the
        // starting point: a task already running when it was opened must not look idle.
        isWorking = transcript.task?.isWorking ?? false
        await bindComposer()
        await startFollowing()
        refreshPolicy.record(at: Date())
    }

    /// Reads the conversation again, unless it was read moments ago.
    ///
    /// The follower's revision guard already catches a gap in the change stream, so
    /// this is for the other case: nothing changed while the app was away, and the
    /// screen is simply old.
    @discardableResult
    public func refreshIfDue(at now: Date = Date()) async -> Bool {
        guard refreshPolicy.isDue(at: now) else { return false }
        // Recorded by the read itself, and only when it succeeds: see the list store.
        await reloadTranscript()
        return true
    }

    /// Sends the draft and refetches, so the prompt appears without the user
    /// having to pull to refresh.
    @discardableResult
    public func send() async -> Bool {
        let sent = await composer.send()
        if sent { await reloadTranscript() }
        return sent
    }

    /// Interrupts the running turn for a queued prompt, then refetches.
    @discardableResult
    public func interruptAndSend(entryID: String? = nil) async -> Bool {
        let sent = await composer.interruptAndSend(entryID: entryID)
        if sent { await reloadTranscript() }
        return sent
    }

    /// Stops the running turn. Nothing to refetch: the transcript will show the
    /// turn ending when the server says so.
    @discardableResult
    public func stopTurn() async -> Bool {
        await composer.stopTurn()
    }

    @discardableResult
    public func clearQueue() async -> Bool {
        await composer.clearQueue()
    }

    /// Refetches the conversation without changing which session is open.
    public func reloadTranscript() async {
        refreshPolicy.record(at: Date())
        guard let sessionID = transcript.selectedSessionID else { return }
        await transcript.select(sessionID: sessionID, force: true)
        await composer.refreshQueue()
    }

    /// Refetches the queue only, for when the screen comes back into view.
    public func refreshQueue() async {
        await composer.refreshQueue()
    }

    /// Opens another session of this task.
    ///
    /// One sequence, because the transcript, the composer, and the subscription
    /// have to move together: the composer cannot speak to a session it does not
    /// hold the identity of, and a subscription left on the old session would
    /// deliver frames for a conversation no longer on screen. A screen that moved
    /// two of the three left the composer and the follower behind.
    ///
    /// Does nothing when the session is already open, or when loading it fails —
    /// in which case the old session stays whole rather than being torn down for
    /// one that never arrived.
    public func open(sessionID: String) async {
        guard sessionID != transcript.selectedSessionID else { return }
        await transcript.select(sessionID: sessionID)
        guard transcript.selectedSessionID == sessionID else { return }
        isWorking = transcript.task?.isWorking ?? false
        await bindComposer()
        await startFollowing()
    }

    private func bindComposer() async {
        guard let taskID, let session = transcript.selectedSession else {
            await composer.bind(nil, permissions: permissions)
            return
        }
        guard let incarnation = session.queueIncarnationID else {
            // Without an incarnation id a prompt cannot be addressed. Better to
            // disable the composer than to send something the server will reject.
            await composer.bind(nil, permissions: permissions)
            return
        }
        await composer.bind(
            ComposerStore.Identity(
                taskID: taskID,
                sessionID: session.id,
                sessionIncarnationID: incarnation
            ),
            permissions: permissions
        )
    }
}
