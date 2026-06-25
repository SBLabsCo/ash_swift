// "shouldPass" fixture (the AshTypescript test/ts/shouldPass analog): a
// hand-written consumer that must type-check against the generated client AND
// AshSwiftRuntime together. The codegen compile harness builds this alongside
// the generated files, so it proves the emitted surface is actually usable —
// not merely internally consistent.
//
// It is never executed; compiling it is the assertion.

import Foundation
import AshSwiftRuntime

enum ConsumerCheck {
    // Configure the client once: base URL + headers (e.g. an auth token).
    static func makeClient() -> AshRpcClient {
        let config = AshRpcConfig(
            baseURL: URL(string: "https://api.example.com")!,
            headers: ["Authorization": "Bearer token"]
        )
        return AshRpcClient(config: config, transport: URLSessionTransport())
    }

    // The generated `AshRpc` entry point exposes an async function per RPC
    // action, callable with ordinary async/await.
    static func callActions() async throws {
        let rpc = AshRpc(client: makeClient())
        try await rpc.listTodos()
        try await rpc.getTodo()
        try await rpc.createTodo()
        try await rpc.updateTodo()
        try await rpc.destroyTodo()
        try await rpc.listUsers()
        try await rpc.createUser()
    }

    // Each resource has a generated Codable model, decodable from the wire.
    static func decodeModels() throws {
        let decoder = JSONDecoder()
        _ = try decoder.decode(Todo.self, from: Data("{}".utf8))
        _ = try decoder.decode(User.self, from: Data("{}".utf8))
    }

    // A custom Transport can be injected without depending on AshSwift's default.
    struct CustomTransport: Transport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{\"success\":true,\"data\":null}".utf8), http)
        }
    }

    static func customTransport() -> AshRpc {
        let config = AshRpcConfig(baseURL: URL(string: "https://api.example.com")!)
        return AshRpc(client: AshRpcClient(config: config, transport: CustomTransport()))
    }
}
