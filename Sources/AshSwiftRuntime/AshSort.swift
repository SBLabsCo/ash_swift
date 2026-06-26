import Foundation

/// The ordering applied to a single sort field.
///
/// Each case maps to the modifier the Ash sort string uses (the format the
/// reused AshTypescript RPC pipeline's `format_sort_string` parses):
///   - `.ascending`           → bare field name (e.g. `title`)
///   - `.descending`          → `-` prefix (e.g. `-title`)
///   - `.ascendingNilsFirst`  → `++` prefix (e.g. `++dueAt`)
///   - `.descendingNilsLast`  → `--` prefix (e.g. `--dueAt`)
///
/// The nils-first / nils-last variants only change ordering for nullable
/// fields; on a non-null field they behave like plain ascending / descending.
public enum SortDirection: Sendable, Equatable {
    case ascending
    case descending
    case ascendingNilsFirst
    case descendingNilsLast

    /// The Ash sort-string modifier this direction prepends to the field name.
    public var sortModifier: String {
        switch self {
        case .ascending: return ""
        case .descending: return "-"
        case .ascendingNilsFirst: return "++"
        case .descendingNilsLast: return "--"
        }
    }
}

/// A single (field, direction) pair in a typed sort.
///
/// `Field` is the per-resource sortable-field enum codegen emits — a
/// `String`-backed `RawRepresentable` whose raw value is the camelCase wire
/// field name. The server's input formatter converts that back to the
/// resource's internal field name.
public struct SortField<Field: RawRepresentable & Sendable>: Sendable where Field.RawValue == String {
    public let field: Field
    public let direction: SortDirection

    public init(_ field: Field, _ direction: SortDirection = .ascending) {
        self.field = field
        self.direction = direction
    }
}

/// Serializes a typed sort into the Ash sort string the server already parses,
/// or `nil` when the sort is empty (so the caller omits it from the request).
///
/// Fields serialize in priority order, comma-separated, each prefixed with its
/// direction modifier: `[SortField(.score, .descending), SortField(.title)]`
/// becomes `"-score,title"`.
public func ashSortString<Field>(_ sort: [SortField<Field>]) -> String? {
    guard !sort.isEmpty else { return nil }
    return sort
        .map { $0.direction.sortModifier + $0.field.rawValue }
        .joined(separator: ",")
}
