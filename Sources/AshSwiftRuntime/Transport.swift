import Foundation

/// The pluggable HTTP layer the runtime uses to actually send a request
/// (ADR-0004). The default implementation is `URLSessionTransport`; callers who
/// standardize on another networking stack (e.g. Alamofire) or need
/// interceptors can supply their own conforming type without AshSwift forcing a
/// dependency on anyone.
public protocol Transport: Sendable {
    /// Sends `request` and returns the response body together with the HTTP
    /// response. Implementations should surface network-level failures as a
    /// thrown error.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
