import Foundation
import AshSwiftRuntime
import GeneratedClient

// Shared capture half of the e2e capture-and-replay harness. Copied into the
// consumer package's test target by `AshSwift.Test.SwiftConsumer.shared_package/0`.
//
// A test builds an `AshRpc` with `capturingRpc(name, response)`, calls a generated
// function, and the outgoing request body is written to
// `<package>/captured_bodies/<name>.json`. The Elixir side replays it with
// `AshSwift.Test.SwiftConsumer.replay/2`. The canned `response` only needs to
// decode; the backend never sees it.

struct CapturingTransport: Transport {
    let response: String
    let name: String

    /// `<package>/captured_bodies`, derived from this file's own location
    /// (`<package>/Tests/E2ETests/CapturingTransport.swift`).
    static let bodiesDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("captured_bodies")

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try FileManager.default.createDirectory(
            at: Self.bodiesDirectory, withIntermediateDirectories: true)
        try request.httpBody!.write(
            to: Self.bodiesDirectory.appendingPathComponent("\(name).json"))
        let http = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(response.utf8), http)
    }
}

func capturingRpc(_ name: String, _ response: String) -> AshRpc {
    let config = AshRpcConfig(baseURL: URL(string: "https://example.com")!)
    return AshRpc(
        client: AshRpcClient(
            config: config, transport: CapturingTransport(response: response, name: name)))
}
