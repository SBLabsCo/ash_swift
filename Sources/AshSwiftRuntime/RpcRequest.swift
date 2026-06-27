import Foundation

/// A typed description of one RPC call: the request body to send and how to
/// decode the result. The generated client constructs an `RpcRequest` value and
/// hands it to `AshRpcClient.execute`, which runs the wire round-trip and
/// validates the `{"success": ...}` envelope before delegating the data decode
/// back to the request.
///
/// New action shapes become new `RpcRequest` conformances rather than new
/// methods on the client — the client's interface stays one method wide.
public protocol RpcRequest: Sendable {
    /// The request body POSTed for this call. Wire-identical to what any
    /// AshTypescript client sends (ADR-0003).
    associatedtype Body: Encodable

    /// The value `execute` returns to the caller.
    associatedtype Output

    /// Builds the request body. nil Optional properties are omitted from the
    /// JSON via the synthesized `encodeIfPresent`.
    func makeBody() -> Body

    /// Decodes the result from the already-validated response bytes. `execute`
    /// has confirmed `success == true`; this only has to read the `data` shape.
    func decode(from data: Data, using decoder: JSONDecoder) throws -> Output
}

/// The common case: the result is the response envelope's `data` value,
/// decoded into `Output`. Covers list, paginated, get, create, and update
/// requests — only destroy (void) and raw (data) supply a custom `decode`.
public protocol DataEnvelopeRequest: RpcRequest where Output: Decodable {}

extension DataEnvelopeRequest {
    public func decode(from data: Data, using decoder: JSONDecoder) throws -> Output {
        return try decoder.decode(DataEnvelope<Output>.self, from: data).data
    }
}

/// The single-key `{ "data": … }` envelope every `DataEnvelopeRequest` unwraps.
private struct DataEnvelope<D: Decodable>: Decodable {
    let data: D
}

// MARK: - Request bodies

/// Body for list, raw, and any void action: the action name, field selection,
/// and optional sort/filter. `sort` is the assembled Ash sort string (see
/// AshSort.swift); `filter` is a type-erased `{Resource}Filter`. Each is omitted
/// from the JSON when nil — so a raw/void action, or a list with no sort/filter,
/// stays wire-identical to the M1 `RequestBody`.
public struct ActionFieldsBody: Encodable, Sendable {
    let action: String
    let fields: [FieldSelection]
    let sort: String?
    let filter: AnyEncodable?
}

/// Body for paginated list actions. `page`, `sort`, and `filter` are each
/// omitted from the JSON when nil (the backend then returns its default page /
/// order / unfiltered result).
public struct PagedBody<P: Encodable & Sendable>: Encodable, Sendable {
    let action: String
    let fields: [FieldSelection]
    let page: P?
    let sort: String?
    let filter: AnyEncodable?
}

/// Body for get actions. `input` carries native get_by field values; `getBy`
/// carries RPC-level get_by field values. Empty dicts are passed as nil so the
/// key is omitted from the JSON.
public struct GetBody: Encodable, Sendable {
    let action: String
    let fields: [FieldSelection]
    let input: [String: String]?
    let getBy: [String: String]?
}

/// Body for create actions. The typed `input` encodes directly into the JSON.
public struct CreateBody<I: Encodable & Sendable>: Encodable, Sendable {
    let action: String
    let input: I
    let fields: [FieldSelection]
}

/// Body for update actions. `identity` is the primary-key string value (the
/// AshTypescript RPC wire format — see ADR-0003).
public struct UpdateBody<I: Encodable & Sendable>: Encodable, Sendable {
    let action: String
    let identity: String
    let input: I
    let fields: [FieldSelection]
}

/// Body for destroy actions. `identity` is the primary-key string value.
public struct DestroyBody: Encodable, Sendable {
    let action: String
    let identity: String
}

/// Body for generic (`:action`-type) actions: the action name plus the typed
/// `input` when the action takes arguments. `input` is omitted from the JSON
/// when nil (the synthesized `encodeIfPresent`), so a no-argument generic action
/// sends just `{"action": …}`. Generic actions in this slice carry no field
/// selection (typed-record returns that would need it are deferred), so there is
/// no `fields` key — wire-confirmed against the RPC pipeline (issue #54).
public struct GenericActionBody<I: Encodable & Sendable>: Encodable, Sendable {
    let action: String
    let input: I?
}

