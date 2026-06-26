import Foundation

/// A typed representation of any JSON value that can appear in an Ash.Type.Map field.
///
/// Ash maps arrive on the wire as plain JSON objects whose values may be strings,
/// numbers, booleans, null, arrays, or nested objects. The generated client types
/// map fields of type `Ash.Type.Map` to `[String: AshJSON]`; callers pattern-match
/// on individual `AshJSON` values to extract the underlying data.
///
/// Example:
/// ```swift
/// if case .string(let s) = todo.metadata?["label"] { print(s) }
/// if case .number(let n) = todo.metadata?["count"] { print(Int(n)) }
/// ```
public indirect enum AshJSON: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([AshJSON])
    case object([String: AshJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([AshJSON].self) {
            self = .array(a)
        } else {
            let o = try container.decode([String: AshJSON].self)
            self = .object(o)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}
