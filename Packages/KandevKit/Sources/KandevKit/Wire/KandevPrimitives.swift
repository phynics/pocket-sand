import Foundation

/// A Kandev timestamp.
///
/// The server sends RFC 3339 with nanosecond precision
/// (`2026-10-04T18:07:04.074817797Z`), which trips the stricter ISO 8601
/// parsers. The raw string is kept so nothing is lost, and `date` is a
/// best-effort parse for sorting and relative-time display.
public struct KandevTimestamp: Sendable, Equatable, Comparable {
    public let raw: String
    public let date: Date?

    public init(raw: String) {
        self.raw = raw
        self.date = Self.parse(raw)
    }

    public static func < (lhs: KandevTimestamp, rhs: KandevTimestamp) -> Bool {
        switch (lhs.date, rhs.date) {
        case (let l?, let r?): l < r
        case (nil, _?): true
        case (_?, nil): false
        default: lhs.raw < rhs.raw
        }
    }

    static func parse(_ raw: String) -> Date? {
        // Nanosecond digits are more than any parser here wants, so trim to
        // milliseconds before handing it over.
        let trimmed = trimmingFractionalSeconds(raw)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func trimmingFractionalSeconds(_ raw: String) -> String {
        guard let dot = raw.firstIndex(of: ".") else { return raw }
        let afterDot = raw.index(after: dot)
        var end = afterDot
        while end < raw.endIndex, raw[end].isNumber { end = raw.index(after: end) }
        let digits = raw.distance(from: afterDot, to: end)
        guard digits > 3 else { return raw }
        let cut = raw.index(afterDot, offsetBy: 3)
        return String(raw[raw.startIndex..<cut]) + String(raw[end...])
    }
}

extension KandevTimestamp: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(raw: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// A list the server sometimes sends as JSON text inside a string.
///
/// `labels` arrives as the string `"[]"`, not as an array. Verified against a
/// live server; a model that expects `[String]` fails to decode every task.
/// Both shapes are accepted because both are on the wire.
public struct KandevStringList: Sendable, Equatable {
    public let values: [String]

    public init(_ values: [String] = []) { self.values = values }
}

extension KandevStringList: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([String].self) {
            self.init(list)
            return
        }
        let text = try container.decode(String.self)
        guard !text.isEmpty, let data = text.data(using: .utf8) else {
            self.init()
            return
        }
        self.init((try? JSONDecoder().decode([String].self, from: data)) ?? [])
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

extension KandevStringList: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: String...) { self.init(elements) }
}
