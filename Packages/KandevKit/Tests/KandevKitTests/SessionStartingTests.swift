import Foundation
import Testing

@testable import KandevKit

/// The agent catalogue, and starting a session with one of its profiles.
///
/// The runtime in `realRuntime` is the live server's own response, flattened for
/// length. The filtering cases below it are written by hand, and say so.
@Suite("KandevAgentCatalogue")
struct KandevAgentCatalogueTests {
    private let realRuntime = #"""
{
  "capability_status": "ok",
  "created_at": "2026-08-02T15:02:14.946786936Z",
  "id": "eaedef95-08f1-478d-a035-bd8478201fba",
  "inference_capable": true,
  "name": "pi-acp",
  "profiles": [
    {
      "agent_display_name": "Pi",
      "agent_id": "eaedef95-08f1-478d-a035-bd8478201fba",
      "allow_indexing": false,
      "auto_approve": true,
      "auto_fallback": false,
      "billing_type": "api_key",
      "cli_flags": [],
      "cli_passthrough": false,
      "created_at": "2026-10-04T01:24:57.197942258Z",
      "cursor_mcp_auth_enabled": true,
      "enabled": true,
      "id": "e689b9e3-89f7-4afa-919a-fb60f589e1ab",
      "kind": "concrete",
      "model": "opencode-go/deepseek-flash",
      "name": "ocg/kandev/deepseek-v4.1-flash",
      "provider_supported": false,
      "require_exact_model": false,
      "updated_at": "2026-10-04T01:25:15.059810534Z",
      "user_modified": true
    },
    {
      "agent_display_name": "Pi",
      "agent_id": "eaedef95-08f1-478d-a035-bd8478201fba",
      "allow_indexing": false,
      "auto_approve": false,
      "auto_fallback": false,
      "billing_type": "api_key",
      "cli_flags": [],
      "cli_passthrough": false,
      "created_at": "2026-09-24T01:16:32.20962296Z",
      "cursor_mcp_auth_enabled": true,
      "enabled": true,
      "id": "eca1058b-3db7-4cd4-85e1-bcbfdc23c0a3",
      "kind": "concrete",
      "mode": "high",
      "model": "umans/umans-mimo-v2.6-pro-lab",
      "name": "umans lab",
      "provider_supported": false,
      "require_exact_model": false,
      "updated_at": "2026-09-24T01:16:50.747564811Z",
      "user_modified": true
    },
    {
      "agent_display_name": "Pi",
      "agent_id": "eaedef95-08f1-478d-a035-bd8478201fba",
      "allow_indexing": false,
      "auto_approve": false,
      "auto_fallback": false,
      "billing_type": "api_key",
      "cli_flags": [],
      "cli_passthrough": false,
      "created_at": "2026-08-02T15:02:14.947130563Z",
      "cursor_mcp_auth_enabled": true,
      "enabled": true,
      "id": "da2ebe0d-2df5-4d75-ab3f-15e12dfd3759",
      "kind": "concrete",
      "mode": "high",
      "model": "umans/umans-deepseek-v4.1-flash",
      "name": "umans/Umans DeepSeek V4.1 Flash",
      "provider_supported": false,
      "require_exact_model": false,
      "updated_at": "2026-09-24T06:58:57.023236474Z",
      "user_modified": true
    }
  ],
  "supports_mcp": true,
  "updated_at": "2026-08-02T15:02:14.946786936Z"
}
"""#

    private func catalogue(_ json: String) throws -> KandevAgentCatalogue {
        try JSONDecoder().decode(KandevAgentCatalogue.self, from: Data(json.utf8))
    }

    @Test("decodes a runtime from the server's own response")
    func decodesRealRuntime() throws {
        let decoded = try JSONDecoder().decode(KandevAgentRuntime.self, from: Data(realRuntime.utf8))

        #expect(decoded.name == "pi-acp")
        #expect(decoded.inferenceCapable == true)
        #expect(decoded.profiles.count == 3)

        let profile = try #require(decoded.profiles.first)
        #expect(profile.agentID == decoded.id)
        #expect(profile.enabled == true)
        #expect(profile.model?.isEmpty == false)
    }

    @Test("flattens runtimes into one list of profiles")
    func flattensProfiles() throws {
        let decoded = try catalogue(
            #"""
            {"total": 2, "agents": [
              {"id": "a1", "name": "pi-acp", "inference_capable": true, "profiles": [
                {"id": "p1", "name": "worker", "enabled": true},
                {"id": "p2", "name": "reviewer", "enabled": true}
              ]},
              {"id": "a2", "name": "opencode-acp", "inference_capable": true, "profiles": [
                {"id": "p3", "name": "deepseek", "enabled": true}
              ]}
            ]}
            """#
        )

        #expect(decoded.selectableProfiles.map(\.id) == ["p1", "p2", "p3"])
    }

    /// A disabled profile is present and useless: the server would refuse it, so
    /// offering it would promise something that cannot happen.
    @Test("leaves out profiles that are disabled")
    func filtersDisabledProfiles() throws {
        let decoded = try catalogue(
            #"""
            {"agents": [{"id": "a1", "name": "pi-acp", "inference_capable": true, "profiles": [
              {"id": "on", "name": "On", "enabled": true},
              {"id": "off", "name": "Off", "enabled": false},
              {"id": "unstated", "name": "Unstated"}
            ]}]}
            """#
        )

        #expect(decoded.selectableProfiles.map(\.id) == ["on"])
    }

    /// The `dynamic` runtime is a routing placeholder with no profiles, so it is
    /// left out. A profile whose model the runtime does not confirm is **kept**,
    /// and marked: hiding it told people they had no agent set up when they did.
    @Test("leaves out runtimes that cannot be the author of a conversation")
    func filtersUnusableRuntimes() throws {
        let decoded = try catalogue(
            #"""
            {"agents": [
              {"id": "dynamic", "name": "dynamic", "inference_capable": false, "profiles": [
                {"id": "ignored", "name": "Ignored", "enabled": true}
              ]},
              {"id": "a1", "name": "pi-acp", "inference_capable": true, "profiles": [
                {"id": "unsupported", "name": "Unsupported", "enabled": true, "provider_supported": false},
                {"id": "fine", "name": "Fine", "enabled": true, "provider_supported": true}
              ]}
            ]}
            """#
        )

        #expect(decoded.selectableProfiles.map(\.id) == ["unsupported", "fine"])
        let unconfirmed = decoded.selectableProfiles.filter(\.isUnconfirmed)
        #expect(unconfirmed.map(\.id) == ["unsupported"], "and marked as uncertain")
    }

    @Test("takes the runtime's name when a profile does not carry one")
    func fillsInRuntimeName() throws {
        let decoded = try catalogue(
            #"""
            {"agents": [{"id": "a1", "name": "pi-acp", "inference_capable": true, "profiles": [
              {"id": "p1", "name": "worker", "enabled": true}
            ]}]}
            """#
        )

        #expect(decoded.selectableProfiles.first?.agentDisplayName == "pi-acp")
    }

    @Test("falls back to the model, then the id, when a profile has no usable name")
    func profileDisplayNameFallsBack() {
        let named = KandevAgentProfile(id: "p1", name: "  ", model: "openai/gpt")
        #expect(named.displayName == "openai/gpt")

        let anonymous = KandevAgentProfile(id: "abcdef1234", name: "")
        #expect(anonymous.displayName == "abcdef12")
    }
}

/// A session starter with no server behind it.
actor StubSessionStarter: KandevSessionStarting {
    var profiles: [KandevAgentProfile] = []
    var launchResult: Result<KandevSessionLaunch, any Error> = .success(
        KandevSessionLaunch(success: true, sessionID: "s-new", taskID: "t1", state: "STARTING")
    )
    private(set) var launchedProfiles: [String] = []
    private(set) var profileRequests = 0
    var profileFailure: (any Error)?

    func setProfiles(_ profiles: [KandevAgentProfile]) { self.profiles = profiles }
    func failLaunch(with error: any Error) { launchResult = .failure(error) }
    func failProfiles(with error: any Error) { profileFailure = error }

    func agentProfiles() async throws -> [KandevAgentProfile] {
        profileRequests += 1
        if let profileFailure { throw profileFailure }
        return profiles
    }

    func launchSession(taskID: String, agentProfileID: String) async throws -> KandevSessionLaunch {
        launchedProfiles.append(agentProfileID)
        return try launchResult.get()
    }
}

@MainActor
@Suite("TaskConversationStore starting a session")
struct SessionStartingTests {
    private func store(
        sessions: [KandevSession],
        permissions: ConversationPermissions = .default
    ) async -> (TaskConversationStore, StubSessionStarter, StubTranscriptSource) {
        let transcriptSource = StubTranscriptSource(
            task: .success(KandevTask(id: "t1", title: "A task", sessionCount: sessions.count)),
            sessions: .success(sessions),
            messages: ["s1": []]
        )
        let starter = StubSessionStarter()
        await starter.setProfiles([
            KandevAgentProfile(id: "p1", name: "worker", model: "deepseek", enabled: true),
            KandevAgentProfile(id: "p2", name: "reviewer", model: "opus", enabled: true),
        ])
        let store = TaskConversationStore(
            transcriptSource: transcriptSource,
            promptSource: StubPromptSource(),
            permissions: permissions,
            sessionStarter: starter
        )
        return (store, starter, transcriptSource)
    }

    @Test("a task with no session offers the profiles that could run it")
    func offersProfiles() async {
        let (store, starter, _) = await store(sessions: [])
        await store.load(taskID: "t1")
        #expect(store.transcript.hasNoSession)

        await store.loadStartableProfiles()

        #expect(store.startableProfiles.map(\.id) == ["p1", "p2"])
        #expect(store.canStartSession)
        let requests = await starter.profileRequests
        #expect(requests == 1)
    }

    @Test("asking twice does not refetch a list it already has")
    func profilesAreLoadedOnce() async {
        let (store, starter, _) = await store(sessions: [])
        await store.load(taskID: "t1")

        await store.loadStartableProfiles()
        await store.loadStartableProfiles()

        let requests = await starter.profileRequests
        #expect(requests == 1)
    }

    /// Starting an agent is a write with a cost, so it must take a stronger right
    /// than reading.
    @Test("starting is refused without permission to control sessions")
    func refusesWithoutPermission() async {
        let readOnly = ConversationPermissions(canPrompt: true, canControlSessions: false)
        let (store, starter, _) = await store(sessions: [], permissions: readOnly)
        await store.load(taskID: "t1")

        #expect(store.canStartSession == false)
        #expect(await store.startSession(agentProfileID: "p1") == false)
        let launched = await starter.launchedProfiles
        #expect(launched.isEmpty)
    }

    @Test("starting launches the chosen profile and reloads the task")
    func startsAndReloads() async {
        let (store, starter, transcriptSource) = await store(sessions: [])
        await store.load(taskID: "t1")
        let readsBefore = await transcriptSource.requestedSessions.count

        // The server now has a session for the task.
        await transcriptSource.setSessions([
            KandevSession(
                id: "s-new",
                taskID: "t1",
                name: "worker",
                state: "STARTING",
                isPrimary: true,
                queueIncarnationID: "inc-new"
            )
        ])
        await transcriptSource.setMessages([], forSession: "s-new")

        let started = await store.startSession(agentProfileID: "p2")

        #expect(started)
        let launched = await starter.launchedProfiles
        #expect(launched == ["p2"])
        #expect(store.transcript.hasNoSession == false)
        // And the composer can now speak to the session that exists.
        #expect(store.composer.identity?.sessionID == "s-new")
        #expect(store.composer.identity?.sessionIncarnationID == "inc-new")
        let readsAfter = await transcriptSource.requestedSessions.count
        #expect(readsAfter > readsBefore, "a started session has to be read back")
    }

    @Test("a launch the server refuses is reported and changes nothing")
    func refusedLaunchIsReported() async {
        let (store, starter, _) = await store(sessions: [])
        await store.load(taskID: "t1")
        await starter.failLaunch(
            with: KandevError.action(
                KandevActionFailure(code: "profile_not_found", message: "no such profile")
            )
        )

        let started = await store.startSession(agentProfileID: "p2")

        #expect(started == false)
        #expect(store.sessionStartFailure == "no such profile")
        #expect(store.transcript.hasNoSession, "the task still has no session")
    }

    @Test("a failed profile list is reported without hiding the task")
    func failedProfileListIsReported() async {
        let (store, starter, _) = await store(sessions: [])
        await store.load(taskID: "t1")
        await starter.failProfiles(with: KandevError.connectionClosed)

        await store.loadStartableProfiles()

        #expect(store.startableProfiles.isEmpty)
        #expect(store.sessionStartFailure != nil)
        #expect(store.transcript.hasNoSession, "the task is still shown as it is")
    }
}
