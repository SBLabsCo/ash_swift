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

    test "emits all-Optional camelCased fields for each resource", %{files: files} do
      types = files["AshRpcTypes.swift"]
      # Todo scalar fields
      assert types =~ "public var completed: Bool?"
      assert types =~ "public var id: String?"
      assert types =~ "public var priority: String?"
      assert types =~ "public var title: String?"
      assert types =~ "public var userId: String?"
      # User scalar fields
      assert types =~ "public var email: String?"
      assert types =~ "public var name: String?"
    end

    test "emits relationship fields as Optional nested types", %{files: files} do
      types = files["AshRpcTypes.swift"]
      # belongs_to :user on Todo emits a User? field
      assert types =~ "public var user: User?"
      # has_many :todos on User emits a [Todo]? field
      assert types =~ "public var todos: [Todo]?"
    end

    test "the functions file imports the runtime and exposes an AshRpc entry point", %{
      files: files
    } do
      functions = files["AshRpcFunctions.swift"]
      assert functions =~ "import AshSwiftRuntime"
      assert functions =~ "public struct AshRpc: Sendable {"
      assert functions =~ "public let client: AshRpcClient"
    end

    test "list (non-get read) actions accept a field list and return a typed array", %{
      files: files
    } do
      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func listTodos(fields: [FieldSelection] = []) async throws -> [Todo] {"

      assert functions =~
               "public func listUsers(fields: [FieldSelection] = []) async throws -> [User] {"
    end

    test "non-list actions keep the simple M1 void signature", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      for func <- ~w(getTodo createTodo updateTodo destroyTodo createUser) do
        assert functions =~ "public func #{func}() async throws {"
      end
    end

    test "is deterministic — same domains produce byte-identical output", %{files: files} do
      assert Codegen.build_files(@domains) == files
    end
  end

  describe "2-hop relationship guard" do
    setup do
      %{files: Codegen.build_files([AshSwift.Test.TagDomain])}
    end

    test "emits the 1-hop related resource struct", %{files: files} do
      assert files["AshRpcTypes.swift"] =~
               "public struct Category: Codable, Sendable, Equatable {"
    end

    test "does not emit a 2-hop resource struct", %{files: files} do
      refute files["AshRpcTypes.swift"] =~
               "public struct Publisher: Codable, Sendable, Equatable {"
    end

    test "drops relationship fields referencing 2-hop types from related structs", %{files: files} do
      refute files["AshRpcTypes.swift"] =~ "public var publisher: Publisher?"
    end

    test "preserves scalar fields on related resource structs", %{files: files} do
      types = files["AshRpcTypes.swift"]
      assert types =~ "public var name: String?"
      assert types =~ "public var publisherId: String?"
    end

    test "the 1-hop relationship field is still emitted on the primary resource struct", %{
      files: files
    } do
      assert files["AshRpcTypes.swift"] =~ "public var category: Category?"
    end
  end

  describe "stale_files/2 (the --check staleness guard)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "ash_swift_stale_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "reports every file as stale when nothing has been generated yet", %{dir: dir} do
      assert Codegen.stale_files(@domains, dir) ==
               ["AshRpcFunctions.swift", "AshRpcTypes.swift"]
    end

    test "reports nothing stale right after generating", %{dir: dir} do
      assert {:ok, _} = Codegen.generate(@domains, dir)
      assert Codegen.stale_files(@domains, dir) == []
    end

    test "reports a file stale once its committed copy drifts", %{dir: dir} do
      assert {:ok, _} = Codegen.generate(@domains, dir)
      File.write!(Path.join(dir, "AshRpcTypes.swift"), "// hand-edited\n")

      assert Codegen.stale_files(@domains, dir) == ["AshRpcTypes.swift"]
    end
  end
end
