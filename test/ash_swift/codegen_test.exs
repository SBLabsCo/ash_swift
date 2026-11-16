defmodule AshSwift.CodegenTest do
  @moduledoc """
  End-to-end tests of the full pipeline (manifest -> Reader -> Emitter) over the
  fixture domains: the Swift source codegen emits, never its internal helpers.
  Pure Swift formatting is pinned in `codegen/emitter_test.exs` over a hand-built
  IR, and Reader classifications in `codegen/reader_test.exs`.
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

    # Smoke check across the whole pipeline (manifest → Reader → Emitter). The
    # per-construct formatting assertions live in codegen/emitter_test.exs over a
    # hand-built IR; this only confirms the fixture domain reaches the output.
    test "end to end: the fixture domain's structs, enums, input structs and functions are emitted",
         %{files: files} do
      types = files["AshRpcTypes.swift"]
      functions = files["AshRpcFunctions.swift"]

      assert types =~ "public struct Todo: Codable, Sendable, Equatable {"
      assert types =~ "public var priority: TodoPriority?"
      assert types =~ "public enum TodoPriority: String, Codable, Sendable, Equatable {"
      # An Ash.Type.Enum member named like a Swift keyword is escaped.
      assert types =~ "    case `case`"
      assert types =~ "public struct CreateTodoInput: Encodable, Sendable {"
      assert types =~ "public struct TodoFilter: Encodable, Sendable {"
      assert types =~ "public enum TodoSortField: String, Sendable {"

      assert functions =~ "public func createTodo(input: CreateTodoInput,"
      assert functions =~ "public func updateTodo(id: String, input: UpdateTodoInput,"
      # An RPC action named like a Swift keyword is escaped.
      assert functions =~ "public func `init`("
    end

    test "emits a Swift enum for an aggregate whose resolved type is an enum",
         %{files: files} do
      types = files["AshRpcTypes.swift"]
      # `top_priority` is a `first` aggregate over the enum attribute :priority, so
      # it resolves to an enum type and is emitted like an enum attribute: a typed
      # field plus a per-resource generated enum.
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

    test "emits a Swift enum for a zero-argument calculation whose type is an enum",
         %{files: files} do
      types = files["AshRpcTypes.swift"]
      # `name_size` is a zero-arg :atom calculation with a one_of constraint, so it
      # resolves to an enum and is emitted like an enum attribute: a typed field
      # plus a per-resource generated enum. This exercises the enum branch of the
      # Reader's derived-field classifier (private `emit_derived_fields/5`) from
      # the *calculation* path (aggregates cover it too, but only indirectly for
      # calcs).
      assert types =~ "public enum UserNameSize: String, Codable, Sendable, Equatable {"

      # Scope the case assertions to the UserNameSize block so they stay
      # load-bearing (a whole-file `case short` could be satisfied elsewhere).
      enum_block = Regex.run(~r/public enum UserNameSize:.*?\n\}/s, types) |> List.first()
      assert enum_block =~ "case long"
      assert enum_block =~ "case short"
    end

    test "non-String get_by field (integer) is always emitted as String parameter type", %{
      files: files
    } do
      functions = files["AshRpcFunctions.swift"]

      # score is Ash.Type.Integer; ash_type_to_swift would emit "Int", but
      # lookup params travel in [String: String] dicts so must always be String.
      assert functions =~
               "public func getTodoByScore(score: String, fields: [FieldSelection]) async throws -> Todo {"
    end

    test "pure get? action with arguments takes input: and no lookup param (#91)", %{
      files: files
    } do
      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func fetchTodoByTitle(input: FetchTodoByTitleInput, fields: [FieldSelection]) async throws -> Todo {"

      assert functions =~
               "GetRequest(action: \"fetch_todo_by_title\", arguments: AnyEncodable(input)"
    end

    test "is deterministic — same domains produce byte-identical output", %{files: files} do
      assert Codegen.build_files(@domains) == files
    end
  end

  describe "filter surface (issue #35)" do
    test "a resource with no filterable attributes emits a valid filter struct with only combinators" do
      # MapOnly's only public attribute is an Ash.Type.Map (excluded from
      # filtering) and its primary key is non-public, so the filterable read
      # produces a filter struct with no per-attribute predicates — only the
      # and/or/not combinators (#36) and the no-arg init. The struct must still be
      # valid, compilable Swift (an empty raw-value enum would not be — see the
      # sort-enum bug, issue #41 — but a struct of optional arrays is fine).
      files = Codegen.build_files([AshSwift.Test.MapOnlyDomain])

      # The empty filter struct itself is pinned in reader_test (IR) and
      # emitter_test (rendering); here only that it reaches the output.
      assert files["AshRpcTypes.swift"] =~ "public struct MapOnlyFilter: Encodable, Sendable {"

      # The read function still threads the filter type — the parameter is
      # generated from the action's enable_filter?, not from whether fields exist.
      assert files["AshRpcFunctions.swift"] =~
               "public func listMapOnlys(filter: MapOnlyFilter? = nil, fields: [FieldSelection])"
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
               "public func listMapOnlysSortable(filter: MapOnlyFilter? = nil, fields: [FieldSelection])"

      refute functions =~ "sort:"
    end
  end

  describe "optional pagination overload (issue #37)" do
    # Overload shapes are pinned in emitter_test over a hand-built IR, and the
    # classification (optional vs required, gets excluded) in reader_test; this
    # only confirms the fixture's optional-pagination read reaches the output.
    test "an optional-pagination list read gains a paginated overload beside its bare form" do
      functions = Codegen.build_files(@domains)["AshRpcFunctions.swift"]

      assert functions =~ "public func listTodos(filter: TodoFilter? = nil, sort:"
      assert functions =~ "public func listTodos(page: OffsetPageParams, filter:"
    end
  end

  describe "generic actions (issue #54)" do
    setup do
      %{files: Codegen.build_files(@domains)}
    end

    test "a void action with an argument emits a VoidActionRequest call + typed input struct", %{
      files: files
    } do
      functions = files["AshRpcFunctions.swift"]
      types = files["AshRpcTypes.swift"]

      # No return type (side-effecting) → void function, VoidActionRequest. The
      # input generic is inferred from `input:`, so it is NOT pinned explicitly.
      assert functions =~
               "public func requestMagicLink(input: RequestMagicLinkInput) async throws {"

      assert functions =~
               ~s[try await client.execute(VoidActionRequest(action: "request_magic_link", input: input))]

      # The argument (not a resource attribute) becomes a required input field.
      assert types =~ "public struct RequestMagicLinkInput: Encodable, Sendable {"
      assert types =~ "public var email: String\n"
    end

    test "a scalar-returning action with required + optional args maps the return and both args",
         %{files: files} do
      functions = files["AshRpcFunctions.swift"]
      types = files["AshRpcTypes.swift"]

      # Scalar return → typed return; input present so the output generic infers
      # from the return position (no explicit generics on GenericActionRequest).
      assert functions =~ "public func echo(input: EchoInput) async throws -> String {"

      assert functions =~
               ~s[return try await client.execute(GenericActionRequest(action: "echo", input: input))]

      # required? drives optionality: message (required) is non-optional + plain
      # encode; loud (optional argument) is Optional + encodeIfPresent.
      assert types =~ "public var message: String\n"
      assert types =~ "public var loud: Bool?\n"
      assert types =~ "try container.encode(message, forKey: .message)"
      assert types =~ "try container.encodeIfPresent(loud, forKey: .loud)"
    end

    test "a no-argument scalar action pins both generics and takes no input param", %{
      files: files
    } do
      functions = files["AshRpcFunctions.swift"]

      # No `input:` to anchor the input generic, so both O and I are explicit.
      assert functions =~ "public func ping() async throws -> String {"

      assert functions =~
               ~s[return try await client.execute(GenericActionRequest<String, EmptyActionInput>(action: "ping"))]

      # A no-arg action emits no input struct.
      refute files["AshRpcTypes.swift"] =~ "PingInput"
    end

    test "a map-returning action maps to a [String: AshJSON] return", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      assert functions =~ "public func stats() async throws -> [String: AshJSON] {"

      assert functions =~
               "client.execute(GenericActionRequest<[String: AshJSON], EmptyActionInput>(action: \"stats\"))"
    end

    test "a struct return of a resource emits a field-selected optional model return (#56)",
         %{files: files} do
      # `summarize` returns a struct (instance_of Todo): the pipeline requires
      # `fields:`, and the action may return nil, so the function returns `Todo?`.
      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func summarize(fields: [FieldSelection]) async throws -> Todo? {"

      # Without `allow_nil? true` the return is a non-optional `Todo`.
      assert functions =~
               "public func summarizeRequired(fields: [FieldSelection]) async throws -> Todo {"

      assert functions =~
               ~s[client.execute(GenericActionRequest<Todo?, EmptyActionInput>(action: "summarize", fields: fields))]

      # The target model struct is emitted by the existing model path — no result struct.
      refute files["AshRpcTypes.swift"] =~ "SummarizeResult"
    end

    test "an array-of-resource return is not emitted (warning pinned in reader_test)", %{
      files: files
    } do
      refute files["AshRpcFunctions.swift"] =~ "func summarizeAll"
    end

    test "a void no-argument action emits VoidActionRequest<EmptyActionInput> and no input param",
         %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      # The {:void, nil} branch: no `input:` to anchor the input generic, so it is
      # pinned explicitly to EmptyActionInput and the function takes no parameters.
      assert functions =~ "public func pingVoid() async throws {"

      assert functions =~
               ~s[try await client.execute(VoidActionRequest<EmptyActionInput>(action: "ping_void"))]

      refute files["AshRpcTypes.swift"] =~ "PingVoidInput"
    end

    test "a Swift-keyword-named argument is backtick-escaped in the input struct", %{files: files} do
      types = files["AshRpcTypes.swift"]

      # `default` is a Swift keyword; generic-action arguments share render_input_struct,
      # so the escaping must reach them (lessons.md: escape every identifier emitter).
      assert types =~ "public struct EchoConfigInput: Encodable, Sendable {"
      assert types =~ "public var `default`: String"
      assert types =~ "try container.encode(`default`, forKey: .`default`)"
    end

    test "an array-argument generic action renders an input-taking function and input struct", %{
      files: files
    } do
      functions = files["AshRpcFunctions.swift"]
      types = files["AshRpcTypes.swift"]

      # The element-wise [Scalar] mapping is covered in reader_test.exs
      # ("generic-action array arguments").
      assert functions =~ "public func broadcast(input: BroadcastInput) async throws {"
      assert types =~ "public struct BroadcastInput: Encodable, Sendable {"
    end

    test "an array-of-record argument generates a typed nested input struct", %{files: files} do
      functions = files["AshRpcFunctions.swift"]
      types = files["AshRpcTypes.swift"]

      # `bulk_create` takes a `{:array, :map}` argument with field constraints. The
      # element becomes a compiler-checked nested struct, not `[[String: AshJSON]]`.
      assert functions =~ "public func bulkCreate(input: BulkCreateInput) async throws"

      assert types =~ "public struct BulkCreateInput: Encodable, Sendable {"

      # The generated element struct, with field optionality from allow_nil?.
      assert types =~ "public struct BulkCreateRowsItem: Encodable, Sendable {"
      assert types =~ "try container.encode(label, forKey: .label)"
      assert types =~ "try container.encodeIfPresent(priority, forKey: .priority)"
    end

    test "an array-of-map argument action renders an input-taking function", %{files: files} do
      assert files["AshRpcFunctions.swift"] =~
               "public func bulkRaw(input: BulkRawInput) async throws"
    end
  end

  describe "create/update action arguments (issue #83)" do
    setup do
      %{files: Codegen.build_files(@domains)}
    end

    test "an unmappable argument is warned about and the rest of the action is still emitted", %{
      files: files
    } do
      log = ExUnit.CaptureLog.capture_log(fn -> Codegen.build_files(@domains) end)

      assert log =~ "argument :grid of action :create_with_args"
      # The rest of the action is still emitted.
      assert files["AshRpcFunctions.swift"] =~
               "public func createTodoWithArgs(input: CreateTodoWithArgsInput, fields: [FieldSelection]) async throws -> Todo {"
    end

    test "the 'arguments are not yet supported' warning is gone" do
      log = ExUnit.CaptureLog.capture_log(fn -> Codegen.build_files(@domains) end)

      refute log =~ "not yet supported"
      refute log =~ "is not a public attribute"
    end
  end

  describe "arguments named like a private attribute (issue #84)" do
    setup do
      %{files: Codegen.build_files(@domains)}
    end

    test "an argument-only update and a generic action whose argument shadows a private attribute are both emitted with input-taking functions",
         %{files: files} do
      assert files["AshRpcFunctions.swift"] =~
               "public func setTodoDueDate(id: String, input: SetTodoDueDateInput, fields: [FieldSelection]) async throws -> Todo {"

      assert files["AshRpcFunctions.swift"] =~
               "public func checkTodoDueDate(input: CheckTodoDueDateInput) async throws -> Bool {"
    end

    test "no omission warning is logged for either action" do
      log = ExUnit.CaptureLog.capture_log(fn -> Codegen.build_files(@domains) end)

      refute log =~ ":set_due_date"
      refute log =~ ":check_due_date"
    end
  end

  describe "destroy action arguments (issue #102)" do
    setup do
      %{files: Codegen.build_files(@domains)}
    end

    test "a required argument generates an input struct and a required input:", %{files: files} do
      body = input_struct(files["AshRpcTypes.swift"], "ArchiveTodoInput")
      assert body =~ "    public var reason: String\n"

      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func archiveTodo(id: String, input: ArchiveTodoInput) async throws {"

      assert functions =~
               ~s|DestroyRequest(action: "archive_todo", identity: id, input: AnyEncodable(input))|
    end

    test "only-optional arguments make input: optional, with keyword escaping", %{files: files} do
      body = input_struct(files["AshRpcTypes.swift"], "DiscardTodoInput")
      assert body =~ "    public var `default`: String?\n"
      assert body =~ "    public var hard: Bool?\n"

      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func discardTodo(id: String, input: DiscardTodoInput? = nil) async throws {"

      assert functions =~
               ~s|DestroyRequest(action: "discard_todo", identity: id, input: input.map { AnyEncodable($0) })|
    end

    test "a destroy without arguments keeps its exact signature", %{files: files} do
      functions = files["AshRpcFunctions.swift"]
      assert functions =~ "public func destroyTodo(id: String) async throws {"
      assert functions =~ ~s|DestroyRequest(action: "destroy_todo", identity: id)|
      refute files["AshRpcTypes.swift"] =~ "DestroyTodoInput"
    end
  end

  describe "read action arguments (issue #87)" do
    setup do
      %{files: Codegen.build_files(@domains)}
    end

    defp input_struct(types, name) do
      [_, rest] = String.split(types, "public struct #{name}: Encodable, Sendable {", parts: 2)
      rest |> String.split("\n}\n", parts: 2) |> hd()
    end

    test "a list read's optional uuid and boolean arguments generate an all-optional input struct",
         %{files: files} do
      body = input_struct(files["AshRpcTypes.swift"], "SearchTodosInput")

      assert body =~ "    public var userId: String?\n"
      assert body =~ "    public var completedOnly: Bool?\n"
      assert body =~ "public init(completedOnly: Bool? = nil, userId: String? = nil)"
    end

    test "a list read takes an optional input: and sends it under `input`", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func searchTodos(input: SearchTodosInput? = nil, filter: TodoFilter? = nil, sort: [SortField<TodoSortField>] = [], fields: [FieldSelection]) async throws -> [Todo] {"

      assert functions =~
               ~s|ListRequest(action: "search_todos", input: input.map { AnyEncodable($0) }, filter:|
    end

    test "a required argument makes input: required", %{files: files} do
      assert input_struct(files["AshRpcTypes.swift"], "SearchTodosPagedInput") =~
               "    public var titleContains: String\n"

      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func searchTodosPaged(input: SearchTodosPagedInput, page: OffsetPageParams? = nil,"

      assert functions =~
               ~s|OffsetPageRequest(action: "search_todos_paged", input: AnyEncodable(input), page: page,|
    end

    test "both optional-pagination overloads carry input:", %{files: files} do
      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func searchTodosKeysetOptional(input: SearchTodosKeysetOptionalInput? = nil, filter: TodoFilter? = nil,"

      assert functions =~
               "public func searchTodosKeysetOptional(input: SearchTodosKeysetOptionalInput? = nil, page: KeysetPageParams, filter:"

      assert functions =~
               ~s|KeysetPageRequest(action: "search_todos_keyset_optional", input: input.map { AnyEncodable($0) }, page: page,|
    end

    test "a native get_by read keeps its lookup param and excludes it from the input struct", %{
      files: files
    } do
      body = input_struct(files["AshRpcTypes.swift"], "GetTodoScopedInput")
      assert body =~ "    public var completedOnly: Bool?\n"
      refute body =~ "public var id"

      functions = files["AshRpcFunctions.swift"]

      assert functions =~
               "public func getTodoScoped(id: String, input: GetTodoScopedInput? = nil, fields: [FieldSelection]) async throws -> Todo {"

      assert functions =~
               ~s|GetRequest(action: "get_todo_scoped", input: ["id": id], arguments: input.map { AnyEncodable($0) }, fields: fields)|
    end

    test "an RPC-level get_by read sends getBy plus arguments", %{files: files} do
      assert files["AshRpcFunctions.swift"] =~
               ~s|GetRequest(action: "find_todo_scoped", getBy: ["title": title], arguments: input.map { AnyEncodable($0) }, fields: fields)|
    end

    test "reads without arguments keep their exact signatures", %{files: files} do
      functions = files["AshRpcFunctions.swift"]
      types = files["AshRpcTypes.swift"]

      assert functions =~
               "public func listTodos(filter: TodoFilter? = nil, sort: [SortField<TodoSortField>] = [], fields: [FieldSelection]) async throws -> [Todo] {"

      assert functions =~
               ~s|ListRequest(action: "list_todos", filter: filter.map { AnyEncodable($0) }, sort: ashSortString(sort), fields: fields)|

      assert functions =~
               ~s|GetRequest(action: "get_todo", input: ["id": id], fields: fields)|

      assert functions =~
               "public func getTodo(id: String, fields: [FieldSelection]) async throws -> Todo {"

      # A native get_by's lookup field is not an "argument" — no input struct.
      refute types =~ "GetTodoInput"
      refute types =~ "ListTodosInput"
    end
  end

  describe "generic-action constrained-map return (issue #70)" do
    setup do
      %{files: Codegen.build_files(@domains)}
    end

    test "a constrained :map return emits a typed Decodable result struct, not [String: AshJSON]",
         %{files: files} do
      functions = files["AshRpcFunctions.swift"]
      types = files["AshRpcTypes.swift"]

      # `upload_start` returns a `:map` carrying `fields:` constraints — the typed
      # manifest mirrors SwingClips' upload_start. The function returns the generated
      # struct (not `[String: AshJSON]`), the input generic infers from `input:`, and
      # — because the return is field-selectable — it carries a required `fields:`
      # selection the RPC pipeline demands (issue #73).
      assert functions =~
               "public func uploadStart(input: UploadStartInput, fields: [FieldSelection]) async throws -> UploadStartResult {"

      assert functions =~
               ~s[return try await client.execute(GenericActionRequest(action: "upload_start", input: input, fields: fields))]

      # Regression (issue #73): the fields-less form the RPC pipeline rejects must
      # not be emitted for a field-selectable typed-record return.
      refute functions =~
               "public func uploadStart(input: UploadStartInput) async throws -> UploadStartResult {"

      # Decode-only struct (no encode/CodingKeys — Swift synthesises init(from:)).
      assert types =~ "public struct UploadStartResult: Decodable, Sendable, Equatable {"

      # Required only when the map constraint set allow_nil?: false; the nullable-
      # default scalar and the unconstrained map field are Optional.
      assert types =~ "public var videoId: String\n"
      assert types =~ "public var caption: String?"
      assert types =~ "public var metadata: [String: AshJSON]?"
      # The {:array, :map} field is typed by the generated element struct.
      assert types =~ "public var clips: [UploadStartResultClipsItem]?"
    end

    test "an {:array, :map} return field emits a typed, Decodable nested struct", %{files: files} do
      types = files["AshRpcTypes.swift"]

      # The nested element struct carries the result-struct prefix so it never
      # collides with an argument-side `clips` nested struct on the same action.
      assert types =~ "public struct UploadStartResultClipsItem: Decodable, Sendable, Equatable {"
      assert types =~ "public var clipId: String\n"
      assert types =~ "public var orderIndex: Int\n"
      assert types =~ "public var uploadUrl: String\n"
    end

    test "an unconstrained :map return still maps to [String: AshJSON] (no struct)", %{
      files: files
    } do
      functions = files["AshRpcFunctions.swift"]

      # Regression guard: `stats` has no `fields:` constraint, so it stays the
      # untyped dict — only a *constrained* map gets a generated struct.
      assert functions =~ "public func stats() async throws -> [String: AshJSON] {"
      refute files["AshRpcTypes.swift"] =~ "StatsResult"
    end
  end

  describe "generic action returning an unexposed, unrelated resource (#56)" do
    # The classification (IR) is pinned in reader_test.exs; this checks the model
    # struct reaches the rendered types file.
    test "renders the target's model struct" do
      files = Codegen.build_files([AshSwift.Test.ReturnOnlyDomain])

      assert files["AshRpcTypes.swift"] =~
               "public struct Publisher: Codable, Sendable, Equatable {"
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

  describe "generate/2 and stale_files/2 against a temp dir" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "ash_swift_codegen_#{System.unique_integer([:positive])}")

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

    test "regenerating with no schema change writes nothing", %{dir: dir} do
      assert {:ok, first} = Codegen.generate(@domains, dir)
      assert "AshRpcTypes.swift" in first

      # Second run sees identical content and writes nothing — no diff, no churn.
      assert {:ok, []} = Codegen.generate(@domains, dir)
    end
  end
end
