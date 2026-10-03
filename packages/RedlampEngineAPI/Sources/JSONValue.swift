import Foundation

/// Any JSON value. Used to carry fields written by a newer Redlamp through a load and save
/// unchanged, so an older build never erases settings it doesn't understand.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    /// An integer a `Double` can't hold exactly, so it isn't rounded on the way through.
    case integer(Int64)
    /// An integer above `Int64.max`.
    case unsignedInteger(UInt64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = Double(exactly: value).map(JSONValue.number) ?? .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = Double(exactly: value).map(JSONValue.number) ?? .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .unsignedInteger(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

/// A coding key for fields whose names aren't known at compile time.
public struct DynamicCodingKey: CodingKey {
    public var stringValue: String
    public var intValue: Int? {
        nil
    }

    public init(_ string: String) {
        stringValue = string
    }

    public init?(stringValue: String) {
        self.stringValue = stringValue
    }

    public init?(intValue _: Int) {
        nil
    }
}

public extension KeyedDecodingContainer where Key == DynamicCodingKey {
    /// Every field in this container whose name isn't in `known`.
    func unknownFields(excluding known: Set<String>) throws -> [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        for key in allKeys where !known.contains(key.stringValue) {
            fields[key.stringValue] = try decode(JSONValue.self, forKey: key)
        }
        return fields
    }
}

public extension KeyedEncodingContainer where Key == DynamicCodingKey {
    mutating func encode(_ fields: [String: JSONValue]) throws {
        for (name, value) in fields {
            try encode(value, forKey: DynamicCodingKey(name))
        }
    }
}
