import Foundation

/// A JSON value for the research loop's requests and replies. The loop only
/// links Foundation and the model catalog, so it does not use the engine's
/// `JSONValue`.
public enum ResearchJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([ResearchJSON])
    case object([String: ResearchJSON])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ResearchJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ResearchJSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> ResearchJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .integer(let value): return value
        case .number(let value) where value.rounded() == value && abs(value) < 1e15:
            return Int(value)
        default: return nil
        }
    }

    public var arrayValue: [ResearchJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: ResearchJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    static func decode(_ data: Data) throws -> ResearchJSON {
        try JSONDecoder().decode(ResearchJSON.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
