defmodule AshSwift.CodegenTest do
  @moduledoc """
  Tests the primary M1 seam: the Swift source codegen emits — never its internal
  helpers. These assert on observable, structural properties of the output.
  """
  use ExUnit.Case, async: true

  alias AshSwift.Codegen

  @domains [AshSwift.Test.Domain]

  describe "build_files/1" do
    setup do
      %{files: Codegen.build_files(@domains)}
    end

    test "splits output into a navigable types file and an RPC-functions file", %{files: files} do
      assert Map.keys(files) |> Enum.sort() == ["AshRpcFunctions.swift", "AshRpcTypes.swift"]
    end

    test "emits one Codable struct per resource, named by its type_name", %{files: files} do
      types = files["AshRpcTypes.swift"]
      assert types =~ "public struct Todo: Codable, Sendable, Equatable {"
      assert types =~ "public struct User: Codable, Sendable, Equatable {"
    end

    test "the functions file imports the runtime and exposes an AshRpc entry point", %{files: files} do
      functions = files["AshRpcFunctions.swift"]
      assert functions =~ "import AshSwiftRuntime"
      assert functions =~ "public struct AshRpc: Sendable {"
      assert functions =~ "public let client: AshRpcClient"
    end

    test "generates a camelCased async function per RPC action", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      for func <- ~w(listTodos getTodo createTodo updateTodo destroyTodo listUsers createUser) do
        assert functions =~ "public func #{func}() async throws {"
      end
    end

    test "is deterministic — same domains produce byte-identical output", %{files: files} do
      assert Codegen.build_files(@domains) == files
    end
  end
end
