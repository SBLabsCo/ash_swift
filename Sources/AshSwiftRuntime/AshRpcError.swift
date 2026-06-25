import Foundation

/// A single error object as returned by the backend in a failure envelope
/// (`{"success": false, "errors": [...]}`). Fields are optional because the
/// exact error shape varies by action; this is the decode-boundary view.
public struct AshRpcServerError: Codable, Sendable, Equatable {
    public let type: String?
    public let message: String?
    public let field: String?

    public init(type: String? = nil, message: String? = nil, field: String? = nil) {
        self.type = type
        self.message = message
        self.field = field
    }
}

/// Every failure the runtime can surface, thrown so callers handle them with
/// `do`/`catch` (ADR-0004).
public enum AshRpcError: Error, Sendable {
    /// The response was not an `HTTPURLResponse`.
    case invalidResponse

    /// A non-2xx HTTP status. Carries the status code and raw body.
    case httpStatus(code: Int, body: Data)

    /// The backend returned `{"success": false, "errors": [...]}`.
    case server(errors: [AshRpcServerError])

    /// The response body could not be decoded into the expected shape.
    case decodingFailed(description: String)
}