/// The input type for a generic action that takes no arguments. Pins the input
/// generic of `GenericActionRequest` / `VoidActionRequest` at the call site
/// (where there is no `input` value to infer it from); it never reaches the wire
/// because the body's `input` stays nil.
public struct EmptyActionInput: Encodable, Sendable {
    public init() {}
}

// MARK: - Requests

/// Runs an action and returns the raw, envelope-validated response bytes.
/// The `Output` is `Data`, so there is no `data`-key unwrap.
public struct RawRequest: RpcRequest {
    public typealias Output = Data
    let action: String
    let fields: [FieldSelection]

    public init(action: String, fields: [FieldSelection] = []) {
        self.action = action
        self.fields = fields
    }

    public func makeBody() -> ActionFieldsBody {
        ActionFieldsBody(action: action, fields: fields, sort: nil, filter: nil)
    }

    public func decode(from data: Data, using decoder: JSONDecoder) throws -> Data {
        data
    }
}

/// A list (non-get read) action with no required pagination: decodes the
/// `data` array into `[T]`. `sort` is the assembled Ash sort string (build it
/// from a typed sort with `ashSortString` — see AshSort.swift); nil leaves the
/// pre-sort wire shape unchanged.
public struct ListRequest<T: Decodable & Sendable>: DataEnvelopeRequest {
    public typealias Output = [T]
    let action: String
    let filter: AnyEncodable?
    let sort: String?
    let fields: [FieldSelection]

    public init(
        action: String,
        filter: AnyEncodable? = nil,
        sort: String? = nil,
        fields: [FieldSelection] = []
    ) {
        self.action = action
        self.filter = filter
        self.sort = sort
        self.fields = fields
    }

    public func makeBody() -> ActionFieldsBody {
        ActionFieldsBody(action: action, fields: fields, sort: sort, filter: filter)
    }
}

/// An offset-paginated read action: decodes the `data` object into
/// `OffsetPage<T>`. Pass `page` to control which page the backend returns.
public struct OffsetPageRequest<T: Decodable & Sendable>: DataEnvelopeRequest {
    public typealias Output = OffsetPage<T>
    let action: String
    let page: OffsetPageParams?
    let filter: AnyEncodable?
    let sort: String?
    let fields: [FieldSelection]

    public init(
        action: String,
        page: OffsetPageParams? = nil,
        filter: AnyEncodable? = nil,
        sort: String? = nil,
        fields: [FieldSelection] = []
    ) {
        self.action = action
        self.page = page
        self.filter = filter
        self.sort = sort
        self.fields = fields
    }

    public func makeBody() -> PagedBody<OffsetPageParams> {
        PagedBody(action: action, fields: fields, page: page, sort: sort, filter: filter)
    }
}

/// A keyset-paginated read action: decodes the `data` object into
/// `KeysetPage<T>`. Pass `page` to control which page the backend returns.
public struct KeysetPageRequest<T: Decodable & Sendable>: DataEnvelopeRequest {
    public typealias Output = KeysetPage<T>
    let action: String
    let page: KeysetPageParams?
    let filter: AnyEncodable?
    let sort: String?
    let fields: [FieldSelection]

    public init(
        action: String,
        page: KeysetPageParams? = nil,
        filter: AnyEncodable? = nil,
        sort: String? = nil,
        fields: [FieldSelection] = []
    ) {
        self.action = action
        self.page = page
        self.filter = filter
        self.sort = sort
        self.fields = fields
    }

    public func makeBody() -> PagedBody<KeysetPageParams> {
        PagedBody(action: action, fields: fields, page: page, sort: sort, filter: filter)
    }
}

/// A get action where `not_found_error?` is true: decodes the single `data`
/// record into `T`. The backend throws (surfaced as `AshRpcError.server`) when
/// no record matches, so the result is non-optional.
public struct GetRequest<T: Decodable & Sendable>: DataEnvelopeRequest {
    public typealias Output = T
    let action: String
    let input: [String: String]
    let getBy: [String: String]
    let fields: [FieldSelection]

    public init(
        action: String,
        input: [String: String] = [:],
        getBy: [String: String] = [:],
        fields: [FieldSelection] = []
    ) {
        self.action = action
        self.input = input
        self.getBy = getBy
        self.fields = fields
    }

