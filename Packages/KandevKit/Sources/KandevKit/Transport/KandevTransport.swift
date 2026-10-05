import Foundation

/// The seam between the app and a Kandev server.
///
/// Nothing above this protocol knows that the transport is a WebSocket, which is
/// what lets tests drive the store with recorded frames and what will let us add
/// an HTTPS path later without touching the UI.
public protocol KandevTransport: Sendable {
    /// Frames the server pushed without being asked: streamed agent output, task
    /// status, connectivity notices.
    var notifications: AsyncStream<KandevEnvelope> { get }

    func connect() async throws

    /// Sends one request frame and returns the response that carries its `id`.
    /// Throws `KandevError.server` when the server answers with an error frame.
    func send(_ envelope: KandevEnvelope) async throws -> KandevEnvelope

    func close() async
}
