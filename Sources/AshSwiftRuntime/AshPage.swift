import Foundation

/// A page of results returned by an offset-paginated read action.
///
/// Decodes from the paginated envelope AshTypescript emits when
/// `pagination offset?: true, required?: true` is set on the Ash action:
/// `{"results":[...],"hasMore":bool,"limit":int,"offset":int,"count":int|null}`.
public struct OffsetPage<T: Decodable & Sendable>: Decodable, Sendable {
    public let results: [T]
    public let hasMore: Bool
    public let limit: Int
    public let offset: Int
    public let count: Int?
}

/// A page of results returned by a keyset-paginated read action.
///
/// Decodes from the paginated envelope AshTypescript emits when
/// `pagination keyset?: true, required?: true` is set on the Ash action:
/// `{"results":[...],"hasMore":bool,"limit":int,"after":str|null,"before":str|null,"nextPage":str|null,"previousPage":str|null,"count":int|null}`.
public struct KeysetPage<T: Decodable & Sendable>: Decodable, Sendable {
    public let results: [T]
    public let hasMore: Bool
    public let limit: Int
    public let after: String?
    public let before: String?
    public let nextPage: String?
    public let previousPage: String?
    public let count: Int?
}

/// Page navigation parameters for offset-paginated read actions.
///
/// Pass to `runListOffset` (or generated wrappers) to control which page the
/// backend returns. Nil fields are omitted from the JSON body.
public struct OffsetPageParams: Encodable, Sendable {
    public let limit: Int?
    public let offset: Int?

    public init(limit: Int? = nil, offset: Int? = nil) {
        self.limit = limit
        self.offset = offset
    }
}

/// Page navigation parameters for keyset-paginated read actions.
///
/// Pass to `runListKeyset` (or generated wrappers) to control which page the
/// backend returns. Nil fields are omitted from the JSON body.
public struct KeysetPageParams: Encodable, Sendable {
    public let limit: Int?
    public let after: String?
    public let before: String?

    public init(limit: Int? = nil, after: String? = nil, before: String? = nil) {
        self.limit = limit
        self.after = after
        self.before = before
    }
}
