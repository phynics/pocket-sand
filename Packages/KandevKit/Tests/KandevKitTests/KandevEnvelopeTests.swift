import Foundation
import Testing

@testable import KandevKit

@Suite("KandevEnvelope")
struct KandevEnvelopeTests {
    @Test("decodes a response frame")
    func decodesResponse() throws {
        let json = #"""
        {
          "id": "550e8400-e29b-41d4-a716-446655440000",
          "type": "response",
          "action": "workflow.list",
          "payload": { "workflows": [], "total": 0 },
          "timestamp": "2026-07-16T09:00:00Z"
        }
        """#

        let envelope = try JSONDecoder().decode(KandevEnvelope.self, from: Data(json.utf8))

        #expect(envelope.type == .response)
        #expect(envelope.id == "550e8400-e29b-41d4-a716-446655440000")
        #expect(envelope.action == "workflow.list")
        #expect(envelope.payload?["total"] == .integer(0))
        #expect(envelope.timestamp == "2026-07-16T09:00:00Z")
    }

    @Test("decodes a notification, which carries no id")
    func decodesNotification() throws {
        let json = #"{"type":"notification","action":"acp.progress","payload":{"text":"hi"}}"#

        let envelope = try JSONDecoder().decode(KandevEnvelope.self, from: Data(json.utf8))

        #expect(envelope.type == .notification)
        #expect(envelope.id == nil)
        #expect(envelope.payload?["text"] == .string("hi"))
    }

    @Test("decodes the documented error frame into a readable payload")
    func decodesError() throws {
        let json = #"""
        {
          "id": "abc",
          "type": "error",
          "action": "task.get",
          "payload": { "code": "NOT_FOUND", "message": "no task with that id", "details": {} }
        }
        """#

        let envelope = try JSONDecoder().decode(KandevEnvelope.self, from: Data(json.utf8))
        let decodedPayload = try envelope.payload?.decoded(as: KandevErrorPayload.self)
        let payload = try #require(decodedPayload)

        #expect(payload.code == "NOT_FOUND")
        #expect(payload.message == "no task with that id")
    }

    @Test("a request omits fields the server does not need")
    func encodesRequestCompactly() throws {
        let envelope = KandevEnvelope.request(id: "1", action: "task.list")
        let data = try JSONEncoder().encode(envelope)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let object = try #require(json)

        #expect(object["type"] as? String == "request")
        #expect(object["action"] as? String == "task.list")
        #expect(object["id"] as? String == "1")
        #expect(object["payload"] == nil)
    }

    @Test("rejects a frame whose type is not part of the protocol")
    func rejectsUnknownKind() {
        let json = #"{"type":"telemetry","action":"whatever"}"#

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(KandevEnvelope.self, from: Data(json.utf8))
        }
    }
}
