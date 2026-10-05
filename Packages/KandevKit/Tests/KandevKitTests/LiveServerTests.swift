import Foundation
import Testing

@testable import KandevKit

/// Reads a real server. Off unless `KANDEV_LIVE` names one, so `swift test`
/// stays offline and deterministic:
///
///     make test-live
///
/// Everything here is a read. Nothing creates, starts, or stops anything.
@Suite(
    "Live server",
    .enabled(if: ProcessInfo.processInfo.environment["KANDEV_LIVE"] != nil)
)
struct LiveServerTests {
    private var client: KandevClient {
        KandevClient(
            baseURL: URL(string: ProcessInfo.processInfo.environment["KANDEV_LIVE"]!)!,
            token: ProcessInfo.processInfo.environment["KANDEV_TOKEN"]
        )
    }

    @Test("reads workspaces, then a flat task list with real payloads")
    func readsTaskList() async throws {
        let client = client
        try await client.connect()

        let workspaces = try await client.workspaces()
        let workspace = try #require(workspaces.first, "expected at least one workspace")
        #expect(!workspace.id.isEmpty)

        let page = try await client.tasks(
            workspaceID: workspace.id,
            query: .init(pageSize: 5, sort: .updatedDesc)
        )

        #expect(page.total >= page.tasks.count)
        #expect(!page.tasks.isEmpty, "expected tasks on the dev server")
        for task in page.tasks {
            #expect(!task.id.isEmpty)
            #expect(!task.title.isEmpty)
            // The row design depends on both of these being present per task.
            #expect(task.workflowStepID != nil)
            #expect(task.lastActivity != nil)
        }

        await client.close()
    }

    @Test("every task's step id resolves to a step name across its workspace's workflows")
    func stepNamesResolve() async throws {
        let client = client
        try await client.connect()

        let workspace = try #require(try await client.workspaces().first)
        let tasks = try await client.tasks(workspaceID: workspace.id, query: .init(pageSize: 100))
        let workflows = try await client.workflows(workspaceID: workspace.id)

        var stepNames: [String: String] = [:]
        for workflow in workflows {
            for step in try await client.workflowSteps(workflowID: workflow.id) {
                stepNames[step.id] = step.name
            }
        }

        let named = tasks.tasks.compactMap { task in
            task.workflowStepID.flatMap { stepNames[$0] }
        }
        #expect(
            named.count == tasks.tasks.count,
            "the step chip needs a name for every row, or it renders blank"
        )

        await client.close()
    }

    @Test("reads a task's sessions and its session transcript")
    func readsSessionsAndTranscript() async throws {
        let client = client
        try await client.connect()

        let workspace = try #require(try await client.workspaces().first)
        let tasks = try await client.tasks(workspaceID: workspace.id, query: .init(pageSize: 100))
        let withSession = try #require(
            tasks.tasks.first { ($0.sessionCount ?? 0) > 0 },
            "expected a task with at least one session"
        )

        let sessions = try await client.sessions(taskID: withSession.id)
        let session = try #require(sessions.first)
        #expect(!session.id.isEmpty)

        let page = try await client.messages(sessionID: session.id, limit: 5)
        #expect(page.messages.count <= 5)
        for message in page.messages {
            #expect(!message.id.isEmpty)
        }

        await client.close()
    }

    @Test("a rejected request surfaces as an error rather than an empty result")
    func rejectedRequestThrows() async throws {
        let client = client
        try await client.connect()

        await #expect(throws: (any Error).self) {
            _ = try await client.task(id: "00000000-0000-0000-0000-000000000000")
        }

        await client.close()
    }
}
