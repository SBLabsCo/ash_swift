import Foundation

/// Static configuration for the generated client: where the backend lives and
/// what headers every request carries.
///
/// M1 covers static base-URL and header configuration only; a lifecycle-hooks
/// framework (dynamic per-request config) is a later milestone.
public struct AshRpcConfig: Sendable {
    /// The backend's base URL, e.g. `https://api.example.com`.
    public var baseURL: URL

    /// The RPC endpoint path appended to `baseURL`, matching the reused
    /// AshTypescript run endpoint (ADR-0003). Defaults to `/rpc/run`.
    public var runEndpointPath: String

    /// Headers attached to every request, e.g. an auth bearer token.
    public var headers: [String: String]

    public init(
        baseURL: URL,
        runEndpointPath: String = "/rpc/run",
        headers: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        self.runEndpointPath = runEndpointPath
        self.headers = headers
    }

    /// The fully resolved URL the client POSTs RPC requests to.
    ///
    /// Appends `runEndpointPath` to `baseURL` while preserving any path the
    /// base URL already carries (e.g. `https://host/v1` + `/rpc/run` →
    /// `https://host/v1/rpc/run`), so a base URL with a prefix is not silently
    /// discarded.
    public var runEndpointURL: URL {
        var base = baseURL.absoluteString
        if base.hasSuffix("/") {
            base.removeLast()
        }
        let path = runEndpointPath.hasPrefix("/") ? runEndpointPath : "/" + runEndpointPath
        return URL(string: base + path) ?? baseURL
    }
}
