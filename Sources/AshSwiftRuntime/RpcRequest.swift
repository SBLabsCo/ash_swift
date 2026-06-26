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

/// Body for list, raw, and any void action: just the action name and field
/// selection. Wire-identical to the M1 `RequestBody`.
public struct ActionFieldsBody: Encodable, Sendable {
    let action: String
    let fields: [FieldSelection]
}

/// Body for paginated list actions. `page` is omitted from the JSON when nil
/// (the backend then returns its default page).
public struct PagedBody<P: Encodable & Sendable>: Encodable, Sendable {
    let action: String
    let fields: [FieldSelection]
    let page: P?
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
        ActionFieldsBody(action: action, fields: fields)
    }

    public func decode(from data: Data, using decoder: JSONDecoder) throws -> Data {
        data
    }
}

/// A list (non-get read) action with no required pagination: decodes the
/// `data` array into `[T]`.
public struct ListRequest<T: Decodable & Sendable>: DataEnvelopeRequest {
    public typealias Output = [T]
    let action: String
    let fields: [FieldSelection]

    public init(action: String, fields: [FieldSelection] = []) {
        self.action = action
        self.fields = fields
    }

    public func makeBody() -> ActionFieldsBody {
        ActionFieldsBody(action: action, fields: fields)
    }
}

/// An offset-paginated read action: decodes the `data` object into
/// `OffsetPage<T>`. Pass `page` to control which page the backend returns.
public struct OffsetPageRequest<T: Decodable & Sendable>: DataEnvelopeRequest {
    public typealias Output = OffsetPage<T>
    let action: String
    let page: OffsetPageParams?
    let fields: [FieldSelection]

    public init(action: String, page: OffsetPageParams? = nil, fields: [FieldSelection] = []) {
        self.action = action
        self.page = page
        self.fields = fields
    }

    public func makeBody() -> PagedBody<OffsetPageParams> {
        PagedBody(action: action, fields: fields, page: page)
    }
}

/// A keyset-paginated read action: decodes the `data` object into
/// `KeysetPage<T>`. Pass `page` to control which page the backend returns.
public struct KeysetPageRequest<T: Decodable & Sendable>: DataEnvelopeRequest {
    public typealias Output = KeysetPage<T>
    let action: String
    let page: KeysetPageParams?
    let fields: [FieldSelection]

    public init(action: String, page: KeysetPageParams? = nil, fields: [FieldSelection] = []) {
        self.action = action
        self.page = page
        self.fields = fields
    }

    public func makeBody() -> PagedBody<KeysetPageParams> {
        PagedBody(action: action, fields: fields, page: page)
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
