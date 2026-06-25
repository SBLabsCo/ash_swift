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
    // action. List actions accept a field selection list and return typed arrays;
    // other action types keep the simple void signature for M1.
    static func callActions() async throws {
        let rpc = AshRpc(client: makeClient())

        // List actions return a typed array; field selection is optional.
        let todos: [Todo] = try await rpc.listTodos()
        let _ = todos
        let selected: [Todo] = try await rpc.listTodos(fields: ["id", "title"])
        let _ = selected

        // Non-list actions keep their M1 void signature.
        try await rpc.getTodo()
        try await rpc.createTodo()
        try await rpc.updateTodo()
        try await rpc.destroyTodo()

        let users: [User] = try await rpc.listUsers()
        let _ = users
        try await rpc.createUser()
    }

    // Generated models are all-Optional Codable structs. Absent JSON keys
    // decode as nil rather than failing — safe for ad-hoc field selection.
    static func decodeModels() throws {
        let decoder = JSONDecoder()

        // All fields present.
        let full = try decoder.decode(
            Todo.self,
            from: Data(#"{"id":"1","title":"Buy milk","completed":false,"priority":null,"userId":null}"#.utf8)
        )
        _ = full.id
        _ = full.title
        _ = full.completed

        // Partial response: fields not selected decode as nil.
        let partial = try decoder.decode(Todo.self, from: Data(#"{"id":"1","title":"Test"}"#.utf8))
        _ = partial.completed  // nil — field absent from partial response

        // Empty object: every field is nil.
        _ = try decoder.decode(Todo.self, from: Data("{}".utf8))
        _ = try decoder.decode(User.self, from: Data("{}".utf8))
    }

    // A custom Transport can be injected without depending on AshSwift's default.
    struct CustomTransport: Transport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"success":true,"data":[]}"#.utf8), http)
        }
    }

    static func customTransport() -> AshRpc {
        let config = AshRpcConfig(baseURL: URL(string: "https://api.example.com")!)
        return AshRpc(client: AshRpcClient(config: config, transport: CustomTransport()))
    }
}
