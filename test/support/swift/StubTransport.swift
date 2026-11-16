import Foundation
import AshSwiftRuntime
import GeneratedClient

// Shared Swift-side e2e harness. Copied into the consumer package's test target by
// `AshSwift.Test.SwiftConsumer.shared_package/0`.
//
// `StubTransport` returns a canned response and lets a test observe the outgoing
// request via `onRequest`. `stubRpc` wraps it in an `AshRpc`. `capturingRpc` is the
// capture half of capture-and-replay: the outgoing request body is written to
// `<package>/captured_bodies/<name>.json`, and the Elixir side replays it with
// `AshSwift.Test.SwiftConsumer.replay/1`. The canned response only needs to decode;
// the backend never sees it.

struct StubTransport: Transport {
    var status: Int = 200
    let body: Data
    var onRequest: @Sendable (URLRequest) throws -> Void = { _ in }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try onRequest(request)
        let http = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, http)
    }
}

func stubRpc(_ transport: StubTransport, headers: [String: String] = [:]) -> AshRpc {
    let config = AshRpcConfig(baseURL: URL(string: "https://example.com")!, headers: headers)
    return AshRpc(client: AshRpcClient(config: config, transport: transport))
}

func stubRpc(body: Data) -> AshRpc {
    stubRpc(StubTransport(body: body))
}

/// `<package>/captured_bodies`, derived from this file's own location
/// (`<package>/Tests/E2ETests/StubTransport.swift`).
private let bodiesDirectory: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("captured_bodies")

func capturingRpc(_ name: String, _ response: String) -> AshRpc {
    stubRpc(
        StubTransport(body: Data(response.utf8)) { request in
            try FileManager.default.createDirectory(
                at: bodiesDirectory, withIntermediateDirectories: true)
            try request.httpBody!.write(
                to: bodiesDirectory.appendingPathComponent("\(name).json"))
        })
}
