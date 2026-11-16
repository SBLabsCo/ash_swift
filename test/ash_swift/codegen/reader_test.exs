defmodule AshSwift.Codegen.ReaderTest do
  @moduledoc """
  Tests the manifest Reader against the Codegen IR directly — the classification
  logic (enum detection, filter-operator-group selection, sort surface, generic-
  action gating) that was previously only observable through rendered-Swift
  substrings. Asserting on the IR as data is the test-surface win of the
  Reader/Emitter split (ADR-0010).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshSwift.Codegen.Reader
  alias AshSwift.Test.ActionIRKeys

  @domains [AshSwift.Test.Domain]

  # The IR is immutable data; read it once for the whole module. setup_all runs
  # outside the per-test process, so capture the skip warnings here.
  setup_all do
    {ir, _log} = with_log(fn -> Reader.read(@domains) end)
    %{ir: ir}
  end

  defp resource(ir, type_name), do: Enum.find(ir.all_resources, &(&1.type_name == type_name))

  defp attr_type(res, name), do: Enum.find(res.fields, &(&1.name == name)).swift_type

  defp input_struct(ir, name) do
    todo = resource(ir, "Todo")
    Enum.find(todo.input_structs, &(&1.struct_name == name))
  end

  defp input_field(struct, name), do: Enum.find(struct.fields, &(&1.name == name))

  describe "read/1 shape" do
    test "returns primary and all resource lists of plain maps", %{ir: ir} do
      assert Enum.map(ir.primary_resources, & &1.type_name) == ["Todo", "User"]

      # all_resources folds in related resources, so it is a superset of primary.
      primary = MapSet.new(ir.primary_resources, & &1.type_name)
      all = MapSet.new(ir.all_resources, & &1.type_name)
      assert MapSet.subset?(primary, all)
    end
  end

  describe "action IR key sets (#95)" do
    test "CRUD actions carry exactly the documented keys; generic actions their own set", %{
      ir: ir
    } do
      todo = resource(ir, "Todo")

      for name <- [
            :list_todos,
            :get_todo,
            :fetch_todo,
            :create_todo,
            :update_todo,
            :destroy_todo,
            :archive_todo,
            :discard_todo
          ] do
        action = Enum.find(todo.actions, &(&1.rpc_name == name))

        assert MapSet.new(Map.keys(action)) == ActionIRKeys.crud(),
               "CRUD keys drifted for #{name}"
      end

      ping = Enum.find(todo.actions, &(&1.rpc_name == :ping))
      assert MapSet.new(Map.keys(ping)) == ActionIRKeys.generic()
    end
  end

  describe "list and get action flags (#34, #35, #37, #41)" do
    defp action_ir(ir, type_name, rpc_name),
      do: Enum.find(resource(ir, type_name).actions, &(&1.rpc_name == rpc_name))

    test "a default list read is sortable and filterable; enable_sort?/enable_filter? false each drop one",
         %{ir: ir} do
      assert %{sortable?: true, filterable?: true} = action_ir(ir, "Todo", :list_todos)
      assert %{sortable?: false, filterable?: true} = action_ir(ir, "Todo", :list_todos_no_sort)
      assert %{sortable?: true, filterable?: false} = action_ir(ir, "Todo", :list_todos_no_filter)
    end

    test "a get is never sortable, filterable or paginated, and never has an optional pagination overload",
         %{ir: ir} do
      for name <- [
            :get_todo,
            :find_todo,
            :fetch_todo,
            :find_todo_by_title,
            :find_todo_offset_by_title
          ] do
        assert %{
                 sortable?: false,
                 filterable?: false,
                 pagination_type: :none,
                 optional_pagination_type: :none
               } =
                 action_ir(ir, "Todo", name)
      end
    end

    test "not_found_error? is true by default and false when the RPC action says so", %{ir: ir} do
      assert %{not_found_error?: true} = action_ir(ir, "Todo", :get_todo)
      assert %{not_found_error?: false} = action_ir(ir, "Todo", :find_todo)
    end

    test "optional pagination is classified by the supported types; required pagination is not optional",
         %{ir: ir} do
      assert %{optional_pagination_type: :offset, pagination_type: :none} =
               action_ir(ir, "Todo", :list_todos)

      assert %{optional_pagination_type: :keyset} =
               action_ir(ir, "Todo", :list_todos_keyset_optional)

      assert %{pagination_type: :offset, optional_pagination_type: :none} =
               action_ir(ir, "Todo", :list_todos_offset)
    end

    test "a sortable read over a resource with no sortable attributes drops the sort surface (#41)" do
      ir = Reader.read([AshSwift.Test.MapOnlyDomain])

      assert %{sort_field: nil, filter_struct: %{fields: []}} = resource(ir, "MapOnly")

      assert %{sortable?: false, filterable?: true} =
               action_ir(ir, "MapOnly", :list_map_onlys_sortable)
    end
  end

  describe "destroy action inputs (#102)" do
    test "a destroy gets an input struct only when it declares inputs", %{ir: ir} do
      todo = resource(ir, "Todo")
      action = fn name -> Enum.find(todo.actions, &(&1.rpc_name == name)) end

      assert action.(:archive_todo).input_struct_name == "ArchiveTodoInput"
      assert action.(:archive_todo).input_required? == true
      assert action.(:discard_todo).input_struct_name == "DiscardTodoInput"
      assert action.(:discard_todo).input_required? == false
      assert action.(:destroy_todo).input_struct_name == nil
      assert action.(:destroy_todo).input_required? == false
      assert action.(:remove_titled_todo).input_required? == true
    end
  end

  describe "input optionality: accepted attributes and arguments (#113, #124, #75)" do
    test "require_attributes makes accepted update/destroy attributes required (#113)", %{ir: ir} do
      rename = input_struct(ir, "RenameTodoInput")
      assert %{required?: true} = input_field(rename, "title")
      assert %{required?: false} = input_field(rename, "priority")

      assert %{required?: true} = input_field(input_struct(ir, "RemoveTitledTodoInput"), "title")
    end

    test "allow_nil_input, nullable and defaulted attributes stay optional; a plain allow_nil?: false one is required (#124)",
         %{ir: ir} do
      input = input_struct(ir, "CreateLenientTodoInput")

      # allow_nil?: false, but in allow_nil_input
      assert %{required?: false} = input_field(input, "title")
      # nullable, in require_attributes: manifest says required, parity says optional
      assert %{required?: false} = input_field(input, "score")
      # has a default, in require_attributes
      assert %{required?: false} = input_field(input, "completed")

      # control: allow_nil?: false, no default, not in allow_nil_input
      assert %{required?: true} = input_field(input_struct(ir, "CreateTodoInput"), "title")
    end

    test "a required argument named like a nullable public attribute stays required (#75)", %{
      ir: ir
    } do
      assert %{required?: true, swift_type: "Int"} =
               input_field(input_struct(ir, "SetTodoScoreInput"), "score")
    end
  end

  describe "enum classification" do
    test "an attribute with a one_of / Ash.Type.Enum type becomes a typed enum in the IR", %{
      ir: ir
    } do
      todo = resource(ir, "Todo")
      enum_names = Enum.map(todo.enums, & &1.enum_name)

      assert "TodoPriority" in enum_names
      assert "TodoStatus" in enum_names

      priority = Enum.find(todo.enums, &(&1.enum_name == "TodoPriority"))

      assert priority.cases == [
               %{name: "low", raw: nil},
               %{name: "medium", raw: nil},
               %{name: "high", raw: nil}
             ]
    end

    test "an Ash.Type.Enum attribute types its field with the generated enum", %{ir: ir} do
      todo = resource(ir, "Todo")

      assert attr_type(todo, "status") == "TodoStatus"
      status = Enum.find(todo.enums, &(&1.enum_name == "TodoStatus"))

      assert Enum.sort(Enum.map(status.cases, & &1.name)) == [
               "active",
               "archived",
               "case",
               "default",
               "pending"
             ]
    end
  end

  describe "scalar attribute type mapping" do
    # The full Ash-to-Swift table is pinned in type_map_test; this only shows the
    # Reader applies it to attributes.
    test "attributes resolve to their Swift wire type in the IR", %{ir: ir} do
      todo = resource(ir, "Todo")

      # Decimal serialises as "123.45" on the wire; String is the faithful type.
      assert attr_type(todo, "amount") == "String"
      assert attr_type(todo, "dueAt") == "Date"
    end
  end

  describe "filter-operator-group selection" do
    test "each filterable attribute carries the operator generic for its type and nullability", %{
      ir: ir
    } do
      todo = resource(ir, "Todo")
      refute is_nil(todo.filter_struct)
      groups = Map.new(todo.filter_struct.fields, &{&1.name, &1.swift_type})

      # boolean, non-null → equality only
      assert groups["completed"] == "EquatableOperators<Bool>"
      # integer, nullable → comparison operators, with isNil
      assert groups["score"] == "NullableComparableOperators<Int>"
      # uuid, non-null → equality+membership default group, over String
      assert groups["id"] == "EnumOperators<String>"
      # enum, nullable → membership over the generated enum type
      assert groups["priority"] == "NullableEnumOperators<TodoPriority>"
      assert groups["status"] == "NullableEnumOperators<TodoStatus>"
      # string, non-null → eq/notEq/in, no isNil
      assert groups["title"] == "EnumOperators<String>"
      # string, nullable → isNil added
      assert groups["default"] == "NullableEnumOperators<String>"
      # ci_string, nullable → case-insensitive-aware group
      assert groups["username"] == "NullableCiStringOperators<String>"
    end

    test "date/datetime and decimal attributes are comparable, typed by their Swift type", %{
      ir: ir
    } do
      todo = resource(ir, "Todo")
      groups = Map.new(todo.filter_struct.fields, &{&1.name, &1.swift_type})

      assert groups["dueAt"] == "NullableComparableOperators<Date>"
      # Decimal maps to a Swift String but the Ash type drives the comparable group.
      assert groups["amount"] == "NullableComparableOperators<String>"
    end

    test "every filterable resource gets a filter struct; composite maps are excluded", %{ir: ir} do
      for type_name <- ["Todo", "User"] do
        refute is_nil(resource(ir, type_name).filter_struct), "#{type_name} must be filterable"
      end

      todo = resource(ir, "Todo")
      refute "metadata" in Enum.map(todo.filter_struct.fields, & &1.name)
    end
  end

  describe "sort surface" do
    test "a resource with sortable attributes gets a typed SortField enum in the IR", %{ir: ir} do
      todo = resource(ir, "Todo")
      refute is_nil(todo.sort_field)

      assert todo.sort_field.type_name == "TodoSortField"
      assert "title" in todo.sort_field.fields
    end

    test "public comparable attributes are sortable; composite maps are not", %{ir: ir} do
      todo = resource(ir, "Todo")

      for name <- ["completed", "dueAt", "scheduledAt", "title", "amount", "status", "default"] do
        assert name in todo.sort_field.fields, "#{name} must be sortable"
      end

      # The backend can't sort by a JSON object.
      refute "metadata" in todo.sort_field.fields

      assert resource(ir, "User").sort_field.type_name == "UserSortField"
    end
  end

  describe "get? lookup location (#66, #91)" do
    test "a list read, a create and a generic action are not gets", %{ir: ir} do
      todo = resource(ir, "Todo")

      for rpc_name <- [:list_todos, :create_todo, :ping] do
        action = Enum.find(todo.actions, &(&1.rpc_name == rpc_name))
        assert action, "fixture lost #{rpc_name}"
        assert action.get == nil
      end
    end

    test "a pure get? action has no lookup params (#91)", %{ir: ir} do
      todo = resource(ir, "Todo")
      fetch = Enum.find(todo.actions, &(&1.rpc_name == :fetch_todo))

      assert fetch.get == :pure
    end

    test "a pure get? action with arguments keeps them as read input, no lookup (#91)", %{ir: ir} do
      todo = resource(ir, "Todo")
      fetch = Enum.find(todo.actions, &(&1.rpc_name == :fetch_todo_by_title))

      assert fetch.get == :pure
      assert fetch.input_struct_name == "FetchTodoByTitleInput"

      input = input_struct(ir, "FetchTodoByTitleInput")
      assert Enum.any?(input.fields, &(&1.name == "title"))
    end

    test "a native get_by action still travels via :input", %{ir: ir} do
      todo = resource(ir, "Todo")
      get_todo = Enum.find(todo.actions, &(&1.rpc_name == :get_todo))

      assert {:input, [%{name: "id"}]} = get_todo.get
    end

    test "a non-String native get_by field is coerced to a String lookup param", %{ir: ir} do
      # `score` is an Ash.Type.Integer attribute, but lookup values travel in
      # `[String: String]` dicts (lessons.md), so TypeMap's Int must not leak in.
      assert {:input, [%{name: "score", swift_type: "String"}]} =
               action_ir(ir, "Todo", :get_todo_by_score).get
    end

    test "an RPC-level get_by action still travels via :get_by", %{ir: ir} do
      todo = resource(ir, "Todo")
      find_by_title = Enum.find(todo.actions, &(&1.rpc_name == :find_todo_by_title))

      assert {:get_by, [%{name: "title"}]} = find_by_title.get
    end
  end

  describe "generic-action gating (#54)" do
    test "unmappable generic actions are dropped; supported ones kept", %{ir: ir} do
      todo = resource(ir, "Todo")
      rpc_names = Enum.map(todo.actions, & &1.rpc_name)

      # :summarize_all (an array-of-resource return) maps to no Swift type: dropped (#56).
      refute :summarize_all in rpc_names
      # :deep_broadcast takes a nested-array argument ({:array, {:array, _}}) whose element is
      # unmappable, so the whole action is skipped rather than emitted with a wrong-typed input.
      refute :deep_broadcast in rpc_names

      # :summarize (a struct return of a resource, allow_nil? true) is an optional
      # field-selected model return, carrying its target resource (#56).
      summarize = Enum.find(todo.actions, &(&1.rpc_name == :summarize))
      assert summarize.generic_return == {:typed_record, "Todo?"}
      assert summarize.generic_return_resource == AshSwift.Test.Todo

      # Ash's default allow_nil? false makes the same return non-optional.
      required = Enum.find(todo.actions, &(&1.rpc_name == :summarize_required))
      assert required.generic_return == {:typed_record, "Todo"}
      assert required.generic_return_resource == AshSwift.Test.Todo

      # Void and scalar/map generic actions are supported and kept — including the
      # void branch of generic_action_return/1 (nil -> :void), exercised by :ping_void.
      assert :stats in rpc_names
      assert :ping in rpc_names
      assert :ping_void in rpc_names

      # Array arguments are now supported: a scalar array (:broadcast) and a record
      # array (:bulk_create) both generate.
      assert :broadcast in rpc_names
      assert :bulk_create in rpc_names
    end

    test "skipped generic actions are announced with a warning" do
      log = capture_log(fn -> Reader.read(@domains) end)

      # `summarize_all` returns an array of resources, which maps to no Swift type (#56).
      assert log =~ "generic action :summarize_all"

      # `deep_broadcast` takes `{:array, {:array, :string}}`: the element is itself
      # an array, which maps to no Swift type, so the input gate skips the action.
      assert log =~ "generic action :deep_broadcast"
      assert log =~ "argument :matrix"
      assert log =~ "skipping"
    end
  end

  describe "generic action resource return targets (#56)" do
    test "an unexposed, unrelated return target's model struct is emitted" do
      ir = Reader.read([AshSwift.Test.ReturnOnlyDomain])

      assert resource(ir, "Publisher")

      reporter = resource(ir, "Reporter")
      latest = Enum.find(reporter.actions, &(&1.rpc_name == :latest_publisher))
      assert latest.generic_return == {:typed_record, "Publisher?"}
      assert latest.generic_return_resource == AshSwift.Test.Publisher
    end
  end

  describe "array attributes (#78)" do
    test "an array attribute maps to the Swift array of its element type", %{ir: ir} do
      todo = resource(ir, "Todo")

      # The regression this guards: `{:array, :string}` used to read `type.module`
      # (nil for an array) and fall through to the String catch-all, emitting a
      # scalar `String?` the device then failed to decode.
      assert attr_type(todo, "tags") == "[String]"

      # Element mapping is the shared scalar table, not a String special case.
      assert attr_type(todo, "scores") == "[Int]"
      assert attr_type(todo, "notes") == "[[String: AshJSON]]"
    end

    test "an array of an enum element maps to the generated Swift enum and emits it", %{ir: ir} do
      todo = resource(ir, "Todo")

      assert attr_type(todo, "labels") == "[TodoLabels]"

      labels = Enum.find(todo.enums, &(&1.enum_name == "TodoLabels"))
      assert labels.cases == [%{name: "red", raw: nil}, %{name: "green", raw: nil}]
    end

    test "element nullability comes from nil_items?, not the attribute's allow_nil?", %{ir: ir} do
      todo = resource(ir, "Todo")

      # `tags` is allow_nil?: false and `scores` allow_nil?: true, yet neither
      # permits nil *elements* — only `nil_tags` sets `nil_items?: true`. The array's
      # own optionality is applied by the emitter (every model field is Optional), so
      # the two nullabilities stay independent.
      assert attr_type(todo, "nilTags") == "[String?]"
      refute attr_type(todo, "tags") =~ "?"
      refute attr_type(todo, "scores") =~ "?"
    end

    test "an array whose element maps to no Swift type is omitted, not mis-typed", %{ir: ir} do
      todo = resource(ir, "Todo")

      # `matrix` is {:array, {:array, :string}}: the element is itself an array, which
      # maps to no Swift type. Omitting it makes a consumer's use site a compile
      # error; emitting a guessed `String` would compile and fail at decode instead.
      refute Enum.any?(todo.fields, &(&1.name == "matrix"))

      refute Enum.any?(todo.input_structs, fn s -> Enum.any?(s.fields, &(&1.name == "matrix")) end)
    end

    test "array attributes are excluded from the filter and sort surfaces", %{ir: ir} do
      todo = resource(ir, "Todo")

      filter_names = Enum.map(todo.filter_struct.fields, & &1.name)

      for name <- ["tags", "scores", "labels", "nilTags", "notes", "matrix"] do
        refute name in filter_names, "#{name} must not be filterable"
        refute name in todo.sort_field.fields, "#{name} must not be sortable"
      end
    end

    test "an array attribute still reaches the create input struct with its array type", %{ir: ir} do
      create = input_struct(ir, "CreateTodoInput")

      # allow_nil?: false but `default []`, so it is accepted yet not required —
      # the array-ness must not disturb the existing required? rule.
      assert %{swift_type: "[String]", required?: false} =
               Enum.find(create.fields, &(&1.name == "tags"))
    end
  end

  describe "generic-action array arguments" do
    test "an array-of-scalar argument maps to a [Scalar] input field", %{ir: ir} do
      struct = input_struct(ir, "BroadcastInput")

      assert %{name: "tags", swift_type: "[String]", required?: false} =
               Enum.find(struct.fields, &(&1.name == "tags"))
    end

    test "an array-of-record argument generates a typed nested input struct", %{ir: ir} do
      # The top-level input carries the array typed by the generated element struct.
      bulk_input = input_struct(ir, "BulkCreateInput")

      assert %{name: "rows", swift_type: "[BulkCreateRowsItem]", required?: true} =
               Enum.find(bulk_input.fields, &(&1.name == "rows"))

      # The element struct is emitted, its fields' optionality read from allow_nil?.
      item = input_struct(ir, "BulkCreateRowsItem")
      assert item, "expected a generated BulkCreateRowsItem struct"

      assert %{swift_type: "String", required?: true} =
               Enum.find(item.fields, &(&1.name == "label"))

      assert %{swift_type: "Int", required?: false} =
               Enum.find(item.fields, &(&1.name == "priority"))
    end
  end

  describe "generic-action map arguments" do
    test "a map-typed argument maps to the AshJSON dictionary", %{ir: ir} do
      struct = input_struct(ir, "EchoConfigInput")

      assert %{swift_type: "[String: AshJSON]", required?: false} =
               input_field(struct, "options")
    end

    test "an unconstrained array-of-map argument maps to [[String: AshJSON]]", %{ir: ir} do
      struct = input_struct(ir, "BulkRawInput")

      assert %{swift_type: "[[String: AshJSON]]"} = input_field(struct, "rows")
    end
  end

  describe "generic-action constrained-map return (#70)" do
    test "an unconstrained :map return still maps to the untyped [String: AshJSON]", %{ir: ir} do
      todo = resource(ir, "Todo")
      stats = Enum.find(todo.actions, &(&1.rpc_name == :stats))

      assert stats.generic_return == {:typed, "[String: AshJSON]"}
      # No struct is generated for an unconstrained map.
      refute Enum.any?(todo.input_structs, &(&1.struct_name == "StatsResult"))
    end

    test "a constrained :map return generates a typed Decodable result struct", %{ir: ir} do
      todo = resource(ir, "Todo")
      upload = Enum.find(todo.actions, &(&1.rpc_name == :upload_start))

      # The return is the generated struct, not [String: AshJSON]. Tagged
      # `:typed_record` (not `:typed`) so the emitter threads the required `fields:`
      # selection for this field-selectable return (issue #73).
      assert upload.generic_return == {:typed_record, "UploadStartResult"}

      result = input_struct(ir, "UploadStartResult")
      assert result, "expected a generated UploadStartResult struct"
      assert result.decodable?, "result struct must be tagged decodable? (renders Decodable)"

      # Required only when the map constraint set allow_nil?: false; nullable-default
      # scalar (caption) and the plain map (metadata) are Optional.
      assert %{swift_type: "String", required?: true} =
               Enum.find(result.fields, &(&1.name == "videoId"))

      assert %{swift_type: "String", required?: false} =
               Enum.find(result.fields, &(&1.name == "caption"))

      assert %{swift_type: "[String: AshJSON]", required?: false} =
               Enum.find(result.fields, &(&1.name == "metadata"))

      # The {:array, :map} field is typed by the generated element struct.
      assert %{swift_type: "[UploadStartResultClipsItem]", required?: false} =
               Enum.find(result.fields, &(&1.name == "clips"))
    end

    test "an {:array, :map} return field generates a typed, decodable nested struct", %{ir: ir} do
      # Named with the result-struct prefix so it never collides with an
      # argument-side `clips` nested struct on the same action.
      item = input_struct(ir, "UploadStartResultClipsItem")
      assert item, "expected a generated UploadStartResultClipsItem struct"
      assert item.decodable?, "nested result struct must be tagged decodable?"

      assert %{swift_type: "String", required?: true} =
               Enum.find(item.fields, &(&1.name == "clipId"))

      assert %{swift_type: "Int", required?: true} =
               Enum.find(item.fields, &(&1.name == "orderIndex"))

      assert %{swift_type: "String", required?: true} =
               Enum.find(item.fields, &(&1.name == "uploadUrl"))
    end
  end

  describe "aggregates (#51)" do
    test "public aggregates are typed from their resolved type", %{ir: ir} do
      user = resource(ir, "User")

      # count -> Int, exists -> Bool.
      assert attr_type(user, "todoCount") == "Int"
      assert attr_type(user, "hasTodos") == "Bool"
      # max/min/sum preserve the field's type; avg promotes :integer to :float -> Double.
      assert attr_type(user, "highestScore") == "Int"
      assert attr_type(user, "lowestScore") == "Int"
      assert attr_type(user, "totalScore") == "Int"
      assert attr_type(user, "averageScore") == "Double"
    end

    test "an aggregate whose resolved type is an enum is typed with a generated enum", %{ir: ir} do
      user = resource(ir, "User")

      assert attr_type(user, "topPriority") == "UserTopPriority"
      enum = Enum.find(user.enums, &(&1.enum_name == "UserTopPriority"))
      assert Enum.sort(Enum.map(enum.cases, & &1.name)) == ["high", "low", "medium"]
    end

    test "an aggregate that resolves to no scalar/enum (a list) is skipped", %{ir: ir} do
      user = resource(ir, "User")

      refute Enum.any?(user.fields, &(&1.name == "todoTitles"))
    end

    test "private aggregates are excluded", %{ir: ir} do
      user = resource(ir, "User")

      refute Enum.any?(user.fields, &(&1.name == "secretCount"))
    end
  end

  describe "calculations (#52)" do
    test "a zero-argument scalar calculation is a typed field", %{ir: ir} do
      user = resource(ir, "User")

      assert attr_type(user, "displayName") == "String"
    end

    test "a zero-argument calculation whose type is an enum is typed with a generated enum", %{
      ir: ir
    } do
      user = resource(ir, "User")

      assert attr_type(user, "nameSize") == "UserNameSize"
      enum = Enum.find(user.enums, &(&1.enum_name == "UserNameSize"))
      assert Enum.sort(Enum.map(enum.cases, & &1.name)) == ["long", "short"]
    end

    test "argument-bearing calculations (optional or required argument) are skipped", %{ir: ir} do
      user = resource(ir, "User")
      names = Enum.map(user.fields, & &1.name)

      refute "greeting" in names
      refute "nameMatches" in names
    end

    test "a calculation returning a non-scalar (map) type is skipped", %{ir: ir} do
      user = resource(ir, "User")

      refute Enum.any?(user.fields, &(&1.name == "nameSummary"))
    end

    test "private calculations are excluded", %{ir: ir} do
      user = resource(ir, "User")

      refute Enum.any?(user.fields, &(&1.name == "secretLabel"))
    end
  end

  describe "relationship fields" do
    test "belongs_to and has_many are typed with the related struct", %{ir: ir} do
      assert attr_type(resource(ir, "Todo"), "user") == "User"
      assert attr_type(resource(ir, "User"), "todos") == "[Todo]"
    end
  end

  describe "2-hop relationship guard" do
    setup do
      %{ir: Reader.read([AshSwift.Test.TagDomain])}
    end

    test "the 1-hop related resource is read; the 2-hop resource is not", %{ir: ir} do
      type_names = Enum.map(ir.all_resources, & &1.type_name)

      assert "Category" in type_names
      refute "Publisher" in type_names
      assert attr_type(resource(ir, "Tag"), "category") == "Category"
    end

    test "relationship fields referencing 2-hop types are dropped; scalar fields kept", %{ir: ir} do
      category = resource(ir, "Category")
      names = Enum.map(category.fields, & &1.name)

      refute "publisher" in names
      assert attr_type(category, "name") == "String"
      assert attr_type(category, "publisherId") == "String"
    end

    test "relationship fields record their destination module; other fields do not (#147)", %{
      ir: ir
    } do
      tag = resource(ir, "Tag")

      assert %{destination: AshSwift.Test.Category} =
               Enum.find(tag.fields, &(&1.name == "category"))

      category = resource(ir, "Category")

      assert %{destination: nil} = Enum.find(category.fields, &(&1.name == "name"))
    end

    test "a related struct keeps a relationship field whose destination is emitted", %{ir: ir} do
      category = resource(ir, "Category")

      assert attr_type(category, "tags") == "[Tag]"

      assert %{destination: AshSwift.Test.Tag} =
               Enum.find(category.fields, &(&1.name == "tags"))
    end

    test "an array-of-optional-elements field on a related struct is kept (#78)", %{ir: ir} do
      # The 2-hop guard filters only relationship fields (by their recorded
      # `destination:`); a non-relationship field like this one is kept
      # whatever the shape of its Swift type.
      assert attr_type(resource(ir, "Category"), "aliases") == "[String?]"
    end
  end

  describe "one generated Swift name, one owner (#156, #164)" do
    test "an enum named like a resource struct is a codegen error" do
      assert_raise Mix.Error,
                   ~r/not unique: "CollisionItemPriority" \(AshSwift\.Test\.CollisionItem enum, AshSwift\.Test\.CollisionItemPriority struct\).*rename/s,
                   fn -> Reader.read([AshSwift.Test.CollisionDomain]) end
    end

    test "a resource named like another's derived filter struct is a codegen error" do
      assert_raise Mix.Error,
                   ~r/not unique: "WidgetFilter" \(AshSwift\.Test\.Widget filter, AshSwift\.Test\.WidgetFilterResource struct\)/,
                   fn -> Reader.read([AshSwift.Test.FilterNameClashDomain]) end
    end

    test "an enum named like the resource's derived sort-field enum is a codegen error" do
      assert_raise Mix.Error,
                   ~r/not unique: "GadgetSortField" \(AshSwift\.Test\.Gadget enum, AshSwift\.Test\.Gadget sort field\)/,
                   fn -> Reader.read([AshSwift.Test.SortFieldEnumClashDomain]) end
    end

    test "a resource named like another's derived input struct is a codegen error" do
      assert_raise Mix.Error,
                   ~r/not unique: "CreateGizmoInput" \(AshSwift\.Test\.CreateGizmoInputResource struct, AshSwift\.Test\.Gizmo input struct\)/,
                   fn -> Reader.read([AshSwift.Test.InputStructClashDomain]) end
    end

    test "two declarations of one input struct name inside one resource are a codegen error" do
      assert_raise Mix.Error,
                   ~r/not unique: "UploadStartClipsItem" \(AshSwift\.Test\.Uploader input struct, AshSwift\.Test\.Uploader input struct\)/,
                   fn -> Reader.read([AshSwift.Test.SameResourceInputClashDomain]) end
    end

    test "a resource named like another's derived result struct is a codegen error" do
      assert_raise Mix.Error,
                   ~r/not unique: "BuildReportResult" \(AshSwift\.Test\.BuildReportResultResource struct, AshSwift\.Test\.ReportBuilder result struct\)/,
                   fn -> Reader.read([AshSwift.Test.ResultStructClashDomain]) end
    end

    test "a resource named like the generated client struct is a codegen error" do
      assert_raise Mix.Error,
                   ~r/not unique: "AshRpc" \(AshSwift generated client, AshSwift\.Test\.ClientNameResource struct\)/,
                   fn -> Reader.read([AshSwift.Test.ClientNameClashDomain]) end
    end

    test "a resource named like an AshSwiftRuntime public type is a codegen error" do
      assert_raise Mix.Error,
                   ~r/not unique: "AshRpcClient" \(AshSwift\.Test\.RuntimeNameResource struct, AshSwiftRuntime\)/,
                   fn -> Reader.read([AshSwift.Test.RuntimeNameClashDomain]) end
    end

    test "a resource named like a Foundation type the generated files use is a codegen error" do
      assert_raise Mix.Error,
                   ~r/not unique: "Date" \(AshSwift\.Test\.BuiltinNameResource struct, Swift\/Foundation\)/,
                   fn -> Reader.read([AshSwift.Test.BuiltinNameClashDomain]) end
    end

    test "the reserved runtime type names match the public types in Sources/AshSwiftRuntime" do
      declared =
        "Sources/AshSwiftRuntime/*.swift"
        |> Path.wildcard()
        |> Enum.flat_map(fn file ->
          ~r/^public (?:indirect |final )?(?:struct|enum|protocol|typealias|class|actor) (\w+)/m
          |> Regex.scan(File.read!(file), capture: :all_but_first)
          |> List.flatten()
        end)
        |> Enum.sort()

      assert declared != []
      assert Reader.reserved_runtime_type_names() == declared
    end

    test "a related destination sharing a primary's type name is a codegen error" do
      assert_raise Mix.Error,
                   ~r/not unique: "Clash" \(AshSwift\.Test\.ClashPrimary struct, AshSwift\.Test\.ClashRelated struct\)/,
                   fn -> Reader.read([AshSwift.Test.TypeNameClashPrimaryDomain]) end
    end

    test "two related destinations sharing a type name are a codegen error" do
      assert_raise Mix.Error,
                   ~r/not unique: "ClashDup" \(AshSwift\.Test\.ClashRelatedA struct, AshSwift\.Test\.ClashRelatedB struct\)/,
                   fn -> Reader.read([AshSwift.Test.TypeNameClashRelatedDomain]) end
    end

    test "an unexposed module reached by two relationships is emitted once, not an error" do
      ir = Reader.read([AshSwift.Test.SharedDestinationDomain])

      assert ir.all_resources |> Enum.map(& &1.type_name) |> Enum.sort() ==
               ["SharedHolder", "SharedTarget"]
    end
  end

  describe "create/update action arguments (#83)" do
    test "a create action's arguments become input fields alongside its accepted attributes", %{
      ir: ir
    } do
      struct = input_struct(ir, "CreateTodoWithArgsInput")

      # accepted attribute (required on create)
      assert %{swift_type: "String", required?: true} = input_field(struct, "title")
      # scalar argument, required (allow_nil?: false)
      assert %{swift_type: "String", required?: true} = input_field(struct, "note")
      # map argument -> same mapping as a generic-action map argument
      assert %{swift_type: "[String: AshJSON]", required?: false} = input_field(struct, "extras")

      # array-of-record argument -> nested typed struct
      assert %{swift_type: "[CreateTodoWithArgsChecklistItem]", required?: false} =
               input_field(struct, "checklist")
    end

    test "an array-of-record argument generates its nested struct", %{ir: ir} do
      item = input_struct(ir, "CreateTodoWithArgsChecklistItem")

      assert %{swift_type: "String", required?: true} = input_field(item, "label")
      assert %{swift_type: "Bool", required?: false} = input_field(item, "done")
    end

    test "an argument named like an attribute takes the argument's type", %{ir: ir} do
      # `score` is an integer attribute but a String argument on this action.
      assert %{swift_type: "String"} =
               input_field(input_struct(ir, "CreateTodoWithArgsInput"), "score")
    end

    test "an argument of an unmappable type is omitted from the input struct", %{ir: ir} do
      refute input_field(input_struct(ir, "CreateTodoWithArgsInput"), "grid")
    end

    test "an argument-only update (accept []) gets an input struct; a required argument stays required",
         %{ir: ir} do
      assert [%{name: "newTitle", swift_type: "String", required?: true}] =
               input_struct(ir, "RetitleTodoInput").fields
    end
  end

  describe "arguments named like a private attribute (#84)" do
    test "an update keeps an argument whose same-named attribute is private (#84)", %{ir: ir} do
      assert [%{name: "dueDate", swift_type: "String", required?: true}] =
               input_struct(ir, "SetTodoDueDateInput").fields
    end

    test "a generic action keeps an argument whose same-named attribute is private (#84)", %{
      ir: ir
    } do
      assert [%{name: "dueDate", swift_type: "String", required?: true}] =
               input_struct(ir, "CheckTodoDueDateInput").fields
    end

    test "the private attribute itself stays out of the resource fields", %{ir: ir} do
      todo = resource(ir, "Todo")

      refute Enum.any?(todo.fields, &(&1.name == "dueDate"))
    end
  end
end
