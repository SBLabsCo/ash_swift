import Foundation

/// A page of results returned by an offset-paginated read action.
///
/// Decodes from the paginated envelope AshTypescript emits when
/// `pagination offset?: true` is set on the Ash action:
/// `{"results":[...],"hasMore":bool,"limit":int,"offset":int,"count":int|null}`.
public struct OffsetPage<T: Decodable & Sendable>: Decodable, Sendable {
    public let results: [T]
    public let hasMore: Bool
    public let limit: Int?
    public let offset: Int?
    public let count: Int?
}

/// A page of results returned by a keyset-paginated read action.
///
/// Decodes from the paginated envelope AshTypescript emits when
/// `pagination keyset?: true` is set on the Ash action:
/// `{"results":[...],"hasMore":bool,"limit":int,"after":str|null,"before":str|null,"nextPage":str|null,"previousPage":str|null,"count":int|null}`.
public struct KeysetPage<T: Decodable & Sendable>: Decodable, Sendable {
    public let results: [T]
    public let hasMore: Bool
    public let limit: Int?
    public let after: String?
    public let before: String?
    public let nextPage: String?
    public let previousPage: String?
    public let count: Int?
}
