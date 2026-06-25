import Foundation

/// Represents a single field or nested relationship selection for an RPC request.
///
/// String literals are implicitly converted to `.scalar`, so simple field lists
/// still work without change:
/// ```swift
/// let todos = try await rpc.listTodos(fields: ["id", "title"])
/// ```
/// To include nested relationship data, use `.relationship(_:fields:)`:
/// ```swift
/// let todos = try await rpc.listTodos(fields: [
///     "id", "title",
///     .relationship("user", ["name", "email"])
/// ])
/// ```
public enum FieldSelection: Encodable, Sendable, Equatable, ExpressibleByStringLiteral {
    case scalar(String)
    case relationship(String, [FieldSelection])

    public init(stringLiteral value: String) {
        self = .scalar(value)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .scalar(let name):
            var container = encoder.singleValueContainer()
            try container.encode(name)
        case .relationship(let name, let fields):
            var container = encoder.container(keyedBy: StringCodingKey.self)
            try container.encode(fields, forKey: StringCodingKey(name))
        }
    }
}

private struct StringCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ value: String) { self.stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
