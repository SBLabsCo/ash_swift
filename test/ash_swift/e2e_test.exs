defmodule AshSwift.E2ETest do
  @moduledoc """
  End-to-end wire compatibility: runs actions in-process through the reused
  AshTypescript RPC pipeline, then verifies generated Swift models can decode
  the real JSON responses.

  This proves that the Elixir backend and the generated Swift client agree on
  the wire — not just that the Swift code compiles, but that it correctly
  decodes what the backend actually produces.
  """
  use ExUnit.Case, async: false

  alias AshSwift.Codegen

  @domains [AshSwift.Test.Domain]
  @moduletag :swift_build

  test "generated Swift list function decodes real RPC pipeline JSON" do
    repo_root = File.cwd!()
    tmp = make_consumer_package(repo_root)
    sources = Path.join([tmp, "Sources", "GeneratedClient"])
    tests_dir = Path.join([tmp, "Tests", "E2ETests"])
    File.mkdir_p!(tests_dir)

    # Generate the Swift types and functions into the consumer package.
    assert {:ok, written} = Codegen.generate(@domains, sources)
    assert "AshRpcTypes.swift" in written
    assert "AshRpcFunctions.swift" in written

    # Create a todo (owned by a user) in-process using the ETS-backed data layer.
    # Assigning an owner lets us select the multi-word `user_id` field below, which
    # exercises the snake_case -> camelCase wire mapping end to end.
    user =
      Ash.create!(AshSwift.Test.User, %{name: "Owner", email: "owner@example.com"},
        domain: AshSwift.Test.Domain
      )

    Ash.create!(AshSwift.Test.Todo, %{title: "E2E Todo", completed: true, user_id: user.id},
      domain: AshSwift.Test.Domain
    )

    # Run the list action through the real AshTypescript RPC pipeline.
    # A minimal Plug.Conn suffices — no auth needed for these fixture actions.
    # `userId` is sent in client (camelCase) format, the way the Swift client emits
    # it; the pipeline parses it back to `user_id` and formats the response key as
    # `userId`, which must match the generated Swift property name.
    conn = %Plug.Conn{private: %{}, assigns: %{}}
    params = %{"action" => "list_todos", "fields" => ["id", "title", "completed", "userId"]}
    rpc_result = AshTypescript.Rpc.run_action(:ash_swift, conn, params)

    assert rpc_result["success"] == true
    assert is_list(rpc_result["data"]) and rpc_result["data"] != []

    # Encode the real pipeline response as JSON — this is the exact wire format
    # the Swift client will see in production.
    json = Jason.encode!(rpc_result)

    # Write a Swift XCTest that decodes the real JSON with the generated model.
    # Using a raw string literal so the JSON embeds cleanly into Swift source.
    e2e_swift = """
    import XCTest
    import Foundation
    import AshSwiftRuntime
    import GeneratedClient

    // Decodes a real JSON response from the AshTypescript RPC pipeline using
    // the generated Swift model, proving the server and client are wire-compatible.
    final class E2EDecodeTest: XCTestCase {
        func testListResponseDecodesIntoGeneratedModel() throws {
            let json = #{inspect(json, binaries: :as_strings)}
            let raw = Data(json.utf8)

            struct ListEnvelope: Decodable {
                let success: Bool
                let data: [Todo]
            }

            let envelope = try JSONDecoder().decode(ListEnvelope.self, from: raw)

            XCTAssertTrue(envelope.success)
            XCTAssertFalse(envelope.data.isEmpty)

            let first = try XCTUnwrap(envelope.data.first)
            XCTAssertNotNil(first.id)
            XCTAssertEqual(first.title, "E2E Todo")
            XCTAssertEqual(first.completed, true)
            // user_id is serialized as the camelCased key `userId` on the wire;
            // the generated property name must match it exactly, or this decodes
            // as nil instead of the owner's id.
            XCTAssertEqual(first.userId, #{inspect(to_string(user.id))})
            // priority was not requested — absent keys decode as nil, not an error.
            XCTAssertNil(first.priority)
        }
    }
    """

    File.write!(Path.join(tests_dir, "E2EDecodeTest.swift"), e2e_swift)

    {output, status} =
      System.cmd("swift", ["test", "--filter", "E2EDecodeTest"], cd: tmp, stderr_to_stdout: true)

    assert status == 0, "swift test failed:\n#{output}"
  end

  test "generated Swift model decodes nested relationship data" do
    repo_root = File.cwd!()
    tmp = make_consumer_package(repo_root)
    sources = Path.join([tmp, "Sources", "GeneratedClient"])
    tests_dir = Path.join([tmp, "Tests", "E2ETests"])
    File.mkdir_p!(tests_dir)

    assert {:ok, _written} = Codegen.generate(@domains, sources)

    # Create a user and a todo that belongs to that user.
    user =
      Ash.create!(AshSwift.Test.User, %{name: "Nested Owner", email: "nested@example.com"},
        domain: AshSwift.Test.Domain
      )

    Ash.create!(AshSwift.Test.Todo, %{title: "Nested Todo", user_id: user.id},
      domain: AshSwift.Test.Domain
    )

    # Request the todo list with nested user fields — the wire format passes
    # relationship field selection as a map inside the fields array.
    conn = %Plug.Conn{private: %{}, assigns: %{}}

    params = %{
      "action" => "list_todos",
      "fields" => ["id", "title", %{"user" => ["name", "email"]}]
    }

    rpc_result = AshTypescript.Rpc.run_action(:ash_swift, conn, params)

    assert rpc_result["success"] == true
    data = rpc_result["data"]
    assert is_list(data) and data != []

    json = Jason.encode!(rpc_result)

    # The Swift XCTest decodes the response and asserts the nested User struct
    # populated on todo.user, proving full round-trip wire compatibility.
    e2e_swift = """
    import XCTest
    import Foundation
    import AshSwiftRuntime
    import GeneratedClient

    final class E2ENestedRelationshipTest: XCTestCase {
        func testNestedRelationshipDecodesIntoGeneratedModel() throws {
            let json = #{inspect(json, binaries: :as_strings)}
            let raw = Data(json.utf8)

            struct ListEnvelope: Decodable {
                let success: Bool
                let data: [Todo]
            }

            let envelope = try JSONDecoder().decode(ListEnvelope.self, from: raw)

            XCTAssertTrue(envelope.success)
            XCTAssertFalse(envelope.data.isEmpty)

            // Find the todo we created for this test (ETS may have others from
            // the concurrent scalar E2E test).
            let todo = try XCTUnwrap(
                envelope.data.first(where: { $0.title == "Nested Todo" })
            )

            // Nested relationship: todo.user should be populated.
            let nestedUser = try XCTUnwrap(todo.user)
            XCTAssertEqual(nestedUser.name, "Nested Owner")
            XCTAssertEqual(nestedUser.email, "nested@example.com")

            // The scalar userId was not requested in this call — it decodes as nil.
            XCTAssertNil(todo.userId)
        }
    }
    """

    File.write!(Path.join(tests_dir, "E2ENestedRelationshipTest.swift"), e2e_swift)

    {output, status} =
      System.cmd("swift", ["test", "--filter", "E2ENestedRelationshipTest"],
        cd: tmp,
        stderr_to_stdout: true
      )

    assert status == 0, "swift test failed:\n#{output}"
  end

  test "generated Swift enum decodes from real backend enum value" do
    repo_root = File.cwd!()
    tmp = make_consumer_package(repo_root)
    sources = Path.join([tmp, "Sources", "GeneratedClient"])
    tests_dir = Path.join([tmp, "Tests", "E2ETests"])
    File.mkdir_p!(tests_dir)

    assert {:ok, written} = Codegen.generate(@domains, sources)
    assert "AshRpcTypes.swift" in written

    # Create a todo with an explicit priority value so the wire format carries
    # the enum string ("high") and proves the generated Swift enum decodes it.
    Ash.create!(AshSwift.Test.Todo, %{title: "Enum Todo", priority: :high},
      domain: AshSwift.Test.Domain
    )

    conn = %Plug.Conn{private: %{}, assigns: %{}}
    params = %{"action" => "list_todos", "fields" => ["id", "title", "priority"]}
    rpc_result = AshTypescript.Rpc.run_action(:ash_swift, conn, params)

    assert rpc_result["success"] == true
    data = rpc_result["data"]
    assert is_list(data) and data != []

    json = Jason.encode!(rpc_result)

    e2e_swift = """
    import XCTest
    import Foundation
    import AshSwiftRuntime
    import GeneratedClient

    // Decodes the backend's enum wire value ("high") into the generated TodoPriority
    // Swift enum, proving end-to-end enum wire compatibility.
    final class E2EEnumDecodeTest: XCTestCase {
        func testEnumFieldDecodesFromBackendResponse() throws {
            let json = #{inspect(json, binaries: :as_strings)}
            let raw = Data(json.utf8)

            struct ListEnvelope: Decodable {
                let success: Bool
                let data: [Todo]
            }

            let envelope = try JSONDecoder().decode(ListEnvelope.self, from: raw)
            XCTAssertTrue(envelope.success)

            let enumTodo = try XCTUnwrap(
                envelope.data.first(where: { $0.title == "Enum Todo" })
            )

            // The backend serialises :high as "high"; the generated enum must decode it.
            XCTAssertEqual(enumTodo.priority, .high)

            // Exhaustive switch — proves the generated enum has all three cases.
            let priority = try XCTUnwrap(enumTodo.priority)
            switch priority {
            case .low: break
            case .medium: break
            case .high: break
            }
        }
    }
    """

    File.write!(Path.join(tests_dir, "E2EEnumDecodeTest.swift"), e2e_swift)

    {output, status} =
      System.cmd("swift", ["test", "--filter", "E2EEnumDecodeTest"],
        cd: tmp,
        stderr_to_stdout: true
      )

    assert status == 0, "swift test failed:\n#{output}"
  end

  test "get action: single-record retrieval and not-found path exercise both not_found_error? behaviors" do
    repo_root = File.cwd!()
    tmp = make_consumer_package(repo_root)
    sources = Path.join([tmp, "Sources", "GeneratedClient"])
    tests_dir = Path.join([tmp, "Tests", "E2ETests"])
    File.mkdir_p!(tests_dir)

    assert {:ok, _written} = Codegen.generate(@domains, sources)

    # Create a record so we can retrieve it by id.
    todo =
      Ash.create!(AshSwift.Test.Todo, %{title: "Get E2E Todo"}, domain: AshSwift.Test.Domain)

    todo_id = to_string(todo.id)

    conn = %Plug.Conn{private: %{}, assigns: %{}}

    # --- Successful get (not_found_error? true by default) ---
    get_params = %{
      "action" => "get_todo",
      "input" => %{"id" => todo_id},
      "fields" => ["id", "title"]
    }

    get_result = AshTypescript.Rpc.run_action(:ash_swift, conn, get_params)
    assert get_result["success"] == true
    assert is_map(get_result["data"])

    get_json = Jason.encode!(get_result)

    # --- Not-found path (not_found_error? false — returns null data) ---
    nonexistent_id = Ash.UUID.generate()

    find_params = %{
      "action" => "find_todo",
      "input" => %{"id" => nonexistent_id},
      "fields" => ["id"]
    }

    find_result = AshTypescript.Rpc.run_action(:ash_swift, conn, find_params)
    assert find_result["success"] == true
    assert find_result["data"] == nil

    find_json = Jason.encode!(find_result)

    e2e_swift = """
    import XCTest
    import Foundation
    import AshSwiftRuntime
    import GeneratedClient

    // Verifies that the get action response decodes into a single typed record and
    // that the not-found path produces nil for actions with not_found_error? false.
    final class E2EGetActionTest: XCTestCase {
        func testGetSuccessDecodesIntoTypedRecord() throws {
            let json = #{inspect(get_json, binaries: :as_strings)}
            let raw = Data(json.utf8)

            struct GetEnvelope: Decodable {
                let success: Bool
                let data: Todo
            }

            let envelope = try JSONDecoder().decode(GetEnvelope.self, from: raw)
            XCTAssertTrue(envelope.success)
            XCTAssertEqual(envelope.data.title, "Get E2E Todo")
            XCTAssertEqual(envelope.data.id, #{inspect(todo_id)})
        }

        func testGetNotFoundDecodesAsNil() throws {
            let json = #{inspect(find_json, binaries: :as_strings)}
            let raw = Data(json.utf8)

            struct GetOptionalEnvelope: Decodable {
                let success: Bool
                let data: Todo?
            }

            let envelope = try JSONDecoder().decode(GetOptionalEnvelope.self, from: raw)
            XCTAssertTrue(envelope.success)
            XCTAssertNil(envelope.data)
        }
    }
    """

    File.write!(Path.join(tests_dir, "E2EGetActionTest.swift"), e2e_swift)

    {output, status} =
      System.cmd("swift", ["test", "--filter", "E2EGetActionTest"],
        cd: tmp,
        stderr_to_stdout: true
      )

    assert status == 0, "swift test failed:\n#{output}"
  end

  test "create, update, and destroy actions encode correctly and return typed records" do
    repo_root = File.cwd!()
    tmp = make_consumer_package(repo_root)
    sources = Path.join([tmp, "Sources", "GeneratedClient"])
    tests_dir = Path.join([tmp, "Tests", "E2ETests"])
    File.mkdir_p!(tests_dir)

    assert {:ok, _written} = Codegen.generate(@domains, sources)

    conn = %Plug.Conn{private: %{}, assigns: %{}}

    # --- Create ---
    create_params = %{
      "action" => "create_todo",
      "input" => %{"title" => "E2E Create Todo", "completed" => false},
      "fields" => ["id", "title", "completed"]
    }

    create_result = AshTypescript.Rpc.run_action(:ash_swift, conn, create_params)
    assert create_result["success"] == true
    assert is_map(create_result["data"])
    todo_id = create_result["data"]["id"]
    assert todo_id != nil

    create_json = Jason.encode!(create_result)

    # --- Update ---
    # The AshTypescript RPC wire protocol uses `identity` (not `input`) to
    # identify the record for update/destroy actions (ADR-0003).
    update_params = %{
      "action" => "update_todo",
      "identity" => todo_id,
      "input" => %{"title" => "E2E Updated Todo"},
      "fields" => ["id", "title", "completed"]
    }

    update_result = AshTypescript.Rpc.run_action(:ash_swift, conn, update_params)
    assert update_result["success"] == true
    assert update_result["data"]["title"] == "E2E Updated Todo"

    update_json = Jason.encode!(update_result)

    # --- Destroy ---
    destroy_params = %{
      "action" => "destroy_todo",
      "identity" => todo_id
    }

    destroy_result = AshTypescript.Rpc.run_action(:ash_swift, conn, destroy_params)
    assert destroy_result["success"] == true

    destroy_json = Jason.encode!(destroy_result)

    e2e_swift = """
    import XCTest
    import Foundation
    import AshSwiftRuntime
    import GeneratedClient

    // Verifies that create/update/destroy wire responses decode via generated types
    // and that the generated input struct API compiles with typed, checked calls.
    final class E2EMutationTest: XCTestCase {
        func testCreateResponseDecodesIntoTypedRecord() throws {
            let json = #{inspect(create_json, binaries: :as_strings)}
            let raw = Data(json.utf8)

            struct CreateEnvelope: Decodable {
                let success: Bool
                let data: Todo
            }

            let envelope = try JSONDecoder().decode(CreateEnvelope.self, from: raw)
            XCTAssertTrue(envelope.success)
            XCTAssertEqual(envelope.data.title, "E2E Create Todo")
            XCTAssertEqual(envelope.data.completed, false)
            XCTAssertNotNil(envelope.data.id)
        }

        func testUpdateResponseDecodesIntoTypedRecord() throws {
            let json = #{inspect(update_json, binaries: :as_strings)}
            let raw = Data(json.utf8)

            struct UpdateEnvelope: Decodable {
                let success: Bool
                let data: Todo
            }

            let envelope = try JSONDecoder().decode(UpdateEnvelope.self, from: raw)
            XCTAssertTrue(envelope.success)
            XCTAssertEqual(envelope.data.title, "E2E Updated Todo")
        }

        func testDestroyResponseIsSuccess() throws {
            let json = #{inspect(destroy_json, binaries: :as_strings)}
            let raw = Data(json.utf8)

            // Destroy returns {"success": true, "data": {}}; ignore `data` by
            // not including it in the struct — Codable silently skips extra keys.
            struct DestroyEnvelope: Decodable {
                let success: Bool
            }

            let envelope = try JSONDecoder().decode(DestroyEnvelope.self, from: raw)
            XCTAssertTrue(envelope.success)
        }

        // Compile-time check: the generated input struct API must accept required
        // and optional parameters correctly — the type checker is the real assertion.
        func testInputStructsCompileWithTypedParams() {
            let _create = CreateTodoInput(title: "Required title only")
            let _createFull = CreateTodoInput(
                title: "Full",
                completed: true,
                priority: .high
            )
            let _update = UpdateTodoInput(title: "Partial update")
            let _updateEmpty = UpdateTodoInput()
            let _createUser = CreateUserInput(email: "a@b.com", name: "Alice")
        }
    }
    """

    File.write!(Path.join(tests_dir, "E2EMutationTest.swift"), e2e_swift)

    {output, status} =
      System.cmd("swift", ["test", "--filter", "E2EMutationTest"],
        cd: tmp,
        stderr_to_stdout: true
      )

    assert status == 0, "swift test failed:\n#{output}"
  end

  test "custom headers are forwarded on generated calls; backend errors surface as typed AshRpcError" do
    repo_root = File.cwd!()
    tmp = make_consumer_package(repo_root)
    sources = Path.join([tmp, "Sources", "GeneratedClient"])
    tests_dir = Path.join([tmp, "Tests", "E2ETests"])
    File.mkdir_p!(tests_dir)

    assert {:ok, _written} = Codegen.generate(@domains, sources)

    # This test exercises the two acceptance criteria (stories 24, 25 in the PRD)
    # through the *generated* AshRpc client, not the runtime directly:
    #   1. A bearer token set in AshRpcConfig.headers reaches every request the
    #      generated function sends (header forwarding).
    #   2. When the backend returns {"success": false, ...}, the generated call
    #      throws AshRpcError.server with the decoded error list (typed error).
    e2e_swift = """
    import XCTest
    import Foundation
    import AshSwiftRuntime
    import GeneratedClient

    // Verifies that AshRpcConfig.headers are forwarded on calls made through the
    // generated AshRpc client, and that {"success":false} responses surface as a
    // thrown AshRpcError.server value with the decoded server errors.
    final class E2EHeadersAndErrorsTest: XCTestCase {
        // Stub transport used in both tests: captures the outgoing request and
        // returns a caller-supplied canned response.
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

        private final class CapturedRequest: @unchecked Sendable {
            var value: URLRequest?
        }

        // AshRpcConfig.headers must appear on every request the generated AshRpc
        // function sends. This is story 24: callers set the bearer token once in
        // config and every generated call carries it automatically.
        func testAuthHeaderForwardedOnGeneratedListCall() async throws {
            let captured = CapturedRequest()
            let stub = StubTransport(
                status: 200,
                body: Data(#"{"success":true,"data":[]}"#.utf8)
            ) { captured.value = $0 }

            let config = AshRpcConfig(
                baseURL: URL(string: "https://example.com")!,
                headers: ["Authorization": "Bearer secret-token"]
            )
            let rpc = AshRpc(client: AshRpcClient(config: config, transport: stub))

            let _: [Todo] = try await rpc.listTodos()

            let request = try XCTUnwrap(captured.value)
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer secret-token"
            )
            // Confirm the generated wrapper sent the right action name — the unique
            // E2E value here vs. the runtime unit tests that already cover header
            // forwarding.
            let bodyJSON = try JSONSerialization.jsonObject(
                with: try XCTUnwrap(request.httpBody)
            ) as! [String: Any]
            XCTAssertEqual(bodyJSON["action"] as? String, "list_todos")
        }

        // Story 25: when the backend returns {"success":false,"errors":[...]}, the
        // generated call must throw AshRpcError.server so callers can match on it
        // in a do/catch block and inspect the typed server errors.
        func testBackendErrorSurfacesAsTypedAshRpcError() async {
            let errorBody = Data(#"{"success":false,"errors":[{"type":"unauthorized","message":"not allowed","field":null}]}"#.utf8)
            let stub = StubTransport(status: 200, body: errorBody) { _ in }

            let config = AshRpcConfig(baseURL: URL(string: "https://example.com")!)
            let rpc = AshRpc(client: AshRpcClient(config: config, transport: stub))

            do {
                let _: [Todo] = try await rpc.listTodos()
                XCTFail("expected AshRpcError.server to be thrown")
            } catch let AshRpcError.server(errors) {
                XCTAssertEqual(errors.first?.type, "unauthorized")
                XCTAssertEqual(errors.first?.message, "not allowed")
            } catch {
                XCTFail("unexpected error type: \\(error)")
            }
        }
    }
    """

    File.write!(Path.join(tests_dir, "E2EHeadersAndErrorsTest.swift"), e2e_swift)

    {output, status} =
      System.cmd("swift", ["test", "--filter", "E2EHeadersAndErrorsTest"],
        cd: tmp,
        stderr_to_stdout: true
      )

    assert status == 0, "swift test failed:\n#{output}"
  end

  test "offset-paginated action decodes real backend JSON into OffsetPage<T>" do
    repo_root = File.cwd!()
    tmp = make_consumer_package(repo_root)
    sources = Path.join([tmp, "Sources", "GeneratedClient"])
    tests_dir = Path.join([tmp, "Tests", "E2ETests"])
    File.mkdir_p!(tests_dir)

    assert {:ok, _written} = Codegen.generate(@domains, sources)

    # Create several todos so the paginated response contains results.
    for i <- 1..3 do
      Ash.create!(AshSwift.Test.Todo, %{title: "Paged Todo #{i}"}, domain: AshSwift.Test.Domain)
    end

    conn = %Plug.Conn{private: %{}, assigns: %{}}

    # list_todos_offset uses the :list_offset_paginated action which requires
    # pagination — the backend always returns the paginated envelope shape.
    params = %{
      "action" => "list_todos_offset",
      "fields" => ["id", "title"],
      "page" => %{"limit" => 2, "offset" => 0}
    }

    rpc_result = AshTypescript.Rpc.run_action(:ash_swift, conn, params)

    assert rpc_result["success"] == true
    data = rpc_result["data"]
    assert is_map(data)
    assert is_list(data["results"])
    assert data["results"] != []
    assert is_boolean(data["hasMore"])

    json = Jason.encode!(rpc_result)

    e2e_swift = """
    import XCTest
    import Foundation
    import AshSwiftRuntime
    import GeneratedClient

    // Decodes a real paginated JSON response from the AshTypescript RPC pipeline
    // using the generated OffsetPage<Todo> type, proving wire compatibility for
    // offset-paginated read actions (issue #16).
    final class E2EOffsetPageTest: XCTestCase {
        func testOffsetPageResponseDecodesIntoGeneratedModel() throws {
            let json = #{inspect(json, binaries: :as_strings)}
            let raw = Data(json.utf8)

            struct PageEnvelope: Decodable {
                let success: Bool
                let data: OffsetPage<Todo>
            }

            let envelope = try JSONDecoder().decode(PageEnvelope.self, from: raw)

            XCTAssertTrue(envelope.success)
            XCTAssertFalse(envelope.data.results.isEmpty)

            // Pagination metadata must match the requested page params.
            XCTAssertEqual(envelope.data.limit, 2)
            XCTAssertEqual(envelope.data.offset, 0)
            XCTAssertLessThanOrEqual(envelope.data.results.count, 2)

            let first = try XCTUnwrap(envelope.data.results.first)
            XCTAssertNotNil(first.id)
            XCTAssertNotNil(first.title)
        }
    }
    """

    File.write!(Path.join(tests_dir, "E2EOffsetPageTest.swift"), e2e_swift)

    {output, status} =
      System.cmd("swift", ["test", "--filter", "E2EOffsetPageTest"],
        cd: tmp,
        stderr_to_stdout: true
      )

    assert status == 0, "swift test failed:\n#{output}"
  end

  test "extended Ash types (Decimal, Date, UtcDatetime, UtcDatetimeUsec, Map) decode from real pipeline JSON" do
    repo_root = File.cwd!()
    tmp = make_consumer_package(repo_root)
    sources = Path.join([tmp, "Sources", "GeneratedClient"])
    tests_dir = Path.join([tmp, "Tests", "E2ETests"])
    File.mkdir_p!(tests_dir)

    assert {:ok, _written} = Codegen.generate(@domains, sources)

    # Create a record with every extended-type field populated. Values chosen so
    # each one round-trips through Jason.encode!/1 and reaches the Swift decoder.
    #   deadline  → Ash.Type.Date       → JSON string "2024-06-15"
    #   scheduled_at → Ash.Type.UtcDatetime → JSON string "2024-06-15T10:30:00Z"
    #   due_at    → Ash.Type.UtcDatetimeUsec → JSON string "2024-06-15T10:30:00.123456Z"
    #   started_at → Ash.Type.NaiveDatetime → JSON string "2024-06-15T09:00:00"
    #   amount    → Ash.Type.Decimal    → JSON string "99.99"
    #   metadata  → Ash.Type.Map        → JSON object {"label":"urgent","count":3}
    Ash.create!(
      AshSwift.Test.Todo,
      %{
        title: "Extended Types Todo",
        deadline: ~D[2024-06-15],
        scheduled_at: ~U[2024-06-15 10:30:00Z],
        due_at: ~U[2024-06-15 10:30:00.123456Z],
        started_at: ~N[2024-06-15 09:00:00],
        amount: Decimal.new("99.99"),
        metadata: %{"label" => "urgent", "count" => 3}
      },
      domain: AshSwift.Test.Domain
    )

    conn = %Plug.Conn{private: %{}, assigns: %{}}

    params = %{
      "action" => "list_todos",
      "fields" => [
        "id",
        "title",
        "deadline",
        "scheduledAt",
        "dueAt",
        "startedAt",
        "amount",
        "metadata"
      ]
    }

    rpc_result = AshTypescript.Rpc.run_action(:ash_swift, conn, params)
    assert rpc_result["success"] == true
    data = rpc_result["data"]
    assert is_list(data) and data != []

    json = Jason.encode!(rpc_result)

    e2e_swift = """
    import XCTest
    import Foundation
    import AshSwiftRuntime
    import GeneratedClient

    // Verifies that the extended Ash type mappings (issue #17) round-trip through
    // the real RPC pipeline and decode cleanly into the generated Swift types:
    //   Ash.Type.Decimal        → String  (JSON string "99.99")
    //   Ash.Type.Date           → String  (ISO 8601 date "2024-06-15")
    //   Ash.Type.UtcDatetime    → Date    (ISO 8601 UTC datetime)
    //   Ash.Type.UtcDatetimeUsec → Date   (ISO 8601 UTC datetime with μs)
    //   Ash.Type.NaiveDatetime  → String  (ISO 8601 no-timezone datetime)
    //   Ash.Type.Map            → [String: AshJSON] (arbitrary JSON object)
    final class E2EExtendedTypesTest: XCTestCase {
        func testExtendedTypeFieldsDecodeFromRealPipelineJSON() throws {
            let json = #{inspect(json, binaries: :as_strings)}
            let raw = Data(json.utf8)

            struct ListEnvelope: Decodable {
                let success: Bool
                let data: [Todo]
            }

            let decoder = JSONDecoder()
            // Note: this decoder mirrors the custom ISO 8601 strategy that AshRpcClient
            // configures in production (AshRpcClient.swift). It proves the JSON payload
            // is decodable, but does NOT exercise AshRpcClient's own decoder
            // configuration. A regression in AshRpcClient.swift's dateDecodingStrategy
            // would not be caught here — the in-process test setup has no HTTP path
            // to route through the real client.
            let fmtFrac = ISO8601DateFormatter()
            fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fmtPlain = ISO8601DateFormatter()
            fmtPlain.formatOptions = [.withInternetDateTime]
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let str = try container.decode(String.self)
                if let d = fmtFrac.date(from: str) { return d }
                if let d = fmtPlain.date(from: str) { return d }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Cannot decode Date from: \\(str)"
                )
            }

            let envelope = try decoder.decode(ListEnvelope.self, from: raw)
            XCTAssertTrue(envelope.success)

            let todo = try XCTUnwrap(
                envelope.data.first(where: { $0.title == "Extended Types Todo" })
            )

            // Decimal → String: raw decimal string preserved without precision loss
            XCTAssertEqual(todo.amount, "99.99")

            // Date (date-only) → String: ISO 8601 date
            XCTAssertEqual(todo.deadline, "2024-06-15")

            // UtcDatetime → Date: decoded via ISO8601DateFormatter
            let scheduledAt = try XCTUnwrap(todo.scheduledAt)
            // Round-trip: 2024-06-15T10:30:00Z — check year component as proxy
            let cal = Calendar(identifier: .iso8601)
            XCTAssertEqual(cal.component(.year, from: scheduledAt), 2024)

            // UtcDatetimeUsec → Date: fractional-second variant also decodes
            let dueAt = try XCTUnwrap(todo.dueAt)
            XCTAssertEqual(cal.component(.year, from: dueAt), 2024)

            // NaiveDatetime → String: no timezone, kept as raw ISO 8601 string
            XCTAssertEqual(todo.startedAt, "2024-06-15T09:00:00")

            // Map → [String: AshJSON]: heterogeneous JSON object
            let meta = try XCTUnwrap(todo.metadata)
            // String value
            XCTAssertEqual(meta["label"], .string("urgent"))
            // Numeric value (JSON number decodes as .number)
            if case .number(let n) = meta["count"] {
                XCTAssertEqual(Int(n), 3)
            } else {
                XCTFail("metadata[\\\"count\\\"] should be .number(3)")
            }
        }
    }
    """

    File.write!(Path.join(tests_dir, "E2EExtendedTypesTest.swift"), e2e_swift)

    {output, status} =
      System.cmd("swift", ["test", "--filter", "E2EExtendedTypesTest"],
        cd: tmp,
        stderr_to_stdout: true
      )

    assert status == 0, "swift test failed:\n#{output}"
  end

  test "sorted read action: the Swift-assembled sort string is what the pipeline accepts" do
    repo_root = File.cwd!()
    tmp = make_consumer_package(repo_root)
    sources = Path.join([tmp, "Sources", "GeneratedClient"])
    tests_dir = Path.join([tmp, "Tests", "E2ETests"])
    File.mkdir_p!(tests_dir)

    assert {:ok, _written} = Codegen.generate(@domains, sources)

    # Seed three todos with distinct, prefixed titles and a nullable score, so the
    # ordering assertions can isolate this test's records from any others ETS holds.
    for {title, score} <- [{"SortE2E-Alpha", 2}, {"SortE2E-Bravo", nil}, {"SortE2E-Charlie", 1}] do
      Ash.create!(AshSwift.Test.Todo, %{title: title, score: score}, domain: AshSwift.Test.Domain)
    end

    conn = %Plug.Conn{private: %{}, assigns: %{}}

    # The sort strings below are exactly what `ashSortString` produces in Swift for
    # the typed sorts asserted in the XCTest — `-title` and `++score`. Sending the
    # literal string here and asserting equality with the helper in Swift proves
    # both sides agree on the wire format the server parses.
    desc_params = %{
      "action" => "list_todos",
      "fields" => ["title", "score"],
      "sort" => "-title"
    }

    desc_result = AshTypescript.Rpc.run_action(:ash_swift, conn, desc_params)
    assert desc_result["success"] == true
    desc_json = Jason.encode!(desc_result)

    nils_first_params = %{
      "action" => "list_todos",
      "fields" => ["title", "score"],
      "sort" => "++score"
    }

    nils_first_result = AshTypescript.Rpc.run_action(:ash_swift, conn, nils_first_params)
    assert nils_first_result["success"] == true
    nils_first_json = Jason.encode!(nils_first_result)

    e2e_swift = """
    import XCTest
    import Foundation
    import AshSwiftRuntime
    import GeneratedClient

    // Proves the sort surface round-trips: the Swift-side `ashSortString` produces
    // the exact string the Elixir pipeline was given, and the records come back in
    // the order that string requests, decoded through the generated Todo model.
    final class E2ESortTest: XCTestCase {
        // Keep only this test's seeded records, in the order the server returned them.
        private func ours(_ todos: [Todo]) -> [String] {
            todos.compactMap { $0.title }.filter { $0.hasPrefix("SortE2E-") }
        }

        func testDescendingTitleSortRoundTrips() throws {
            // The generated client would assemble this exact string for the typed sort.
            XCTAssertEqual(
                ashSortString([SortField(TodoSortField.title, .descending)]),
                "-title"
            )

            let json = #{inspect(desc_json, binaries: :as_strings)}
            struct ListEnvelope: Decodable { let success: Bool; let data: [Todo] }
            let envelope = try JSONDecoder().decode(ListEnvelope.self, from: Data(json.utf8))
            XCTAssertTrue(envelope.success)

            // Descending title: Charlie, Bravo, Alpha.
            XCTAssertEqual(
                ours(envelope.data),
                ["SortE2E-Charlie", "SortE2E-Bravo", "SortE2E-Alpha"]
            )
        }

        func testNilsFirstScoreSortRoundTrips() throws {
            XCTAssertEqual(
                ashSortString([SortField(TodoSortField.score, .ascendingNilsFirst)]),
                "++score"
            )

            let json = #{inspect(nils_first_json, binaries: :as_strings)}
            struct ListEnvelope: Decodable { let success: Bool; let data: [Todo] }
            let envelope = try JSONDecoder().decode(ListEnvelope.self, from: Data(json.utf8))
            XCTAssertTrue(envelope.success)

            // Ascending score with nils first: Bravo (nil), Charlie (1), Alpha (2).
            XCTAssertEqual(
                ours(envelope.data),
                ["SortE2E-Bravo", "SortE2E-Charlie", "SortE2E-Alpha"]
            )
        }
    }
    """

    File.write!(Path.join(tests_dir, "E2ESortTest.swift"), e2e_swift)

    {output, status} =
      System.cmd("swift", ["test", "--filter", "E2ESortTest"], cd: tmp, stderr_to_stdout: true)

    assert status == 0, "swift test failed:\n#{output}"
  end

  # Builds a throwaway SPM package with both a library target (for the generated
  # client) and a test target (for the E2E XCTest), mirroring how a real consuming
  # app would depend on AshSwiftRuntime (ADR-0005).
  defp make_consumer_package(repo_root) do
    tmp =
      Path.join(System.tmp_dir!(), "ash_swift_e2e_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(tmp) end)
    File.mkdir_p!(Path.join([tmp, "Sources", "GeneratedClient"]))
    File.mkdir_p!(Path.join([tmp, "Tests", "E2ETests"]))

    pkg_name = String.downcase(Path.basename(repo_root))

    manifest = """
    // swift-tools-version:5.9
    import PackageDescription

    let package = Package(
        name: "GeneratedClientE2E",
        platforms: [.iOS(.v16), .macOS(.v13)],
        dependencies: [
            .package(path: #{inspect(repo_root)})
        ],
        targets: [
            .target(
                name: "GeneratedClient",
                dependencies: [.product(name: "AshSwiftRuntime", package: #{inspect(pkg_name)})]
            ),
            .testTarget(
                name: "E2ETests",
                dependencies: [
                    "GeneratedClient",
                    .product(name: "AshSwiftRuntime", package: #{inspect(pkg_name)})
                ]
            )
        ]
    )
    """

    File.write!(Path.join(tmp, "Package.swift"), manifest)
    tmp
  end
end
