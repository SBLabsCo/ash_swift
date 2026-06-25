defmodule AshSwift.E2ETest do
  @moduledoc """
  End-to-end wire compatibility: runs the list_todos action in-process through
  the reused AshTypescript RPC pipeline, then verifies the generated Swift model
  can decode the real JSON response.

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

    # Create a todo in-process using the ETS-backed data layer.
    Ash.create!(AshSwift.Test.Todo, %{title: "E2E Todo", completed: true},
      domain: AshSwift.Test.Domain
    )

    # Run the list action through the real AshTypescript RPC pipeline.
    # A minimal Plug.Conn suffices — no auth needed for these fixture actions.
    conn = %Plug.Conn{private: %{}, assigns: %{}}
    params = %{"action" => "list_todos", "fields" => ["id", "title", "completed"]}
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
            // userId not requested — decodes as nil, not a decode failure.
            XCTAssertNil(first.userId)
        }
    }
    """

    File.write!(Path.join(tests_dir, "E2EDecodeTest.swift"), e2e_swift)

    {output, status} = System.cmd("swift", ["test", "--filter", "E2EDecodeTest"], cd: tmp, stderr_to_stdout: true)
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
