import Foundation

/// What the task list needs from a server.
///
/// Deliberately narrower than `KandevClient`: the store should be drivable by a
/// fake with four methods, not by a socket. `KandevClient` conforms, so the app
/// passes the real thing and tests pass whatever they like.
public protocol KandevTaskSource: Sendable {
    func workspaces() async throws -> [KandevWorkspace]
    func workflows(workspaceID: String) async throws -> [KandevWorkflow]
    func workflowSteps(workflowID: String) async throws -> [KandevWorkflowStep]
    func tasks(workspaceID: String, query: KandevTaskListQuery) async throws -> KandevTaskList
    /// The workspace's repositories, for choosing which one work belongs to.
    func repositories(workspaceID: String) async throws -> [KandevRepository]
}

extension KandevClient: KandevTaskSource {}
