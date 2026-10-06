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

    /// Walking a conversation backwards with the cursor the server hands out.
    ///
    /// The transcript holds one page and opens at its tail, so this is the only way to the rest of
    /// it — and the cursor is the part that has to be right. The server answers with the oldest id
    /// in the page, and that id is what the next request asks to come before; an ISO timestamp in
    /// that field is refused outright, which is how the field was identified in the first place.
    ///
    /// Two claims, because they fail differently. Paging *k* times has to give the same window as
    /// reading one page of *k* times the size — that is the cursor being used correctly. And a walk
    /// to the end has to terminate, without repeating a message — that is `hasMore` and the cursor
    /// staying in step, and the failure mode is an "Earlier messages" row that never goes away.
    @Test("paging backwards gives the same window as one big page, and walks to the end")
    func pagesBackThroughAConversation() async throws {
        let client = client
        try await client.connect()
        defer { Task { await client.close() } }

        let workspace = try #require(try await client.workspaces().first)
        let tasks = try await client.tasks(
            workspaceID: workspace.id,
            query: .init(pageSize: 100, includeEphemeral: true)
        )

        // The conversation with the most in it, so the walk really has more than one page in it.
        // `limit` here is a hint, not a demand: the server caps a page, so this is a floor.
        var longest: (sessionID: String, count: Int)?
        for task in tasks.tasks {
            guard let sessionID = task.primarySessionID else { continue }
            let page = try await client.messages(sessionID: sessionID, limit: 100)
            if page.messages.count > (longest?.count ?? 0) {
                longest = (sessionID, page.messages.count)
            }
        }
        let session = try #require(longest, "expected at least one session on the server")
        try #require(session.count > 20, "expected a conversation longer than one page to page through")

        let small = 5
        let pages = 4

        // Four pages of five, oldest at the front.
        var walked: [KandevMessage] = []
        var cursor: String?
        for _ in 0..<pages {
            let page = try await client.messages(sessionID: session.sessionID, limit: small, before: cursor)
            walked.insert(contentsOf: page.messages, at: 0)
            // The store falls back to the oldest message on screen when a page answers without a
            // cursor. It has never had to, and this is where that would show.
            cursor = try #require(page.cursor, "every page should name the id to go before next")
        }

        let onePage = try await client.messages(sessionID: session.sessionID, limit: small * pages)
        #expect(walked.map(\.id) == onePage.messages.map(\.id))

        // And the same window is in reading order, which is what the client's reversal is for: the
        // wire hands the newest page back first, and a page that came back descending would show.
        let stamps = walked.compactMap { $0.createdAt?.date }
        #expect(stamps == stamps.sorted(), "expected oldest-first within a page")

        // Now all the way to the beginning, watching for a walk that repeats itself or never ends.
        // A fresh set and a fresh cursor: this is the whole conversation again, not a continuation
        // of the four pages above, and seeding it with those would report them as repeats.
        var seen = Set<String>()
        cursor = nil
        var steps = 0
        while steps < 500 {
            let page = try await client.messages(sessionID: session.sessionID, limit: small, before: cursor)
            let fresh = page.messages.filter { seen.insert($0.id).inserted }
            #expect(fresh.count == page.messages.count, "a page repeated messages already read")
            cursor = page.cursor ?? page.messages.first?.id
            steps += 1
            if !page.hasMore { break }
        }
        #expect(steps < 500, "the walk never reached the beginning")
        print("PAGED \(seen.count) messages in \(steps) pages of \(small)")
    }
}
