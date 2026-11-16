defmodule AshSwift.Codegen.EmitterTest do
  @moduledoc """
  Drives `AshSwift.Codegen.Emitter.render_types/1` and `render_functions/1`
  directly over a small hand-built IR (ADR-0010), so an Emitter formatting
  regression fails here rather than as a substring miss in a full-domain
  `build_files/1` test. The IR is one resource with an enum, a model struct, a
  create input struct (a required field, an optional field, and a
  keyword-named field), a filter struct and a sort-field enum, plus a second
  resource that has neither a filter predicate nor a sort surface.

  Hand-built IR must follow the shape in the Reader's moduledoc (see
  `generic_action/1` for generic actions); the "carries exactly the Reader's key
  sets" test enforces it for actions.

  What the Reader decides (which actions are sortable, how a manifest type maps)
  is *input* here; these tests pin only how the Emitter renders it.
  """
  use ExUnit.Case, async: true

  alias AshSwift.Codegen.Emitter
  alias AshSwift.Test.ActionIRKeys

  # Overrides use `Map.replace!/3`, so a typo'd key or one the Reader never emits
  # for this action kind raises instead of silently rendering an impossible shape.
  defp override!(base, overrides) do
    Enum.reduce(overrides, base, fn {k, v}, acc -> Map.replace!(acc, k, v) end)
  end

  defp action(overrides) do
    override!(
      %{
        rpc_name: :list_todos,
        action: :read,
        action_type: :read,
        get: nil,
        not_found_error?: false,
        input_struct_name: nil,
        input_required?: false,
        primary_key_params: [],
        pagination_type: :none,
        optional_pagination_type: :none,
        sortable?: false,
        filterable?: false
      },
      overrides
    )
  end

  # Shaped exactly like the Reader's generic-action IR: no `input_required?`
  # (CRUD only), plus `generic_return` and `generic_return_resource`.
  defp generic_action(overrides) do
    %{
      rpc_name: :ping,
      action: :ping,
      action_type: :action,
      get: nil,
      not_found_error?: false,
      input_struct_name: nil,
      primary_key_params: [],
      pagination_type: :none,
      optional_pagination_type: :none,
      sortable?: false,
      filterable?: false,
      generic_return: :void,
      generic_return_resource: nil
    }
    |> override!(overrides)
  end

  defp todo(actions) do
    %{
      resource_module: nil,
      domain: nil,
      type_name: "Todo",
      fields: [
        %{name: "default", swift_type: "String"},
        %{name: "priority", swift_type: "TodoPriority"},
        %{name: "title", swift_type: "String"}
      ],
      enums: [
        %{
          enum_name: "TodoPriority",
          cases: [
            %{name: "low", raw: nil},
            %{name: "high", raw: nil},
            %{name: "default", raw: nil},
            %{name: "inProgress", raw: "in_progress"}
          ]
        }
      ],
      actions: actions,
      input_structs: [
        %{
          struct_name: "CreateTodoInput",
          decodable?: false,
          fields: [
            %{name: "notes", swift_type: "String", required?: false},
            %{name: "title", swift_type: "String", required?: true},
            %{name: "default", swift_type: "String", required?: false}
          ]
        }
      ],
      sort_field: %{type_name: "TodoSortField", fields: ["default", "title"]},
      filter_struct: %{
        type_name: "TodoFilter",
        fields: [
          %{name: "default", swift_type: "NullableEnumOperators<String>"},
          %{name: "title", swift_type: "EnumOperators<String>"}
        ]
      }
    }
  end

  # A MapOnly-style resource: no sort field, a predicate-less filter struct. Actions
  # are left out because `render_types/1` does not read them.
  defp bare do
    %{
      resource_module: nil,
      domain: nil,
      type_name: "Bare",
      fields: [],
      enums: [],
      actions: [],
      input_structs: [],
      sort_field: nil,
      filter_struct: %{type_name: "BareFilter", fields: []}
    }
  end

  test "hand-built action IR carries exactly the Reader's key sets (#154)" do
    assert MapSet.new(Map.keys(action([]))) == ActionIRKeys.crud()
    assert MapSet.new(Map.keys(generic_action([]))) == ActionIRKeys.generic()
  end

  describe "render_types/1" do
    setup do
      # Actions are omitted: `render_types/1` does not read them.
      %{types: Emitter.render_types([bare(), todo([])])}
    end

    test "renders an all-Optional Codable model struct, keyword fields escaped", %{types: types} do
      assert types =~ """
             public struct Todo: Codable, Sendable, Equatable {
                 public var `default`: String?
                 public var priority: TodoPriority?
                 public var title: String?
                 public init() {}
             }\
             """
    end

    test "a resource with no fields renders just the no-arg init", %{types: types} do
      assert types =~ """
             public struct Bare: Codable, Sendable, Equatable {
                 public init() {}
             }\
             """
    end

    test "renders enums sorted by wire value, escaping keywords and emitting explicit raw values",
         %{
           types: types
         } do
      assert types =~ """
             public enum TodoPriority: String, Codable, Sendable, Equatable {
                 case `default`
                 case high
                 case inProgress = "in_progress"
                 case low
             }\
             """

      refute types =~ "    case default\n"
    end

    test "an enum is emitted before the model struct that uses it", %{types: types} do
      {enum_pos, _} = :binary.match(types, "public enum TodoPriority:")
      {struct_pos, _} = :binary.match(types, "public struct Todo:")
      assert enum_pos < struct_pos
    end

    # One exact block, so each property, init line, CodingKeys case and encode call
    # is pinned in the CreateTodoInput body (not a substring that the Todo model
    # struct could also satisfy). The IR lists the required `title` second: the
    # stored properties, CodingKeys and encode keep IR order, and only the init
    # moves required fields first. `default` is a Swift keyword, escaped throughout.
    test "input struct: only the init puts required fields first; keyword names are escaped", %{
      types: types
    } do
      assert types =~ """
             public struct CreateTodoInput: Encodable, Sendable {
                 public var notes: String?
                 public var title: String
                 public var `default`: String?

                 public init(title: String, notes: String? = nil, `default`: String? = nil) {
                     self.notes = notes
                     self.title = title
                     self.`default` = `default`
                 }

                 public func encode(to encoder: Encoder) throws {
                     var container = encoder.container(keyedBy: CodingKeys.self)
                     try container.encodeIfPresent(notes, forKey: .notes)
                     try container.encode(title, forKey: .title)
                     try container.encodeIfPresent(`default`, forKey: .`default`)
                 }

                 private enum CodingKeys: String, CodingKey {
                     case notes
                     case title
                     case `default`
                 }
             }\
             """
    end

    test "an input struct with no fields renders only the no-arg init" do
      resource =
        Map.put(bare(), :input_structs, [
          %{struct_name: "NoArgsInput", decodable?: false, fields: []}
        ])

      assert Emitter.render_types([resource]) =~ """
             public struct NoArgsInput: Encodable, Sendable {
                 public init() {}
             }\
             """
    end

    test "a decodable input struct renders a Decodable result struct" do
      resource =
        Map.put(bare(), :input_structs, [
          %{
            struct_name: "UploadResult",
            decodable?: true,
            fields: [
              %{name: "url", swift_type: "String", required?: true},
              %{name: "default", swift_type: "String", required?: false}
            ]
          }
        ])

      assert Emitter.render_types([resource]) =~ """
             public struct UploadResult: Decodable, Sendable, Equatable {
                 public var url: String
                 public var `default`: String?
             }\
             """
    end

    test "filter struct: predicates, then and/or/not of the same type, then init", %{
      types: types
    } do
      assert types =~ """
             public struct TodoFilter: Encodable, Sendable {
                 public var `default`: NullableEnumOperators<String>?
                 public var title: EnumOperators<String>?

                 public var and: [TodoFilter]?
                 public var or: [TodoFilter]?
                 public var not: [TodoFilter]?

                 public init() {}
             }\
             """
    end

    test "a filter struct with no predicates still carries the combinators", %{types: types} do
      assert types =~ """
             public struct BareFilter: Encodable, Sendable {
                 public var and: [BareFilter]?
                 public var or: [BareFilter]?
                 public var not: [BareFilter]?

                 public init() {}
             }\
             """
    end

    test "sort-field enum: keyword cases are escaped", %{types: types} do
      assert types =~ """
             public enum TodoSortField: String, Sendable {
                 case `default`
                 case title
             }\
             """
    end

    test "a nil sort_field emits no SortField enum", %{types: types} do
      refute types =~ "BareSortField"
    end

    test "no resources renders just the header and imports" do
      assert Emitter.render_types([]) ==
               """
               // Generated by AshSwift. Do not edit by hand.
               // Regenerate with `mix ash_swift.codegen`.

               import Foundation
               import AshSwiftRuntime

               """
    end
  end

  describe "render_functions/1" do
    defp functions(actions), do: Emitter.render_functions([todo(actions)])

    test "wraps methods in the AshRpc entry point" do
      out = functions([])

      assert out =~ "import AshSwiftRuntime"
      assert out =~ "public struct AshRpc: Sendable {"
      assert out =~ "public let client: AshRpcClient"
      assert out =~ "public init(client: AshRpcClient) {"
    end

    test "a plain list read takes filter, sort and fields and returns [T]" do
      out = functions([action(sortable?: true, filterable?: true)])

      assert out =~
               "public func listTodos(filter: TodoFilter? = nil, sort: [SortField<TodoSortField>] = [], fields: [FieldSelection]) async throws -> [Todo] {"

      assert out =~
               ~s[client.execute(ListRequest(action: "list_todos", filter: filter.map { AnyEncodable($0) }, sort: ashSortString(sort), fields: fields))]
    end

    test "a list read with sort and filter disabled has only fields" do
      out = functions([action([])])

      assert out =~ "public func listTodos(fields: [FieldSelection]) async throws -> [Todo] {"
      assert out =~ ~s[ListRequest(action: "list_todos", fields: fields)]
      refute out =~ "sort:"
      refute out =~ "filter:"
    end

    test "sort and filter can be disabled independently" do
      no_sort = functions([action(filterable?: true)])
      no_filter = functions([action(sortable?: true)])

      assert no_sort =~
               "public func listTodos(filter: TodoFilter? = nil, fields: [FieldSelection])"

      refute no_sort =~ "sort:"

      assert no_filter =~
               "public func listTodos(sort: [SortField<TodoSortField>] = [], fields: [FieldSelection])"

      refute no_filter =~ "filter:"
    end

    test "an offset-paginated read threads page before filter and sort" do
      out =
        functions([
          action(
            rpc_name: :list_todos_offset,
            pagination_type: :offset,
            sortable?: true,
            filterable?: true
          )
        ])

      assert out =~
               "public func listTodosOffset(page: OffsetPageParams? = nil, filter: TodoFilter? = nil, sort: [SortField<TodoSortField>] = [], fields: [FieldSelection]) async throws -> OffsetPage<Todo> {"

      assert out =~
               ~s[client.execute(OffsetPageRequest(action: "list_todos_offset", page: page, filter: filter.map { AnyEncodable($0) }, sort: ashSortString(sort), fields: fields))]
    end

    test "a keyset-paginated read threads page before filter and sort" do
      out =
        functions([
          action(
            rpc_name: :list_todos_keyset,
            pagination_type: :keyset,
            sortable?: true,
            filterable?: true
          )
        ])

      assert out =~
               "public func listTodosKeyset(page: KeysetPageParams? = nil, filter: TodoFilter? = nil, sort: [SortField<TodoSortField>] = [], fields: [FieldSelection]) async throws -> KeysetPage<Todo> {"

      assert out =~
               ~s[client.execute(KeysetPageRequest(action: "list_todos_keyset", page: page, filter: filter.map { AnyEncodable($0) }, sort: ashSortString(sort), fields: fields))]
    end

    test "create takes a typed input and returns the record" do
      out =
        functions([
          action(
            rpc_name: :create_todo,
            action_type: :create,
            input_struct_name: "CreateTodoInput"
          )
        ])

      assert out =~
               "public func createTodo(input: CreateTodoInput, fields: [FieldSelection]) async throws -> Todo {"

      assert out =~
               ~s[client.execute(CreateRequest(action: "create_todo", input: input, fields: fields))]
    end

    test "update takes the primary key, sent as identity, plus a typed input" do
      out =
        functions([
          action(
            rpc_name: :update_todo,
            action_type: :update,
            input_struct_name: "UpdateTodoInput",
            primary_key_params: [%{name: "id", swift_type: "String"}]
          )
        ])

      assert out =~
               "public func updateTodo(id: String, input: UpdateTodoInput, fields: [FieldSelection]) async throws -> Todo {"

      assert out =~
               ~s[UpdateRequest(action: "update_todo", identity: id, input: input, fields: fields)]
    end

    test "destroy takes the primary key and has a void return" do
      out =
        functions([
          action(
            rpc_name: :destroy_todo,
            action_type: :destroy,
            primary_key_params: [%{name: "id", swift_type: "String"}]
          )
        ])

      assert out =~ "public func destroyTodo(id: String) async throws {"

      assert out =~
               ~s[try await client.execute(DestroyRequest(action: "destroy_todo", identity: id))]

      refute out =~ "return try await client.execute(DestroyRequest"
    end

    test "destroy without a primary key raises" do
      assert_raise RuntimeError, ~r/destroy codegen requires a primary key/, fn ->
        functions([action(rpc_name: :destroy_todo, action_type: :destroy)])
      end
    end

    test "a get returns T or T? by not_found_error?, and sends lookups as input or getBy" do
      get = fn overrides ->
        functions([
          action(
            [
              rpc_name: :get_todo,
              get: {:input, [%{name: "id", swift_type: "String"}]},
              not_found_error?: true
            ] ++ overrides
          )
        ])
      end

      assert get.([]) =~
               "public func getTodo(id: String, fields: [FieldSelection]) async throws -> Todo {"

      assert get.([]) =~ ~s|GetRequest(action: "get_todo", input: ["id": id], fields: fields)|

      assert get.(not_found_error?: false) =~
               "public func getTodo(id: String, fields: [FieldSelection]) async throws -> Todo? {"

      assert get.(not_found_error?: false) =~ ~s[GetOptionalRequest(action: "get_todo"]

      assert get.(get: {:get_by, [%{name: "title", swift_type: "String"}]}) =~
               ~s|getBy: ["title": title]|
    end

    test "a get whose IR claims sortable?, filterable? or a pagination type raises instead of being re-decided" do
      for {flag, value} <- [
            sortable?: true,
            filterable?: true,
            pagination_type: :offset,
            optional_pagination_type: :keyset
          ] do
        assert_raise RuntimeError, ~r/the Reader must set sortable\?\/filterable\? false/, fn ->
          functions([action([{:rpc_name, :get_todo}, {:get, :pure}, {flag, value}])])
        end
      end
    end

    test "a pure get takes no lookup param" do
      out = functions([action(rpc_name: :fetch_todo, get: :pure, not_found_error?: true)])

      assert out =~ "public func fetchTodo(fields: [FieldSelection]) async throws -> Todo {"
      assert out =~ ~s[GetRequest(action: "fetch_todo", fields: fields)]
    end

    test "a read with an optional input struct takes `input: T? = nil`; a required one is bare" do
      optional = functions([action(rpc_name: :list_todos, input_struct_name: "ListTodosInput")])

      required =
        functions([
          action(
            rpc_name: :list_todos,
            input_struct_name: "ListTodosInput",
            input_required?: true
          )
        ])

      assert optional =~ "listTodos(input: ListTodosInput? = nil, fields: [FieldSelection])"
      assert optional =~ "input: input.map { AnyEncodable($0) }"
      assert required =~ "listTodos(input: ListTodosInput, fields: [FieldSelection])"
      assert required =~ "input: AnyEncodable(input)"
    end

    test "optional pagination emits the bare overload plus a paginated one with required page" do
      out = functions([action(rpc_name: :list_todos_opt, optional_pagination_type: :offset)])

      assert out =~ "public func listTodosOpt(fields: [FieldSelection]) async throws -> [Todo] {"

      assert out =~
               "public func listTodosOpt(page: OffsetPageParams, fields: [FieldSelection]) async throws -> OffsetPage<Todo> {"
    end

    test "optional keyset pagination gains a keyset overload with a KeysetPageRequest" do
      out =
        functions([
          action(
            rpc_name: :list_todos_keyset_optional,
            optional_pagination_type: :keyset,
            sortable?: true,
            filterable?: true
          )
        ])

      assert out =~
               "public func listTodosKeysetOptional(page: KeysetPageParams, filter: TodoFilter? = nil, sort: [SortField<TodoSortField>] = [], fields: [FieldSelection]) async throws -> KeysetPage<Todo> {"

      assert out =~
               ~s[client.execute(KeysetPageRequest(action: "list_todos_keyset_optional", page: page, filter: filter.map { AnyEncodable($0) }, sort: ashSortString(sort), fields: fields))]
    end

    test "sort and filter appear on both the bare and the paginated overload when enabled" do
      out =
        functions([
          action(optional_pagination_type: :offset, sortable?: true, filterable?: true)
        ])

      assert out =~
               "public func listTodos(filter: TodoFilter? = nil, sort: [SortField<TodoSortField>] = [], fields: [FieldSelection]) async throws -> [Todo] {"

      assert out =~
               "public func listTodos(page: OffsetPageParams, filter: TodoFilter? = nil, sort: [SortField<TodoSortField>] = [], fields: [FieldSelection]) async throws -> OffsetPage<Todo> {"

      assert out =~
               ~s[client.execute(OffsetPageRequest(action: "list_todos", page: page, filter: filter.map { AnyEncodable($0) }, sort: ashSortString(sort), fields: fields))]
    end

    test "required pagination emits a single function, with no bare overload" do
      out = functions([action(rpc_name: :list_todos_offset, pagination_type: :offset)])

      assert length(String.split(out, "public func listTodosOffset(")) == 2
      refute out =~ "-> [Todo]"
    end

    test "generic actions: void and typed returns, with and without input" do
      out =
        functions([
          generic_action(rpc_name: :ping, generic_return: :void),
          generic_action(rpc_name: :count, generic_return: {:typed, "Int"}),
          generic_action(
            rpc_name: :rename,
            input_struct_name: "RenameInput",
            generic_return: {:typed_record, "Todo"}
          )
        ])

      assert out =~ "public func ping() async throws {"
      assert out =~ ~s[VoidActionRequest<EmptyActionInput>(action: "ping")]
      assert out =~ "public func count() async throws -> Int {"
      assert out =~ ~s[GenericActionRequest<Int, EmptyActionInput>(action: "count")]

      assert out =~
               "public func rename(input: RenameInput, fields: [FieldSelection]) async throws -> Todo {"

      assert out =~ ~s[GenericActionRequest(action: "rename", input: input, fields: fields)]
    end

    test "Swift keyword function names are backtick-escaped" do
      out = functions([action(rpc_name: :init)])

      assert out =~ "public func `init`("
      refute out =~ "public func init("
    end

    test "snake_case rpc names become lowerCamelCase function names" do
      out = functions([action(rpc_name: :list_open_todos)])
      assert out =~ "public func listOpenTodos("
      assert out =~ ~s[action: "list_open_todos"]
    end

    test "methods are emitted in the order given, separated by a blank line" do
      out = functions([action(rpc_name: :b_first), action(rpc_name: :a_second)])
      {b, _} = :binary.match(out, "func bFirst")
      {a, _} = :binary.match(out, "func aSecond")
      assert b < a
      assert out =~ ~r/\}\n\n    \/\/\/ Calls the `a_second`/
    end
  end
end
