import Foundation
import Testing

@testable import KandevKit

@Suite("JSONValue")
struct JSONValueTests {
    @Test("round-trips every case")
    func roundTrips() throws {
        let value = JSONValue.object([
            "null": .null,
            "bool": .bool(true),
            "integer": .integer(42),
            "number": .number(1.5),
            "string": .string("hello"),
            "array": .array([.integer(1), .integer(2)]),
            "nested": .object(["deep": .string("value")]),
        ])

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(decoded == value)
    }

    @Test("keeps integers exact rather than routing them through Double")
    func keepsIntegerPrecision() throws {
        // A Double cannot represent this value. Ids and counters are the reason
        // `integer` exists as a separate case.
        let large = 9_007_199_254_740_993
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data("\(large)".utf8))
        #expect(decoded == .integer(large))
    }

    @Test("distinguishes a boolean from the number one")
    func booleanIsNotAnInteger() throws {
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data("true".utf8)) == .bool(true))
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data("1".utf8)) == .integer(1))
    }

    @Test("re-decodes into a typed struct")
    func decodesIntoAType() throws {
        struct Payload: Decodable, Equatable {
            var code: String
            var message: String
        }

        let value = JSONValue.object(["code": .string("NOT_FOUND"), "message": .string("no such task")])
        let payload = try value.decoded(as: Payload.self)

        #expect(payload == Payload(code: "NOT_FOUND", message: "no such task"))
    }

    @Test("subscript reaches object members and refuses non-objects")
    func subscriptMembers() {
        let value = JSONValue.object(["a": .integer(1)])

        #expect(value["a"] == .integer(1))
        #expect(value["missing"] == nil)
        #expect(JSONValue.array([])["a"] == nil)
    }
}
