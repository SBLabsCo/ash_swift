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
    private let decoder = JSONDecoder()

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

    /// The envelope the runtime checks for success/failure before returning data.
    private struct Envelope: Decodable {
        let success: Bool
        let errors: [AshRpcServerError]?
    }

    /// Typed envelope for decoding a list data payload.
    private struct ListEnvelope<T: Decodable>: Decodable {
        let data: [T]
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
}
