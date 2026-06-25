import Foundation
import XCTest
@testable import AshSwiftRuntime

/// A `Transport` that returns a canned response, so we can exercise the client
/// without a live backend.
private struct StubTransport: Transport {
    let status: Int
    let body: Data
    let onRequest: @Sendable (URLRequest) -> Void

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        onRequest(request)
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, http)
    }
}

final class AshRpcClientTests: XCTestCase {
    private func config() -> AshRpcConfig {
        AshRpcConfig(
            baseURL: URL(string: "https://example.com")!,
            headers: ["Authorization": "Bearer t"]
        )
    }

    func testRunRawPostsToResolvedEndpointWithHeaders() async throws {
        let captured = CapturedRequest()
        let stub = StubTransport(status: 200, body: Data(#"{"success":true,"data":[]}"#.utf8)) {
            captured.value = $0
        }
        let client = AshRpcClient(config: config(), transport: stub)

        _ = try await client.runRaw(action: "list_todos")

        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/rpc/run")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testRunEndpointURLPreservesBaseURLPathPrefix() {
        let config = AshRpcConfig(baseURL: URL(string: "https://example.com/api/v1")!)
        XCTAssertEqual(config.runEndpointURL.absoluteString, "https://example.com/api/v1/rpc/run")

        let trailing = AshRpcConfig(baseURL: URL(string: "https://example.com/api/v1/")!)
        XCTAssertEqual(trailing.runEndpointURL.absoluteString, "https://example.com/api/v1/rpc/run")
    }

    func testRunRawReturnsBodyOnSuccess() async throws {
        let body = Data(#"{"success":true,"data":{"id":"1"}}"#.utf8)
        let stub = StubTransport(status: 200, body: body) { _ in }
        let client = AshRpcClient(config: config(), transport: stub)

        let data = try await client.runRaw(action: "get_todo")
        XCTAssertEqual(data, body)
    }

    func testRunRawThrowsServerErrorOnFailureEnvelope() async {
        let body = Data(#"{"success":false,"errors":[{"type":"invalid","message":"nope"}]}"#.utf8)
        let stub = StubTransport(status: 200, body: body) { _ in }
        let client = AshRpcClient(config: config(), transport: stub)

        do {
            _ = try await client.runRaw(action: "create_todo")
            XCTFail("expected an error")
        } catch let AshRpcError.server(errors) {
            XCTAssertEqual(errors.first?.message, "nope")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRunRawThrowsHttpStatusOnNon2xx() async {
        let stub = StubTransport(status: 500, body: Data("boom".utf8)) { _ in }
        let client = AshRpcClient(config: config(), transport: stub)

        do {
            _ = try await client.runRaw(action: "list_todos")
            XCTFail("expected an error")
        } catch let AshRpcError.httpStatus(code, _) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

/// Reference box so the `@Sendable` capture can record the request the stub saw.
private final class CapturedRequest: @unchecked Sendable {
    var value: URLRequest?
}
