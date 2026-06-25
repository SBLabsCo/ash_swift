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
      # priority is now a typed enum, not String
      assert types =~ "public var priority: TodoPriority?"
      assert types =~ "public var title: String?"
      assert types =~ "public var userId: String?"
      # User scalar fields
      assert types =~ "public var email: String?"
      assert types =~ "public var name: String?"
    end

    test "emits a Swift enum for an atom attribute with one_of constraint", %{files: files} do
      types = files["AshRpcTypes.swift"]
      assert types =~ "public enum TodoPriority: String, Codable, Sendable, Equatable {"
      assert types =~ "    case high"
      assert types =~ "    case low"
      assert types =~ "    case medium"
      # The enum definition must appear before the struct that uses it
      enum_pos = :binary.match(types, "public enum TodoPriority:") |> elem(0)
      struct_pos = :binary.match(types, "public struct Todo:") |> elem(0)
      assert enum_pos < struct_pos
    end

    test "emits a Swift enum for an Ash.Type.Enum subtype attribute", %{files: files} do
      types = files["AshRpcTypes.swift"]
      assert types =~ "public enum TodoStatus: String, Codable, Sendable, Equatable {"
      assert types =~ "    case active"
      assert types =~ "    case archived"
      assert types =~ "    case pending"
      # Field on Todo uses the typed enum, not String
      assert types =~ "public var status: TodoStatus?"
      # Enum definition appears before the struct that references it
      enum_pos = :binary.match(types, "public enum TodoStatus:") |> elem(0)
      struct_pos = :binary.match(types, "public struct Todo:") |> elem(0)
      assert enum_pos < struct_pos
    end

    test "backtick-escapes :case — a statement keyword — in an Ash.Type.Enum", %{files: files} do
      types = files["AshRpcTypes.swift"]
      # :case is a Swift statement keyword; bare `case case` is a syntax error.
      assert types =~ "    case `case`"
      refute types =~ "    case case\n"
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

    test "non-list, non-get actions keep the simple M1 void signature", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      for func <- ~w(createTodo updateTodo destroyTodo createUser) do
        assert functions =~ "public func #{func}() async throws {"
      end
    end

    test "get action with not_found_error? true emits a typed non-optional return", %{
      files: files
    } do
      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func getTodo(id: String, fields: [FieldSelection] = []) async throws -> Todo {"
    end

    test "get action with not_found_error? false emits a typed optional return", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func findTodo(id: String, fields: [FieldSelection] = []) async throws -> Todo? {"
    end

    test "non-String get_by field (integer) is always emitted as String parameter type", %{
      files: files
    } do
      functions = files["AshRpcFunctions.swift"]

      # score is Ash.Type.Integer; ash_type_to_swift would emit "Int", but
      # lookup params travel in [String: String] dicts so must always be String.
      assert functions =~
               "public func getTodoByScore(score: String, fields: [FieldSelection] = []) async throws -> Todo {"
    end

    test "rpc_action get_by emits getBy: argument in the generated call", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func findTodoByTitle(title: String, fields: [FieldSelection] = []) async throws -> Todo {"

      assert functions =~ ~s(getBy: ["title": title])
    end

    test "is deterministic — same domains produce byte-identical output", %{files: files} do
      assert Codegen.build_files(@domains) == files
    end

    test "backtick-escapes Swift reserved keywords used as enum case names", %{files: files} do
      types = files["AshRpcTypes.swift"]
      # :default is a Swift reserved keyword — backtick-escaped. Swift infers the
      # raw String value from the identifier name so no explicit = "default" needed.
      assert types =~ "    case `default`"
      refute types =~ "    case default\n"
      # :pending is not a keyword — emitted without backticks
      assert types =~ "    case pending"
      refute types =~ "    case `pending`"
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
