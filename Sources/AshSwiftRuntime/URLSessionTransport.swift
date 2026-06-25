import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The default `Transport`: a zero-dependency `URLSession` implementation
/// (ADR-0004). Adopting AshSwift adds no supply-chain surface.
public struct URLSessionTransport: Transport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AshRpcError.invalidResponse
        }

        return (data, http)
    }
}
