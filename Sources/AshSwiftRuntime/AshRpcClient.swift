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

    /// The request body the client POSTs. Wire-identical to what any
    /// AshTypescript client sends, by construction (ADR-0003).
    private struct RequestBody: Encodable {
        let action: String
        let fields: [String]
    }

    /// The envelope the runtime checks for success/failure before returning data.
    private struct Envelope: Decodable {
        let success: Bool
        let errors: [AshRpcServerError]?
    }

    /// Typed envelope for decoding a list data payload after `runRaw` validates
    /// the success flag. Generic so each generated list function gets its type.
    private struct ListEnvelope<T: Decodable>: Decodable {
        let data: [T]
    }

    /// Runs an RPC action and returns the raw response body on success.
    ///
    /// Validates the envelope: throws `AshRpcError.httpStatus` for non-2xx
    /// responses, `AshRpcError.server` when the backend reports failure, and
    /// `AshRpcError.decodingFailed` when the envelope is unintelligible.
    @discardableResult
    public func runRaw(action: String, fields: [String] = []) async throws -> Data {
        var request = URLRequest(url: config.runEndpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try encoder.encode(RequestBody(action: action, fields: fields))

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

    /// Runs a list RPC action and decodes the `data` array from the response
    /// envelope into `[T]`. The caller supplies `T` through the return-type
    /// context; no type parameter is needed at the call site.
    public func runList<T: Decodable>(action: String, fields: [String] = []) async throws -> [T] {
        let raw = try await runRaw(action: action, fields: fields)
        do {
            return try decoder.decode(ListEnvelope<T>.self, from: raw).data
        } catch {
            throw AshRpcError.decodingFailed(description: String(describing: error))
        }
    }
}
