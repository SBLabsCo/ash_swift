import Foundation

/// Type-erased `Encodable`, letting a value of any concrete `Encodable` type be
/// stored and re-encoded without the holder being generic over that type.
///
/// The generated read functions wrap a typed `{Resource}Filter` in this so the
/// runtime request bodies (`ActionFieldsBody`, `PagedBody`) can carry a filter
/// without becoming generic over every resource's filter shape. Encoding simply
/// forwards to the wrapped value, so the emitted JSON is identical to encoding
/// the filter directly.
public struct AnyEncodable: Encodable, Sendable {
    private let encodeValue: @Sendable (Encoder) throws -> Void

    public init<T: Encodable & Sendable>(_ wrapped: T) {
        self.encodeValue = { encoder in try wrapped.encode(to: encoder) }
    }

    public func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

// MARK: - Operator groups
//
// Each generic below is a typed bag of filter operators for one attribute. Every
// operator is Optional and encoded with the synthesized `encodeIfPresent`, so an
// unset operator is omitted and a set one serializes as `{operator: value}` —
// the shape `Ash.Query.filter_input` consumes. The operator property names are
// the exact camelCase wire keys the reused AshTypescript RPC pipeline accepts
// (confirmed against the live pipeline): `eq`, `notEq`, `in`, `isNil`,
// `lessThan`, `lessThanOrEqual`, `greaterThan`, `greaterThanOrEqual`.
//
// The group an attribute gets is driven by its Ash type:
//   - boolean              → EquatableOperators        (eq, notEq)
//   - string / enum / uuid → EnumOperators             (eq, notEq, in)
//   - numeric / date(time) → ComparableOperators       (the above + comparisons)
// A nullable attribute gets the matching `Nullable*` variant, which adds `isNil`.
// The bare variants omit `isNil` so a non-null attribute exposes exactly its
// type-driven operator set and nothing more.

/// Equality operators for a non-null attribute (e.g. a non-null `Bool`).
public struct EquatableOperators<T: Encodable & Sendable>: Encodable, Sendable {
    public var eq: T?
    public var notEq: T?

    public init(eq: T? = nil, notEq: T? = nil) {
        self.eq = eq
        self.notEq = notEq
    }
}

/// Equality operators plus `isNil` for a nullable attribute.
public struct NullableEquatableOperators<T: Encodable & Sendable>: Encodable, Sendable {
    public var eq: T?
    public var notEq: T?
    public var isNil: Bool?

    public init(eq: T? = nil, notEq: T? = nil, isNil: Bool? = nil) {
        self.eq = eq
        self.notEq = notEq
        self.isNil = isNil
    }
}

/// Equality + membership operators for a non-null attribute. Used for the
/// equality-and-`in` group: enums, strings, UUIDs, and the default fallback.
public struct EnumOperators<T: Encodable & Sendable>: Encodable, Sendable {
    public var eq: T?
    public var notEq: T?
    public var `in`: [T]?

    public init(eq: T? = nil, notEq: T? = nil, in: [T]? = nil) {
        self.eq = eq
        self.notEq = notEq
        self.`in` = `in`
    }
}

/// Equality + membership operators plus `isNil` for a nullable attribute.
public struct NullableEnumOperators<T: Encodable & Sendable>: Encodable, Sendable {
    public var eq: T?
    public var notEq: T?
    public var `in`: [T]?
    public var isNil: Bool?

    public init(eq: T? = nil, notEq: T? = nil, in: [T]? = nil, isNil: Bool? = nil) {
        self.eq = eq
        self.notEq = notEq
        self.`in` = `in`
        self.isNil = isNil
    }
}

/// Equality, membership, and ordering operators for a non-null comparable
/// attribute (numeric and date/datetime types).
public struct ComparableOperators<T: Encodable & Sendable>: Encodable, Sendable {
    public var eq: T?
    public var notEq: T?
    public var `in`: [T]?
    public var lessThan: T?
    public var lessThanOrEqual: T?
    public var greaterThan: T?
    public var greaterThanOrEqual: T?

    public init(
        eq: T? = nil,
        notEq: T? = nil,
        in: [T]? = nil,
        lessThan: T? = nil,
        lessThanOrEqual: T? = nil,
        greaterThan: T? = nil,
        greaterThanOrEqual: T? = nil
    ) {
        self.eq = eq
        self.notEq = notEq
        self.`in` = `in`
        self.lessThan = lessThan
        self.lessThanOrEqual = lessThanOrEqual
        self.greaterThan = greaterThan
        self.greaterThanOrEqual = greaterThanOrEqual
    }
}

/// Comparable operators plus `isNil` for a nullable comparable attribute.
public struct NullableComparableOperators<T: Encodable & Sendable>: Encodable, Sendable {
    public var eq: T?
    public var notEq: T?
    public var `in`: [T]?
    public var lessThan: T?
    public var lessThanOrEqual: T?
    public var greaterThan: T?
    public var greaterThanOrEqual: T?
    public var isNil: Bool?

    public init(
        eq: T? = nil,
        notEq: T? = nil,
        in: [T]? = nil,
        lessThan: T? = nil,
        lessThanOrEqual: T? = nil,
        greaterThan: T? = nil,
        greaterThanOrEqual: T? = nil,
        isNil: Bool? = nil
    ) {
        self.eq = eq
        self.notEq = notEq
        self.`in` = `in`
        self.lessThan = lessThan
        self.lessThanOrEqual = lessThanOrEqual
        self.greaterThan = greaterThan
        self.greaterThanOrEqual = greaterThanOrEqual
        self.isNil = isNil
    }
}
