import Foundation
import Testing

@testable import KandevKit

/// Decoding is checked against payloads a live v0.96.0 server actually sent.
/// Trimmed for size; no field names or shapes were invented.
@Suite("Kandev payloads")
struct KandevPayloadTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test("decodes a task from the flat list, where labels are a JSON string")
    func decodesTaskFromFlatList() throws {
        let task = try decode(KandevTask.self, #"""
        {
          "id": "a1affafa-5ff8-4d58-8e16-87624732748f",
          "title": "Implement embedded Zenoh transport",
          "description": "Implement the changes described in the GitHub issue.",
          "state": "REVIEW",
          "priority": "medium",
          "origin": "manual",
          "labels": "[]",
          "position": 0,
          "session_count": 1,
          "active_subagent_count": 0,
          "workflow_id": "f1f1e633-dba3-44ea-bf34-af9232665cb0",
          "workflow_step_id": "48e4391e-be40-4293-9fdb-b241a5c9d794",
          "workspace_id": "faf4dd26-22b5-4c6e-ae6a-d0130eb9ea10",
          "primary_session_id": "245683ee-3447-49f7-8e0c-120b7b667675",
          "primary_session_state": "WAITING_FOR_INPUT",
          "updated_at": "2026-10-04T18:07:04.074817797Z",
          "repositories": [
            {"id": "671f0f51-3e07-44d5-90da-6b5acff9559e",
             "repository_id": "4a7bd408-2ed6-47c5-aa60-fc1a2d0b1391",
             "base_branch": "main"}
          ],
          "status_summary": {
            "revision": 826,
            "updated_at": "2026-10-04T18:07:04.085790983Z",
            "last_activity_at": "2026-10-04T18:07:04.074817797Z",
            "primary_session": {"id": "245683ee-3447-49f7-8e0c-120b7b667675", "state": "WAITING_FOR_INPUT"},
            "git": {"behind": 18}
          }
        }
        """#)

        #expect(task.state == "REVIEW")
        #expect(task.labels?.values == [])
        #expect(task.sessionCount == 1)
        #expect(task.repositories?.first?.baseBranch == "main")
        #expect(task.statusSummary?.git?.behind == 18)
        #expect(task.lastActivity?.date != nil)
        #expect(task.isWorking == false)
    }

    /// The trap this guards: a task in `REVIEW` whose session is still running is
    /// ordinary, and the two fields must not be conflated.
    @Test("a task can be in review while its session is generating")
    func reviewTaskCanBeWorking() throws {
        let task = try decode(KandevTask.self, #"""
        {"id":"t","title":"T","state":"REVIEW","primary_session_state":"RUNNING","foreground_activity":"generating"}
        """#)

        #expect(task.state == "REVIEW")
        #expect(task.isWorking)
        #expect(task.lastActivity == nil)
    }

    @Test("accepts labels as a real array too, because both shapes occur")
    func acceptsLabelArray() throws {
        let task = try decode(KandevTask.self, #"{"id":"t","title":"T","labels":["urgent","docs"]}"#)

        #expect(task.labels?.values == ["urgent", "docs"])
    }

    /// A real server sent 79KB for one session, so the model only keeps the
    /// shallow fields and leaves the rest alone.
    @Test("decodes a session without being disturbed by its huge metadata")
    func decodesSession() throws {
        let session = try decode(KandevSession.self, #"""
        {
          "id": "245683ee-3447-49f7-8e0c-120b7b667675",
          "task_id": "a1affafa-5ff8-4d58-8e16-87624732748f",
          "name": "",
          "state": "WAITING_FOR_INPUT",
          "is_primary": true,
          "worktree_branch": "feature/implement-embedded-z-bf5",
          "command_count": 0,
          "last_read_message_id": "9d96c921-5fec-4d04-8c45-1140f587f736",
          "started_at": "2026-10-04T12:36:21.295981357Z",
          "metadata": {"acp": {"session_id": "abc", "meta": {"piAcp": {"queueDepth": 0, "running": false}}}}
        }
        """#)

        #expect(session.isPrimary == true)
        #expect(session.displayName == "feature/implement-embedded-z-bf5")
        #expect(session.metadata?["acp"]?["meta"]?["piAcp"]?["queueDepth"] == .integer(0))
    }

    @Test("falls back to a short id when a session has neither name nor branch")
    func sessionDisplayNameFallsBack() throws {
        let session = try decode(KandevSession.self, #"{"id":"abcdef1234567890","name":"  "}"#)

        #expect(session.displayName == "abcdef12")
    }

    @Test("decodes a paginated message page")
    func decodesMessagePage() throws {
        let page = try decode(KandevMessagePage.self, #"""
        {
          "cursor": "ca50e371-7453-410d-9631-a2c3130cc514",
          "has_more": true,
          "messages": [
            {
              "id": "505b6cdb-9b88-4657-8fd3-5c19f8bf8543",
              "author_type": "user",
              "content": "Implement the changes.",
              "raw_content": "<kandev-system>KANDEV MCP TOOLS</kandev-system>",
              "created_at": "2026-10-04T17:32:55.944055855Z",
              "prompt_index": 1,
              "metadata": {"has_hidden_prompts": true}
            }
          ]
        }
        """#)

        #expect(page.hasMore)
        #expect(page.cursor == "ca50e371-7453-410d-9631-a2c3130cc514")
        #expect(page.messages.first?.isFromUser == true)
        #expect(page.messages.first?.promptIndex == 1)
    }

    @Test("decodes a workflow, and tolerates a missing prompt")
    func decodesWorkflow() throws {
        let list = try decode(KandevWorkflowList.self, #"""
        {"total": 2, "workflows": [
          {"id": "c0d5b387", "name": "Development", "sort_order": 1, "style": "kanban",
           "workspace_id": "faf4dd26", "description": "Default development workflow"},
          {"id": "f1f1e633", "name": "Orchestrate", "sort_order": 2, "style": "kanban",
           "prompt": "You are the orchestrator...", "created_at": "2026-09-30T04:41:18.209914304Z"}
        ]}
        """#)

        #expect(list.total == 2)
        #expect(list.workflows[0].prompt == nil)
        #expect(list.workflows[1].prompt?.hasPrefix("You are the orchestrator") == true)
    }

    @Test("decodes a workflow step")
    func decodesWorkflowStep() throws {
        let list = try decode(KandevWorkflowStepList.self, #"""
        {"steps": [{"id":"d31a4b49","name":"In Progress","position":1,"color":"bg-blue-500",
                    "stage_type":"custom","is_start_step":true,"wip_limit":4}]}
        """#)

        #expect(list.steps.first?.name == "In Progress")
        #expect(list.steps.first?.isStartStep == true)
        #expect(list.steps.first?.color == "bg-blue-500")
    }

    @Test("decodes a workspace, scopes included")
    func decodesWorkspace() throws {
        let list = try decode(KandevWorkspaceList.self, #"""
        {"total": 1, "workspaces": [{
          "id": "faf4dd26-22b5-4c6e-ae6a-d0130eb9ea10",
          "name": "Default Workspace",
          "description": "Default workspace",
          "task_prefix": "KAN",
          "viewer_role": "owner",
          "scopes": ["session.control","session.prompt","task.write","workspace.read"]
        }]}
        """#)

        let workspace = try #require(list.workspaces.first)
        #expect(workspace.taskPrefix == "KAN")
        #expect(workspace.canControlSessions)
        #expect(workspace.canWriteTasks)
    }

    @Test("parses the server's nanosecond timestamps")
    func parsesNanosecondTimestamps() {
        let stamp = KandevTimestamp(raw: "2026-10-04T18:07:04.074817797Z")

        #expect(stamp.date != nil)
        let earlier = KandevTimestamp(raw: "2026-10-04T17:32:54.464054764Z")
        #expect(earlier < stamp)
    }

    @Test("survives a timestamp it cannot parse")
    func toleratesBadTimestamp() {
        let stamp = KandevTimestamp(raw: "not a date")

        #expect(stamp.date == nil)
        #expect(stamp.raw == "not a date")
    }
}
