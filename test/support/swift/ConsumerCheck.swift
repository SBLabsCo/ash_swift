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

        // Nested relationship field selection: select fields on a related resource
        // in a single call. The todo.user property decodes from the inline JSON.
        let withUser: [Todo] = try await rpc.listTodos(fields: [
            "id", "title",
            .relationship("user", ["name", "email"])
        ])
        let _ = withUser

        // Get actions return a typed single record; id is the lookup key.
        let todo: Todo = try await rpc.getTodo(id: "some-uuid")
        let _ = todo
        // findTodo uses not_found_error? false, so the return type is optional.
        let found: Todo? = try await rpc.findTodo(id: "some-uuid")
        let _ = found

        let newTodo: Todo = try await rpc.createTodo(input: CreateTodoInput(title: "New Todo"))
        let _ = newTodo
        let updatedTodo: Todo = try await rpc.updateTodo(id: "some-uuid", input: UpdateTodoInput(title: "Updated"))
        let _ = updatedTodo
        try await rpc.destroyTodo(id: "some-uuid")

        let users: [User] = try await rpc.listUsers()
        let _ = users
        let newUser: User = try await rpc.createUser(
            input: CreateUserInput(email: "test@example.com", name: "Test User")
        )
        let _ = newUser
    }

    // Generated models are all-Optional Codable structs. Absent JSON keys
    // decode as nil rather than failing — safe for ad-hoc field selection.
    static func decodeModels() throws {
        let decoder = JSONDecoder()

        // All fields present; priority is null so it decodes as nil.
        let full = try decoder.decode(
            Todo.self,
            from: Data(#"{"id":"1","title":"Buy milk","completed":false,"priority":null,"userId":null}"#.utf8)
        )
        _ = full.id
        _ = full.title
        _ = full.completed

        // Enum field: backend sends "high" as the raw string; generated TodoPriority decodes it.
        let withPriority = try decoder.decode(
            Todo.self,
            from: Data(#"{"priority":"high"}"#.utf8)
        )
        // Exhaustive switch proves all three cases exist in the generated enum.
        if let p = withPriority.priority {
            switch p {
            case .low: break
            case .medium: break
            case .high: break
            }
        }

        // Enum with keyword-named cases: backend sends "case" and "default" as raw strings.
        // The generated TodoStatus uses backtick-escaped case names so Swift accepts them.
        let withStatus = try decoder.decode(
            Todo.self,
            from: Data(#"{"status":"case"}"#.utf8)
        )
        // Exhaustive switch over all TodoStatus cases — proves `case` and `default` compile.
        if let s = withStatus.status {
            switch s {
            case .active: break
            case .archived: break
            case .`case`: break
            case .`default`: break
            case .pending: break
            }
        }

        // Partial response: fields not selected decode as nil.
        let partial = try decoder.decode(Todo.self, from: Data(#"{"id":"1","title":"Test"}"#.utf8))
        _ = partial.completed  // nil — field absent from partial response

        // Empty object: every field is nil.
        _ = try decoder.decode(Todo.self, from: Data("{}".utf8))
        _ = try decoder.decode(User.self, from: Data("{}".utf8))

        // Nested relationship: todo.user decodes from an inline user object.
        let withUser = try decoder.decode(
            Todo.self,
            from: Data(#"{"id":"1","title":"Buy milk","user":{"name":"Alice","email":"alice@example.com"}}"#.utf8)
        )
        _ = withUser.user?.name  // "Alice"
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
