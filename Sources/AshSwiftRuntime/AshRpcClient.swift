import Foundation

/// The base RPC client the generated client builds on. Encodes a request,
/// POSTs it to the reused AshTypescript run endpoint, and validates the
/// `{"success": ...}` envelope, surfacing failures as thrown `AshRpcError`s.
///
/// Generated per-resource code stays thin — typed signatures over this client.
public struct AshRpcClient: Sendable {
    public let config: AshRpcConfig
    public let transport: Transport

    // Owned once rather than per-call: this is the hot path under every
    // generated function, and a single coder is the natural seam for
    // configuring key/date strategies in a later slice.
    private let encoder = JSONEncoder()

    // Configured at init time to decode Ash.Type.UtcDatetime and
    // Ash.Type.UtcDatetimeUsec fields. Both arrive as ISO 8601 UTC strings:
    //   UtcDatetime    → "2024-01-15T10:30:00Z"
    //   UtcDatetimeUsec → "2024-01-15T10:30:00.123456Z" (with fractional seconds)
    // The custom strategy tries the fractional-second formatter first, falling
    // back to the plain one so both variants decode cleanly.
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let fmtFrac = ISO8601DateFormatter()
        fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fmtPlain = ISO8601DateFormatter()
        fmtPlain.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = fmtFrac.date(from: str) { return date }
            if let date = fmtPlain.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AshRpcClient: cannot parse Date from \"\(str)\""
            )
        }
        return d
    }()

    public init(config: AshRpcConfig, transport: Transport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    /// The request body the client POSTs for list and void actions.
    /// Wire-identical to what any AshTypescript client sends (ADR-0003).
    private struct RequestBody: Encodable {
        let action: String
        let fields: [FieldSelection]
    }

    /// Request body for get actions. `input` carries native get_by field values;
    /// `getBy` carries RPC-level get_by field values. nil fields are omitted from
    /// the JSON (Swift synthesises `encodeIfPresent` for Optional properties).
    private struct GetRequestBody: Encodable {
        let action: String
        let fields: [FieldSelection]
        let input: [String: String]?
        let getBy: [String: String]?
    }

    /// Request body for create actions. The typed `input` encodes directly into
    /// the JSON; nil Optional properties are omitted via `encodeIfPresent`.
    private struct CreateRequestBody<I: Encodable>: Encodable {
        let action: String
        let input: I
        let fields: [FieldSelection]
    }

    /// Request body for update actions. `identity` is the primary-key string value
    /// (the AshTypescript RPC protocol wire format — see ADR-0003).
    private struct UpdateRequestBody<I: Encodable>: Encodable {
        let action: String
        let identity: String
        let input: I
        let fields: [FieldSelection]
    }

    /// Request body for destroy actions. `identity` is the primary-key string value.
    private struct DestroyRequestBody: Encodable {
        let action: String
        let identity: String
    }

    /// The envelope the runtime checks for success/failure before returning data.
    private struct Envelope: Decodable {
        let success: Bool
        let errors: [AshRpcServerError]?
    }

    /// Typed envelope for decoding a list data payload.
    private struct ListEnvelope<T: Decodable>: Decodable {
        let data: [T]
    }

    /// Typed envelope for decoding an offset-paginated data payload.
    private struct OffsetPageEnvelope<T: Decodable & Sendable>: Decodable {
        let data: OffsetPage<T>
    }

    /// Typed envelope for decoding a keyset-paginated data payload.
    private struct KeysetPageEnvelope<T: Decodable & Sendable>: Decodable {
        let data: KeysetPage<T>
    }

    /// Request body for offset-paginated list actions. `page` is omitted from
    /// the JSON when nil (Swift synthesises `encodeIfPresent` for Optional).
    private struct PagedOffsetRequestBody: Encodable {
        let action: String
        let fields: [FieldSelection]
        let page: OffsetPageParams?
    }

    /// Request body for keyset-paginated list actions. `page` is omitted from
    /// the JSON when nil.
    private struct PagedKeysetRequestBody: Encodable {
        let action: String
        let fields: [FieldSelection]
        let page: KeysetPageParams?
    }

    /// Typed envelope for decoding a single non-optional record.
    private struct GetEnvelope<T: Decodable>: Decodable {
        let data: T
    }

    /// Typed envelope for decoding a single optional record (`data` may be null
    /// when `not_found_error?` is false and no matching record exists).
    private struct GetOptionalEnvelope<T: Decodable>: Decodable {
        let data: T?
    }

    /// Sends `body` to the RPC endpoint, validates the success envelope, and
    /// returns the raw response bytes. Shared by all public run* methods.
    private func sendRequest<Body: Encodable>(_ body: Body) async throws -> Data {
        var request = URLRequest(url: config.runEndpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try encoder.encode(body)

        let (data, http) = try await transport.send(request)

        guard (200..<300).contains(http.statusCode) else {
            throw AshRpcError.httpStatus(code: http.statusCode, body: data)
        }

        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw AshRpcError.decodingFailed(description: String(describing: error))
        }

        guard envelope.success else {
            throw AshRpcError.server(errors: envelope.errors ?? [])
        }

        return data
    }

    /// Runs an RPC action and returns the raw response body on success.
    ///
    /// Validates the envelope: throws `AshRpcError.httpStatus` for non-2xx
    /// responses, `AshRpcError.server` when the backend reports failure, and
    /// `AshRpcError.decodingFailed` when the envelope is unintelligible.
    @discardableResult
    public func runRaw(action: String, fields: [FieldSelection] = []) async throws -> Data {
        return try await sendRequest(RequestBody(action: action, fields: fields))
    }

    /// Runs a list RPC action and decodes the `data` array from the response
    /// envelope into `[T]`. The caller supplies `T` through the return-type
    /// context; no type parameter is needed at the call site.
    public func runList<T: Decodable>(action: String, fields: [FieldSelection] = []) async throws -> [T] {
        let raw = try await runRaw(action: action, fields: fields)
        do {
            return try decoder.decode(ListEnvelope<T>.self, from: raw).data
        } catch {
            throw AshRpcError.decodingFailed(description: String(describing: error))
        }
    }

    /// Runs an offset-paginated list RPC action and decodes the response into
    /// `OffsetPage<T>`. Use for read actions with `pagination offset?: true,
    /// required?: true` — the backend always returns the paginated envelope shape.
    /// Pass `page` to control which page the backend returns (limit, offset).
    public func runListOffset<T: Decodable & Sendable>(
        action: String,
        page: OffsetPageParams? = nil,
        fields: [FieldSelection] = []
    ) async throws -> OffsetPage<T> {
        let raw = try await sendRequest(PagedOffsetRequestBody(action: action, fields: fields, page: page))
        do {
            return try decoder.decode(OffsetPageEnvelope<T>.self, from: raw).data
        } catch {
            throw AshRpcError.decodingFailed(description: String(describing: error))
        }
    }

    /// Runs a keyset-paginated list RPC action and decodes the response into
    /// `KeysetPage<T>`. Use for read actions with `pagination keyset?: true,
    /// required?: true` — the backend always returns the paginated envelope shape.
    /// Pass `page` to control which page the backend returns (limit, after/before cursors).
    public func runListKeyset<T: Decodable & Sendable>(
        action: String,
        page: KeysetPageParams? = nil,
        fields: [FieldSelection] = []
    ) async throws -> KeysetPage<T> {
        let raw = try await sendRequest(PagedKeysetRequestBody(action: action, fields: fields, page: page))
        do {
            return try decoder.decode(KeysetPageEnvelope<T>.self, from: raw).data
        } catch {
            throw AshRpcError.decodingFailed(description: String(describing: error))
        }
    }

    /// Builds a `GetRequestBody`, omitting `input`/`getBy` from the JSON when
    /// empty (Swift synthesises `encodeIfPresent` for Optional properties).
    private func makeGetBody(
        action: String,
        input: [String: String],
        getBy: [String: String],
        fields: [FieldSelection]
    ) -> GetRequestBody {
        GetRequestBody(
            action: action,
            fields: fields,
            input: input.isEmpty ? nil : input,
            getBy: getBy.isEmpty ? nil : getBy
        )
    }

    /// Runs a get RPC action and decodes the single record from `data`.
    ///
    /// Use this when `not_found_error?` is true (the default): the backend throws
    /// if no record matches, so the return type is non-optional. Pass lookup fields
    /// in `input` (native `get_by` on the Ash action) or `getBy` (RPC-level
    /// `get_by` on the rpc_action entity); the non-applicable dict defaults to `[:]`
    /// and is omitted from the JSON body.
    public func runGet<T: Decodable>(
        action: String,
        input: [String: String] = [:],
        getBy: [String: String] = [:],
        fields: [FieldSelection] = []
    ) async throws -> T {
        let raw = try await sendRequest(makeGetBody(action: action, input: input, getBy: getBy, fields: fields))
        do {
            return try decoder.decode(GetEnvelope<T>.self, from: raw).data
        } catch {
            throw AshRpcError.decodingFailed(description: String(describing: error))
        }
    }

    /// Runs a get RPC action and returns nil when no record is found.
    ///
    /// Use this when `not_found_error?` is false on the rpc_action: the backend
    /// returns `{"success":true,"data":null}` for a missing record, which decodes
    /// as `nil` here rather than throwing.
    public func runGetOptional<T: Decodable>(
        action: String,
        input: [String: String] = [:],
        getBy: [String: String] = [:],
        fields: [FieldSelection] = []
    ) async throws -> T? {
        let raw = try await sendRequest(makeGetBody(action: action, input: input, getBy: getBy, fields: fields))
        do {
            return try decoder.decode(GetOptionalEnvelope<T>.self, from: raw).data
        } catch {
            throw AshRpcError.decodingFailed(description: String(describing: error))
        }
    }

    /// Runs a create RPC action and decodes the returned record.
    ///
    /// The `input` value is encoded directly into the request body. Generated
    /// create input structs use `encodeIfPresent` for Optional properties so that
    /// unset fields are omitted from the JSON rather than sent as `null`.
    public func runCreate<T: Decodable, I: Encodable>(
        action: String,
        input: I,
        fields: [FieldSelection] = []
    ) async throws -> T {
        let raw = try await sendRequest(CreateRequestBody(action: action, input: input, fields: fields))
        do {
            return try decoder.decode(GetEnvelope<T>.self, from: raw).data
        } catch {
            throw AshRpcError.decodingFailed(description: String(describing: error))
        }
    }

    /// Runs an update RPC action and decodes the returned record.
    ///
    /// `identity` is the primary-key value string (the AshTypescript RPC wire
    /// protocol; see ADR-0003). For single-field UUID primary keys this is the
    /// record's UUID. The typed `input` carries only the changed fields; nil
    /// Optional properties are omitted from the JSON via `encodeIfPresent`.
    public func runUpdate<T: Decodable, I: Encodable>(
        action: String,
        identity: String,
        input: I,
        fields: [FieldSelection] = []
    ) async throws -> T {
        let raw = try await sendRequest(UpdateRequestBody(action: action, identity: identity, input: input, fields: fields))
        do {
            return try decoder.decode(GetEnvelope<T>.self, from: raw).data
        } catch {
            throw AshRpcError.decodingFailed(description: String(describing: error))
        }
    }

    /// Runs a destroy RPC action. `identity` is the primary-key value string.
    /// No record data is returned on success.
    public func runDestroy(action: String, identity: String) async throws {
        _ = try await sendRequest(DestroyRequestBody(action: action, identity: identity))
    }
}
