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
