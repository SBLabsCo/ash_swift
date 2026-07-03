import Foundation

/// The base RPC client the generated client builds on. Runs an `RpcRequest`:
/// encodes its body, POSTs it to the reused AshTypescript run endpoint,
/// validates the `{"success": ...}` envelope, and decodes the result — surfacing
/// failures as thrown `AshRpcError`s.
///
/// The interface is one method wide: every action shape is an `RpcRequest`
/// value (see RpcRequest.swift), not a method here. Generated per-resource code
/// stays thin — typed signatures that build a request and call `execute`.
public struct AshRpcClient: Sendable {
    public let config: AshRpcConfig
    public let transport: Transport

    // Owned once rather than per-call: this is the hot path under every
    // generated function. Symmetric with `decoder` below: an `Ash.Type.UtcDatetime`
    // / `UtcDatetimeUsec` argument is a Swift `Date`, and the backend expects it as
    // an ISO 8601 UTC string. Foundation's default `.deferredToDate` would encode a
    // bare Double (Apple reference-date seconds), which the RPC pipeline can't cast
    // to a datetime — so an action taking a `captured_at`-style `Date` argument would
    // be rejected. Encode with fractional seconds (the `UtcDatetimeUsec` shape); a
    // plain `UtcDatetime` field accepts the fractional form and truncates it.
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(fmt.string(from: date))
        }
        return e
    }()

    // Configured at init time to decode Ash.Type.UtcDatetime and
    // Ash.Type.UtcDatetimeUsec fields. Both arrive as ISO 8601 UTC strings:
    //   UtcDatetime    → "2024-01-15T10:30:00Z"
    //   UtcDatetimeUsec → "2024-01-15T10:30:00.123456Z" (with fractional seconds)
    // The custom strategy tries the fractional-second formatter first, falling
    // back to the plain one so both variants decode cleanly.
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            let fmtFrac = ISO8601DateFormatter()
            fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fmtPlain = ISO8601DateFormatter()
            fmtPlain.formatOptions = [.withInternetDateTime]
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

    /// The envelope the runtime checks for success/failure before decoding data.
    private struct Envelope: Decodable {
        let success: Bool
        let errors: [AshRpcServerError]?
    }

    /// Runs `request`: builds its body, POSTs it, validates the success
    /// envelope, and decodes the result.
    ///
    /// Throws `AshRpcError.httpStatus` for non-2xx responses, `AshRpcError.server`
    /// when the backend reports failure, and `AshRpcError.decodingFailed` when the
    /// envelope or the data payload is unintelligible.
    public func execute<R: RpcRequest>(_ request: R) async throws -> R.Output {
        let raw = try await sendRequest(request.makeBody())
        do {
            return try request.decode(from: raw, using: decoder)
        } catch {
            throw AshRpcError.decodingFailed(description: String(describing: error))
        }
    }

    /// Sends `body` to the RPC endpoint, validates the success envelope, and
    /// returns the raw response bytes. The shared wire round-trip behind `execute`.
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
}
