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

    test "emits public aggregates as Optional fields typed from their resolved type",
         %{files: files} do
      types = files["AshRpcTypes.swift"]
      # User's aggregates over :todos (issue #51). Each is selectable like any
      # other field and decodes through the same Optional struct member.
      # count → Int, exists → Bool.
      assert types =~ "public var todoCount: Int?"
      assert types =~ "public var hasTodos: Bool?"
      # The complete set of field-typed numeric aggregates, all sharing the scalar
      # gate → ash_type_to_swift path. max/min/sum preserve the field's type (:integer
      # → Int); avg promotes to :float → Double, so the assertion pins that :float
      # stays mapped (and in @derived_scalar_kinds) rather than being skipped.
      assert types =~ "public var highestScore: Int?"
      assert types =~ "public var lowestScore: Int?"
      assert types =~ "public var totalScore: Int?"
      assert types =~ "public var averageScore: Double?"
    end

    test "emits a Swift enum for an aggregate whose resolved type is an enum",
         %{files: files} do
      types = files["AshRpcTypes.swift"]
      # `top_priority` is a `first` aggregate over the enum attribute :priority, so
      # it resolves to an enum type and is emitted like an enum attribute: a typed
      # field plus a per-resource generated enum.
      assert types =~ "public var topPriority: UserTopPriority?"
      assert types =~ "public enum UserTopPriority: String, Codable, Sendable, Equatable {"

      # Scope the case assertions to the UserTopPriority block. Asserting `case high`
      # against the whole file would be vacuous — TodoPriority carries the same cases
      # in the same string — so extract this enum's body and check the cases there,
      # making the assertion load-bearing if UserTopPriority's cases ever regress.
      enum_block = Regex.run(~r/public enum UserTopPriority:.*?\n\}/s, types) |> List.first()
      assert enum_block =~ "case high"
      assert enum_block =~ "case low"
      assert enum_block =~ "case medium"
    end

    test "skips an aggregate whose resolved type doesn't map to a Swift scalar/enum",
         %{files: files} do
      types = files["AshRpcTypes.swift"]
      # `todo_titles` is a `list` aggregate → an array result the manifest reports
      # with `module: nil`. A derived field with no faithful Swift type is omitted
      # rather than String-fallbacked (which would silently mis-decode).
      refute types =~ "todoTitles"
    end

    test "does not emit private aggregates", %{files: files} do
      types = files["AshRpcTypes.swift"]
      # `secret_count` is a non-public aggregate — codegen's public-only scope must
      # exclude it (the manifest is built without include_private_aggregates?).
      refute types =~ "secretCount"
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
               "public func listTodos(filter: TodoFilter? = nil, sort: [SortField<TodoSortField>] = [], fields: [FieldSelection] = []) async throws -> [Todo] {"

      assert functions =~
               "public func listUsers(filter: UserFilter? = nil, sort: [SortField<UserSortField>] = [], fields: [FieldSelection] = []) async throws -> [User] {"
    end

    test "offset-paginated read action returns OffsetPage<T> via OffsetPageRequest", %{
      files: files
    } do
      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func listTodosOffset(page: OffsetPageParams? = nil, filter: TodoFilter? = nil, sort: [SortField<TodoSortField>] = [], fields: [FieldSelection] = []) async throws -> OffsetPage<Todo> {"

      assert functions =~ ~s[client.execute(OffsetPageRequest(action: "list_todos_offset",]
    end

    test "keyset-paginated read action returns KeysetPage<T> via KeysetPageRequest", %{
      files: files
    } do
      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func listTodosKeyset(page: KeysetPageParams? = nil, filter: TodoFilter? = nil, sort: [SortField<TodoSortField>] = [], fields: [FieldSelection] = []) async throws -> KeysetPage<Todo> {"

      assert functions =~ ~s[client.execute(KeysetPageRequest(action: "list_todos_keyset",]
    end

    test "create action emits typed input + return", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func createTodo(input: CreateTodoInput, fields: [FieldSelection] = []) async throws -> Todo {"

      assert functions =~
               "public func createUser(input: CreateUserInput, fields: [FieldSelection] = []) async throws -> User {"
    end

    test "update action emits primary-key param + typed input + return", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func updateTodo(id: String, input: UpdateTodoInput, fields: [FieldSelection] = []) async throws -> Todo {"
    end

    test "destroy action emits primary-key param and void return", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func destroyTodo(id: String) async throws {"
    end

    test "emits input structs for create and update actions in the types file", %{files: files} do
      types = files["AshRpcTypes.swift"]

      assert types =~ "public struct CreateTodoInput: Encodable, Sendable {"
      assert types =~ "public struct UpdateTodoInput: Encodable, Sendable {"
      assert types =~ "public struct CreateUserInput: Encodable, Sendable {"
    end

    test "required create fields are non-optional; optional fields are Optional", %{files: files} do
      types = files["AshRpcTypes.swift"]

      # title is required (allow_nil?: false, no default) → non-optional
      assert types =~ "    public var title: String\n"
      # completed is optional (has default) → Optional
      assert types =~ "    public var completed: Bool?\n"
      # enum field is Optional in create input
      assert types =~ "    public var priority: TodoPriority?\n"
    end

    test "update input struct has all-Optional fields", %{files: files} do
      types = files["AshRpcTypes.swift"]

      assert types =~ "public struct UpdateTodoInput: Encodable, Sendable {"
      # The stored property must be Optional (not non-optional like in CreateTodoInput)
      assert Regex.match?(
               ~r/public struct UpdateTodoInput: Encodable, Sendable \{[^}]*\n    public var title: String\?\n/s,
               types
             )

      # The init parameter must also use = nil
      assert types =~ "title: String? = nil"
    end

    test "backtick-escapes Swift reserved keywords in input struct property and init", %{
      files: files
    } do
      types = files["AshRpcTypes.swift"]

      # :default is a Swift reserved keyword; the property, init param, and CodingKey
      # must all use the backtick-escaped form. The raw JSON key remains "default".
      assert types =~ "public var `default`: String?"
      assert types =~ "`default`: String? = nil"
      assert types =~ "case `default`"
      assert types =~ "encodeIfPresent(`default`, forKey: .`default`)"
      refute types =~ "public var default:"
    end

    test "required create fields appear as mandatory init params", %{files: files} do
      types = files["AshRpcTypes.swift"]

      # CreateTodoInput init must require `title: String` with no default
      assert types =~ "public init(title: String,"
      # CreateUserInput init must require both name and email
      assert types =~ "public init(email: String, name: String)"
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

    test "Ash.Type.Decimal maps to String (wire format is a JSON string)", %{files: files} do
      types = files["AshRpcTypes.swift"]
      # Decimal serialises as "123.45" on the wire; String is the faithful Swift type.
      assert types =~ "public var amount: String?"
    end

    test "Ash.Type.Date maps to String (ISO 8601 date-only wire format)", %{files: files} do
      types = files["AshRpcTypes.swift"]
      assert types =~ "public var deadline: String?"
    end

    test "Ash.Type.UtcDatetime maps to Date", %{files: files} do
      types = files["AshRpcTypes.swift"]
      assert types =~ "public var scheduledAt: Date?"
    end

    test "Ash.Type.UtcDatetimeUsec maps to Date", %{files: files} do
      types = files["AshRpcTypes.swift"]
      assert types =~ "public var dueAt: Date?"
    end

    test "Ash.Type.NaiveDatetime maps to String (no timezone in wire format)", %{files: files} do
      types = files["AshRpcTypes.swift"]
      assert types =~ "public var startedAt: String?"
    end

    test "Ash.Type.Map maps to [String: AshJSON]", %{files: files} do
      types = files["AshRpcTypes.swift"]
      assert types =~ "public var metadata: [String: AshJSON]?"
    end

    test "Ash.Type.CiString maps to String (plain JSON string wire format)", %{files: files} do
      types = files["AshRpcTypes.swift"]
      # CiString has an explicit mapping, so codegen emits String without the
      # unmapped-type fallback warning.
      assert types =~ "public var username: String?"
      # And it joins the equality+membership filter group like other strings.
      assert types =~ "public var username: NullableEnumOperators<String>?"
    end

    test "backtick-escapes Swift reserved keywords used as function names", %{files: files} do
      functions = files["AshRpcFunctions.swift"]
      # :init is a Swift declaration keyword; bare `public func init(...)` is a syntax error.
      assert functions =~ "public func `init`("
      refute functions =~ "public func init("
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

  describe "sort surface (issue #34)" do
    setup do
      %{files: Codegen.build_files(@domains)}
    end

    test "emits a typed sortable-field enum per resource covering public attributes", %{
      files: files
    } do
      types = files["AshRpcTypes.swift"]
      assert types =~ "public enum TodoSortField: String, Sendable {"
      # Public attributes appear as camelCased cases (raw value inferred from name).
      assert types =~ "    case completed"
      assert types =~ "    case dueAt"
      assert types =~ "    case scheduledAt"
      assert types =~ "    case title"
      # Users get their own sortable-field enum too.
      assert types =~ "public enum UserSortField: String, Sendable {"
    end

    test "excludes non-sortable composite types (Ash.Type.Map) from the sort field set", %{
      files: files
    } do
      types = files["AshRpcTypes.swift"]
      # `metadata` is an Ash.Type.Map (→ [String: AshJSON]); the backend can't sort
      # by a JSON object, so it must not appear as a typed sort field.
      assert Regex.match?(
               ~r/public enum TodoSortField: String, Sendable \{(?:(?!\}).)*\}/s,
               types
             )

      sort_enum =
        Regex.run(~r/public enum TodoSortField: String, Sendable \{.*?\n\}/s, types) |> hd()

      refute sort_enum =~ "case metadata"
      # Comparable scalars and enums are still included.
      assert sort_enum =~ "case amount"
      assert sort_enum =~ "case status"
    end

    test "backtick-escapes Swift reserved keywords in sortable-field cases", %{files: files} do
      types = files["AshRpcTypes.swift"]
      # :default is a Swift keyword; the case must be escaped (raw value stays "default").
      assert Regex.match?(
               ~r/public enum TodoSortField: String, Sendable \{[^}]*\n    case `default`\n/s,
               types
             )
    end

    test "list read action gains an optional typed sort: parameter", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func listTodos(filter: TodoFilter? = nil, sort: [SortField<TodoSortField>] = [], fields: [FieldSelection] = []) async throws -> [Todo] {"

      assert functions =~
               ~s[client.execute(ListRequest(action: "list_todos", filter: filter.map { AnyEncodable($0) }, sort: ashSortString(sort), fields: fields))]
    end

    test "offset-paginated read action threads sort alongside page", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func listTodosOffset(page: OffsetPageParams? = nil, filter: TodoFilter? = nil, sort: [SortField<TodoSortField>] = [], fields: [FieldSelection] = []) async throws -> OffsetPage<Todo> {"

      assert functions =~
               ~s[client.execute(OffsetPageRequest(action: "list_todos_offset", page: page, filter: filter.map { AnyEncodable($0) }, sort: ashSortString(sort), fields: fields))]
    end

    test "keyset-paginated read action threads sort alongside page", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func listTodosKeyset(page: KeysetPageParams? = nil, filter: TodoFilter? = nil, sort: [SortField<TodoSortField>] = [], fields: [FieldSelection] = []) async throws -> KeysetPage<Todo> {"

      assert functions =~
               ~s[client.execute(KeysetPageRequest(action: "list_todos_keyset", page: page, filter: filter.map { AnyEncodable($0) }, sort: ashSortString(sort), fields: fields))]
    end

    test "enable_sort?: false action is emitted WITHOUT a sort: parameter", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      # Filtering stays on for this action, so it keeps a filter: parameter but no sort:.
      assert functions =~
               "public func listTodosNoSort(filter: TodoFilter? = nil, fields: [FieldSelection] = []) async throws -> [Todo] {"

      refute functions =~ "public func listTodosNoSort(filter: TodoFilter? = nil, sort:"

      assert functions =~
               ~s[client.execute(ListRequest(action: "list_todos_no_sort", filter: filter.map { AnyEncodable($0) }, fields: fields))]
    end

    test "get actions do not gain a sort: parameter", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func getTodo(id: String, fields: [FieldSelection] = []) async throws -> Todo {"

      refute functions =~ "public func getTodo(id: String, sort:"
    end
  end

  describe "filter surface (issue #35)" do
    setup do
      %{files: Codegen.build_files(@domains)}
    end

    test "emits a {Resource}Filter struct per filterable resource", %{files: files} do
      types = files["AshRpcTypes.swift"]
      assert types =~ "public struct TodoFilter: Encodable, Sendable {"
      assert types =~ "public struct UserFilter: Encodable, Sendable {"
    end

    test "a boolean attribute exposes only eq/notEq (EquatableOperators)", %{files: files} do
      types = files["AshRpcTypes.swift"]
      # completed is a non-null Bool → equatable-only operator group, no isNil.
      assert types =~ "public var completed: EquatableOperators<Bool>?"
    end

    test "a numeric attribute exposes the comparable operator group", %{files: files} do
      types = files["AshRpcTypes.swift"]
      # score is a nullable Int → comparisons + in + isNil.
      assert types =~ "public var score: NullableComparableOperators<Int>?"
    end

    test "a date/datetime attribute exposes the comparable operator group", %{files: files} do
      types = files["AshRpcTypes.swift"]
      # dueAt is a nullable utc_datetime_usec (→ Date) → comparisons + in + isNil.
      assert types =~ "public var dueAt: NullableComparableOperators<Date>?"
      # Decimal/Date map to Swift String but stay in the comparable group (Ash type drives it).
      assert types =~ "public var amount: NullableComparableOperators<String>?"
    end

    test "an enum attribute filters over the generated Swift enum", %{files: files} do
      types = files["AshRpcTypes.swift"]
      assert types =~ "public var priority: NullableEnumOperators<TodoPriority>?"
      assert types =~ "public var status: NullableEnumOperators<TodoStatus>?"
    end

    test "a non-null string attribute uses the in-group without isNil", %{files: files} do
      types = files["AshRpcTypes.swift"]
      # title is allow_nil?: false → EnumOperators (eq/notEq/in), no Nullable prefix.
      assert types =~ "public var title: EnumOperators<String>?"
    end

    test "a nullable attribute adds isNil via the Nullable operator group", %{files: files} do
      types = files["AshRpcTypes.swift"]
      # `default` is a nullable String → NullableEnumOperators, and the keyword is escaped.
      assert types =~ "public var `default`: NullableEnumOperators<String>?"
      refute types =~ "public var default:"
    end

    test "excludes composite Ash.Type.Map attributes from the filter", %{files: files} do
      types = files["AshRpcTypes.swift"]

      filter_struct =
        Regex.run(~r/public struct TodoFilter: Encodable, Sendable \{.*?\n\}/s, types) |> hd()

      refute filter_struct =~ "metadata"
    end

    test "filter struct imports nothing extra — operator generics come from the runtime", %{
      files: files
    } do
      types = files["AshRpcTypes.swift"]
      # The runtime import already present must cover the operator generics.
      assert types =~ "import AshSwiftRuntime"
    end

    test "list read action gains an optional typed filter: parameter", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func listTodos(filter: TodoFilter? = nil, sort: [SortField<TodoSortField>] = [], fields: [FieldSelection] = []) async throws -> [Todo] {"

      assert functions =~
               ~s[client.execute(ListRequest(action: "list_todos", filter: filter.map { AnyEncodable($0) }, sort: ashSortString(sort), fields: fields))]
    end

    test "enable_filter?: false action is emitted WITHOUT a filter: parameter", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      # Sorting stays on for this action, so it keeps sort: but drops filter:.
      assert functions =~
               "public func listTodosNoFilter(sort: [SortField<TodoSortField>] = [], fields: [FieldSelection] = []) async throws -> [Todo] {"

      refute functions =~ "public func listTodosNoFilter(filter:"

      assert functions =~
               ~s[client.execute(ListRequest(action: "list_todos_no_filter", sort: ashSortString(sort), fields: fields))]
    end

    test "get actions do not gain a filter: parameter", %{files: files} do
      functions = files["AshRpcFunctions.swift"]
      refute functions =~ "public func getTodo(id: String, filter:"
    end

    test "a resource with no filterable attributes emits a valid filter struct with only combinators" do
      # MapOnly's only public attribute is an Ash.Type.Map (excluded from
      # filtering) and its primary key is non-public, so the filterable read
      # produces a filter struct with no per-attribute predicates — only the
      # and/or/not combinators (#36) and the no-arg init. The struct must still be
      # valid, compilable Swift (an empty raw-value enum would not be — see the
      # sort-enum bug, issue #41 — but a struct of optional arrays is fine).
      files = Codegen.build_files([AshSwift.Test.MapOnlyDomain])
      types = files["AshRpcTypes.swift"]

      assert types =~ """
             public struct MapOnlyFilter: Encodable, Sendable {
                 public var and: [MapOnlyFilter]?
                 public var or: [MapOnlyFilter]?
                 public var not: [MapOnlyFilter]?

                 public init() {}
             }\
             """

      # No attribute predicates leaked in (metadata is excluded, id is non-public):
      # the only `public var`s are the three combinators.
      filter_struct =
        Regex.run(~r/public struct MapOnlyFilter: Encodable, Sendable \{.*?\n\}/s, types) |> hd()

      refute filter_struct =~ "metadata"
      refute filter_struct =~ "Operators<"

      # The read function still threads the filter type — the parameter is
      # generated from the action's enable_filter?, not from whether fields exist.
      assert files["AshRpcFunctions.swift"] =~
               "public func listMapOnlys(filter: MapOnlyFilter? = nil, fields: [FieldSelection] = [])"
    end
  end

  describe "empty sort surface (issue #41)" do
    test "a sortable read over a resource with no sortable attributes emits no SortField enum and no sort: param" do
      # MapOnly's only public attribute is an Ash.Type.Map (excluded by
      # sortable_attribute?/1) and its primary key is non-public, so the
      # sort-enabled `list_map_onlys_sortable` read has zero sortable fields.
      # Codegen must drop the sort surface entirely rather than emit
      # `public enum MapOnlySortField: String, Sendable {}`, which does not compile
      # (an empty raw-value enum has no RawRepresentable conformance).
      files = Codegen.build_files([AshSwift.Test.MapOnlyDomain])
      types = files["AshRpcTypes.swift"]
      functions = files["AshRpcFunctions.swift"]

      # No SortField enum (empty or otherwise) for a resource with no sortable fields.
      refute types =~ "MapOnlySortField"

      # The sort-enabled read drops the `sort:` parameter, exactly as
      # `enable_sort?: false` does. MapOnly never sorts, so no function in this
      # domain references a sort parameter at all.
      assert functions =~
               "public func listMapOnlysSortable(filter: MapOnlyFilter? = nil, fields: [FieldSelection] = [])"

      refute functions =~ "sort:"
    end
  end

  describe "filter logical combinators (issue #36)" do
    setup do
      %{files: Codegen.build_files(@domains)}
    end

    test "each filter type gains and/or/not arrays of the same filter type", %{files: files} do
      types = files["AshRpcTypes.swift"]

      assert types =~ "public var and: [TodoFilter]?"
      assert types =~ "public var or: [TodoFilter]?"
      assert types =~ "public var not: [TodoFilter]?"

      assert types =~ "public var and: [UserFilter]?"
      assert types =~ "public var or: [UserFilter]?"
      assert types =~ "public var not: [UserFilter]?"
    end

    test "combinators sit after the per-attribute predicates, before init", %{files: files} do
      types = files["AshRpcTypes.swift"]

      todo_filter =
        Regex.run(~r/public struct TodoFilter: Encodable, Sendable \{.*?\n\}/s, types) |> hd()

      # A per-attribute predicate (title) precedes the combinators, which precede init.
      assert todo_filter =~
               ~r/public var title: EnumOperators<String>\?.*public var and: \[TodoFilter\]\?.*public var or: \[TodoFilter\]\?.*public var not: \[TodoFilter\]\?\n\n    public init\(\) \{\}/s
    end

    test "combinator keys are emitted verbatim — not run through the field formatter", %{
      files: files
    } do
      types = files["AshRpcTypes.swift"]
      # The wire keys are literally and/or/not; no camelCasing or escaping applied.
      refute types =~ "public var `and`:"
      refute types =~ "public var `or`:"
      refute types =~ "public var `not`:"
    end
  end

  describe "optional pagination overload (issue #37)" do
    setup do
      %{files: Codegen.build_files(@domains)}
    end

    test "a list read with optional pagination keeps its bare [T] overload unchanged", %{
      files: files
    } do
      functions = files["AshRpcFunctions.swift"]

      # The M1 bare-list function is byte-identical — omitting page preserves it,
      # so existing `[Todo]` call sites do not regress.
      assert functions =~
               "public func listTodos(filter: TodoFilter? = nil, sort: [SortField<TodoSortField>] = [], fields: [FieldSelection] = []) async throws -> [Todo] {"
    end

    test "a list read with optional offset pagination gains a paginated overload", %{
      files: files
    } do
      functions = files["AshRpcFunctions.swift"]

      # The overload's `page` is REQUIRED (no `= nil`), which is what makes Swift
      # resolve `listTodos(page:)` here and bare `listTodos()` to the [Todo] form.
      assert functions =~
               "public func listTodos(page: OffsetPageParams, filter: TodoFilter? = nil, sort: [SortField<TodoSortField>] = [], fields: [FieldSelection] = []) async throws -> OffsetPage<Todo> {"

      # Filter + sort + page all compose on the single paginated call.
      assert functions =~
               ~s[client.execute(OffsetPageRequest(action: "list_todos", page: page, filter: filter.map { AnyEncodable($0) }, sort: ashSortString(sort), fields: fields))]
    end

    test "the overload pair is emitted for every optional-pagination list read", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      # list_users is a plain default read too: it gets the same bare + paginated pair.
      assert functions =~
               "public func listUsers(filter: UserFilter? = nil, sort: [SortField<UserSortField>] = [], fields: [FieldSelection] = []) async throws -> [User] {"

      assert functions =~
               "public func listUsers(page: OffsetPageParams, filter: UserFilter? = nil, sort: [SortField<UserSortField>] = [], fields: [FieldSelection] = []) async throws -> OffsetPage<User> {"
    end

    test "an optional-pagination read with sort/filter disabled omits those params on both overloads",
         %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      # enable_sort?: false ⇒ no sort: on either overload; filter still present.
      assert functions =~
               "public func listTodosNoSort(filter: TodoFilter? = nil, fields: [FieldSelection] = []) async throws -> [Todo] {"

      assert functions =~
               "public func listTodosNoSort(page: OffsetPageParams, filter: TodoFilter? = nil, fields: [FieldSelection] = []) async throws -> OffsetPage<Todo> {"

      # enable_filter?: false ⇒ no filter: on either overload; sort still present.
      assert functions =~
               "public func listTodosNoFilter(sort: [SortField<TodoSortField>] = [], fields: [FieldSelection] = []) async throws -> [Todo] {"

      assert functions =~
               "public func listTodosNoFilter(page: OffsetPageParams, sort: [SortField<TodoSortField>] = [], fields: [FieldSelection] = []) async throws -> OffsetPage<Todo> {"
    end

    test "an action supporting only keyset gets a keyset overload, not offset", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func listTodosKeysetOptional(page: KeysetPageParams, filter: TodoFilter? = nil, sort: [SortField<TodoSortField>] = [], fields: [FieldSelection] = []) async throws -> KeysetPage<Todo> {"

      assert functions =~
               ~s[client.execute(KeysetPageRequest(action: "list_todos_keyset_optional", page: page, filter: filter.map { AnyEncodable($0) }, sort: ashSortString(sort), fields: fields))]
    end

    test "required-pagination actions get no extra overload (single function only)", %{
      files: files
    } do
      functions = files["AshRpcFunctions.swift"]

      # list_todos_offset requires pagination, so it has exactly one function and no
      # bare [Todo] sibling — count the `func listTodosOffset(` occurrences.
      occurrences =
        functions
        |> String.split("public func listTodosOffset(")
        |> length()
        |> Kernel.-(1)

      assert occurrences == 1
    end

    test "get actions never gain a paginated overload", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      refute functions =~ "public func getTodo(page:"
      refute functions =~ "public func findTodoByTitle(page:"
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

  describe "enum/struct type name collision detection" do
    test "error message names the colliding type and suggests a rename" do
      assert_raise Mix.Error,
                   ~r/enum type name\(s\) "CollisionItemPriority" conflict.*rename/s,
                   fn ->
                     Codegen.build_files([AshSwift.Test.CollisionDomain])
                   end
    end

    test "no-collision domains produce unchanged output (no regression)" do
      # Calling build_files/1 on the main domain must not raise
      assert %{"AshRpcTypes.swift" => _, "AshRpcFunctions.swift" => _} =
               Codegen.build_files([AshSwift.Test.Domain])
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