    public func makeBody() -> GetBody {
        GetBody(
            action: action,
            fields: fields,
            input: input.isEmpty ? nil : input,
            getBy: getBy.isEmpty ? nil : getBy
        )
    }
}

/// A get action where `not_found_error?` is false: decodes the `data` record
/// into `T?`, returning nil when the backend sends `{"data": null}`.
public struct GetOptionalRequest<T: Decodable & Sendable>: DataEnvelopeRequest {
    public typealias Output = T?
    let action: String
    let input: [String: String]
    let getBy: [String: String]
    let fields: [FieldSelection]

    public init(
        action: String,
        input: [String: String] = [:],
        getBy: [String: String] = [:],
        fields: [FieldSelection] = []
    ) {
        self.action = action
        self.input = input
        self.getBy = getBy
        self.fields = fields
    }

    public func makeBody() -> GetBody {
        GetBody(
            action: action,
            fields: fields,
            input: input.isEmpty ? nil : input,
            getBy: getBy.isEmpty ? nil : getBy
        )
    }
}

/// A create action: encodes the typed `input` and decodes the created record
/// into `T`.
public struct CreateRequest<T: Decodable & Sendable, I: Encodable & Sendable>: DataEnvelopeRequest {
    public typealias Output = T
    let action: String
    let input: I
    let fields: [FieldSelection]

    public init(action: String, input: I, fields: [FieldSelection] = []) {
        self.action = action
        self.input = input
        self.fields = fields
    }

    public func makeBody() -> CreateBody<I> {
        CreateBody(action: action, input: input, fields: fields)
    }
}

/// An update action: sends `identity` (the primary-key string, per ADR-0003)
/// plus the typed `input`, and decodes the updated record into `T`.
public struct UpdateRequest<T: Decodable & Sendable, I: Encodable & Sendable>: DataEnvelopeRequest {
    public typealias Output = T
    let action: String
    let identity: String
    let input: I
    let fields: [FieldSelection]

    public init(action: String, identity: String, input: I, fields: [FieldSelection] = []) {
        self.action = action
        self.identity = identity
        self.input = input
        self.fields = fields
    }

    public func makeBody() -> UpdateBody<I> {
        UpdateBody(action: action, identity: identity, input: input, fields: fields)
    }
}

/// A destroy action: sends `identity` and returns nothing on success.
public struct DestroyRequest: RpcRequest {
    public typealias Output = Void
    let action: String
    let identity: String

    public init(action: String, identity: String) {
        self.action = action
        self.identity = identity
    }

    public func makeBody() -> DestroyBody {
        DestroyBody(action: action, identity: identity)
    }

    public func decode(from data: Data, using decoder: JSONDecoder) throws {
        // Success is already validated by `execute`; destroy returns no record.
    }
}

/// A generic (`:action`-type) action that returns a value: encodes the optional
/// typed `input` and decodes the response's `data` into `O` (a scalar or a
/// `[String: AshJSON]` map). For a no-argument action, pin `I` to
/// `EmptyActionInput` and leave `input` nil. See issue #54.
public struct GenericActionRequest<O: Decodable & Sendable, I: Encodable & Sendable>:
    DataEnvelopeRequest
{
    public typealias Output = O
    let action: String
    let input: I?

    public init(action: String, input: I? = nil) {
        self.action = action
        self.input = input
    }

    public func makeBody() -> GenericActionBody<I> {
        GenericActionBody(action: action, input: input)
    }
}

/// A generic (`:action`-type) action that returns nothing (an Ash action with no
/// `returns` — e.g. a side-effecting command like requesting a magic link).
/// Encodes the optional typed `input` and returns Void on success. For a
/// no-argument action, pin `I` to `EmptyActionInput` and leave `input` nil.
public struct VoidActionRequest<I: Encodable & Sendable>: RpcRequest {
    public typealias Output = Void
    let action: String
    let input: I?

    public init(action: String, input: I? = nil) {
        self.action = action
        self.input = input
    }

    public func makeBody() -> GenericActionBody<I> {
        GenericActionBody(action: action, input: input)
    }

    public func decode(from data: Data, using decoder: JSONDecoder) throws {
        // Success is already validated by `execute`; a void action returns no data.
    }
}
