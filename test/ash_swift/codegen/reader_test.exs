defmodule AshSwift.Codegen.ReaderTest do
  @moduledoc """
  Tests the manifest Reader against the Codegen IR directly — the classification
  logic (enum detection, filter-operator-group selection, sort surface, generic-
  action gating) that was previously only observable through rendered-Swift
  substrings. Asserting on the IR as data is the test-surface win of the
  Reader/Emitter split (ADR-0010).
  """
  use ExUnit.Case, async: true

  alias AshSwift.Codegen.Reader

  @domains [AshSwift.Test.Domain]

  defp resource(ir, type_name), do: Enum.find(ir.all_resources, &(&1.type_name == type_name))

  defp attr_type(res, name), do: Enum.find(res.fields, &(&1.name == name)).swift_type

  defp input_struct(name) do
    todo = resource(Reader.read(@domains), "Todo")
    Enum.find(todo.input_structs, &(&1.struct_name == name))
  end

  defp input_field(struct, name), do: Enum.find(struct.fields, &(&1.name == name))

  describe "read/1 shape" do
    test "returns primary and all resource lists of plain maps" do
      ir = Reader.read(@domains)

      assert Enum.map(ir.primary_resources, & &1.type_name) == ["Todo", "User"]

      # all_resources folds in related resources, so it is a superset of primary.
      primary = MapSet.new(ir.primary_resources, & &1.type_name)
      all = MapSet.new(ir.all_resources, & &1.type_name)
      assert MapSet.subset?(primary, all)
    end
  end

  describe "action IR key sets (#95)" do
    @crud_keys ~w(rpc_name action action_type get
                  not_found_error? input_struct_name input_required? primary_key_params
                  pagination_type optional_pagination_type sortable? filterable?)a
               |> MapSet.new()

    @generic_keys ~w(rpc_name action action_type get
                     not_found_error? input_struct_name primary_key_params pagination_type
                     optional_pagination_type sortable? filterable? generic_return)a
                  |> MapSet.new()

    test "CRUD actions carry exactly the documented keys; generic actions their own set" do
      todo = resource(Reader.read(@domains), "Todo")

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
        assert MapSet.new(Map.keys(action)) == @crud_keys, "CRUD keys drifted for #{name}"
      end

      ping = Enum.find(todo.actions, &(&1.rpc_name == :ping))
      assert MapSet.new(Map.keys(ping)) == @generic_keys
    end
  end

  describe "destroy action inputs (#102)" do
    test "a destroy gets an input struct only when it declares inputs" do
      todo = resource(Reader.read(@domains), "Todo")
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

  describe "accepted-attribute input optionality (#113, #124)" do
    setup do
      todo = resource(Reader.read(@domains), "Todo")
      struct = fn name -> Enum.find(todo.input_structs, &(&1.struct_name == name)) end
      field = fn s, name -> Enum.find(s.fields, &(&1.name == name)) end
      %{struct: struct, field: field}
    end

    test "require_attributes makes accepted update/destroy attributes required (#113)", %{
      struct: struct,
      field: field
    } do
      rename = struct.("RenameTodoInput")
      assert %{required?: true} = field.(rename, "title")
      assert %{required?: false} = field.(rename, "priority")

      assert %{required?: true} = field.(struct.("RemoveTitledTodoInput"), "title")
    end

    test "allow_nil_input, nullable and defaulted attributes stay optional; a plain allow_nil?: false one is required (#124)",
         %{
           struct: struct,
           field: field
         } do
      input = struct.("CreateLenientTodoInput")

      # allow_nil?: false, but in allow_nil_input
      assert %{required?: false} = field.(input, "title")
      # nullable, in require_attributes: manifest says required, parity says optional
      assert %{required?: false} = field.(input, "score")
      # has a default, in require_attributes
      assert %{required?: false} = field.(input, "completed")

      # control: allow_nil?: false, no default, not in allow_nil_input
      assert %{required?: true} = field.(struct.("CreateTodoInput"), "title")
    end
  end

  describe "enum classification" do
    test "an attribute with a one_of / Ash.Type.Enum type becomes a typed enum in the IR" do
      todo = resource(Reader.read(@domains), "Todo")
      enum_names = Enum.map(todo.enums, & &1.enum_name)

      assert "TodoPriority" in enum_names
      assert "TodoStatus" in enum_names

      priority = Enum.find(todo.enums, &(&1.enum_name == "TodoPriority"))
      assert priority.cases == [:low, :medium, :high]
    end

    test "an Ash.Type.Enum attribute types its field with the generated enum" do
      todo = resource(Reader.read(@domains), "Todo")

      assert attr_type(todo, "status") == "TodoStatus"
      status = Enum.find(todo.enums, &(&1.enum_name == "TodoStatus"))
      assert Enum.sort(status.cases) == [:active, :archived, :case, :default, :pending]
    end
  end

  describe "scalar attribute type mapping" do
    test "each Ash scalar attribute resolves to its Swift wire type in the IR" do
      todo = resource(Reader.read(@domains), "Todo")

      # Decimal serialises as "123.45" on the wire; String is the faithful type.
      assert attr_type(todo, "amount") == "String"
      # ISO 8601 date-only.
      assert attr_type(todo, "deadline") == "String"
      assert attr_type(todo, "scheduledAt") == "Date"
      assert attr_type(todo, "dueAt") == "Date"
      # No timezone in the wire format, so no Date.
      assert attr_type(todo, "startedAt") == "String"
      assert attr_type(todo, "metadata") == "[String: AshJSON]"
      # CiString is explicitly mapped (no unmapped-type fallback).
      assert attr_type(todo, "username") == "String"
    end
  end

  describe "filter-operator-group selection" do
    test "each filterable attribute carries the operator generic for its type and nullability" do
      todo = resource(Reader.read(@domains), "Todo")
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
      # ci_string joins the equality+membership group like other strings
      assert groups["username"] == "NullableEnumOperators<String>"
    end

    test "date/datetime and decimal attributes are comparable, typed by their Swift type" do
      todo = resource(Reader.read(@domains), "Todo")
      groups = Map.new(todo.filter_struct.fields, &{&1.name, &1.swift_type})

      assert groups["dueAt"] == "NullableComparableOperators<Date>"
      # Decimal maps to a Swift String but the Ash type drives the comparable group.
      assert groups["amount"] == "NullableComparableOperators<String>"
    end

    test "every filterable resource gets a filter struct; composite maps are excluded" do
      ir = Reader.read(@domains)

      for type_name <- ["Todo", "User"] do
        refute is_nil(resource(ir, type_name).filter_struct), "#{type_name} must be filterable"
      end

      todo = resource(ir, "Todo")
      refute "metadata" in Enum.map(todo.filter_struct.fields, & &1.name)
    end
  end

  describe "sort surface" do
    test "a resource with sortable attributes gets a typed SortField enum in the IR" do
      todo = resource(Reader.read(@domains), "Todo")
      refute is_nil(todo.sort_field)

      assert todo.sort_field.type_name == "TodoSortField"
      assert "title" in todo.sort_field.fields
    end

    test "public comparable attributes are sortable; composite maps are not" do
      ir = Reader.read(@domains)
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
    test "a list read, a create and a generic action are not gets" do
      todo = resource(Reader.read(@domains), "Todo")

      for rpc_name <- [:list_todos, :create_todo, :ping] do
        action = Enum.find(todo.actions, &(&1.rpc_name == rpc_name))
        assert action, "fixture lost #{rpc_name}"
        assert action.get == nil
      end
    end

    test "a pure get? action has no lookup params (#91)" do
      todo = resource(Reader.read(@domains), "Todo")
      fetch = Enum.find(todo.actions, &(&1.rpc_name == :fetch_todo))

      assert fetch.get == :pure
    end

    test "a pure get? action with arguments keeps them as read input, no lookup (#91)" do
      todo = resource(Reader.read(@domains), "Todo")
      fetch = Enum.find(todo.actions, &(&1.rpc_name == :fetch_todo_by_title))

      assert fetch.get == :pure
      assert fetch.input_struct_name == "FetchTodoByTitleInput"

      input = Enum.find(todo.input_structs, &(&1.struct_name == "FetchTodoByTitleInput"))
      assert Enum.any?(input.fields, &(&1.name == "title"))
    end

    test "a native get_by action still travels via :input" do
      todo = resource(Reader.read(@domains), "Todo")
      get_todo = Enum.find(todo.actions, &(&1.rpc_name == :get_todo))

      assert {:input, [%{name: "id"}]} = get_todo.get
    end

    test "an RPC-level get_by action still travels via :get_by" do
      todo = resource(Reader.read(@domains), "Todo")
      find_by_title = Enum.find(todo.actions, &(&1.rpc_name == :find_todo_by_title))

      assert {:get_by, [%{name: "title"}]} = find_by_title.get
    end
  end

  describe "generic-action gating (#54)" do
    test "generic actions whose shape needs field selection are dropped; supported ones kept" do
      todo = resource(Reader.read(@domains), "Todo")
      rpc_names = Enum.map(todo.actions, & &1.rpc_name)

      # :summarize (a resource return) needs field selection the generic-action
      # slice doesn't emit yet (#56).
      refute :summarize in rpc_names

      # Void and scalar/map generic actions are supported and kept — including the
      # void branch of generic_action_return/1 (nil -> :void), exercised by :ping_void.
      assert :stats in rpc_names
      assert :ping in rpc_names
      assert :ping_void in rpc_names

      # Array arguments are now supported: a scalar array (:broadcast) and a record
      # array (:bulk_create) both generate.
      assert :broadcast in rpc_names
      assert :bulk_create in rpc_names

      # A nested-array argument ({:array, {:array, _}}) has an unmappable element, so
      # the whole action is skipped rather than emitted with a wrong-typed input.
      refute :deep_broadcast in rpc_names
    end
  end

  describe "array attributes (#78)" do
    test "an array attribute maps to the Swift array of its element type" do
      todo = resource(Reader.read(@domains), "Todo")

      # The regression this guards: `{:array, :string}` used to read `type.module`
      # (nil for an array) and fall through to the String catch-all, emitting a
      # scalar `String?` the device then failed to decode.
      assert attr_type(todo, "tags") == "[String]"

      # Element mapping is the shared scalar table, not a String special case.
      assert attr_type(todo, "scores") == "[Int]"
      assert attr_type(todo, "notes") == "[[String: AshJSON]]"
    end

    test "an array of an enum element maps to the generated Swift enum and emits it" do
      todo = resource(Reader.read(@domains), "Todo")

      assert attr_type(todo, "labels") == "[TodoLabels]"

      labels = Enum.find(todo.enums, &(&1.enum_name == "TodoLabels"))
      assert labels.cases == [:red, :green]
    end

    test "element nullability comes from nil_items?, not the attribute's allow_nil?" do
      todo = resource(Reader.read(@domains), "Todo")

      # `tags` is allow_nil?: false and `scores` allow_nil?: true, yet neither
      # permits nil *elements* — only `nil_tags` sets `nil_items?: true`. The array's
      # own optionality is applied by the emitter (every model field is Optional), so
      # the two nullabilities stay independent.
      assert attr_type(todo, "nilTags") == "[String?]"
      refute attr_type(todo, "tags") =~ "?"
      refute attr_type(todo, "scores") =~ "?"
    end

    test "an array whose element maps to no Swift type is omitted, not mis-typed" do
      todo = resource(Reader.read(@domains), "Todo")

      # `matrix` is {:array, {:array, :string}}: the element is itself an array, which
      # maps to no Swift type. Omitting it makes a consumer's use site a compile
      # error; emitting a guessed `String` would compile and fail at decode instead.
      refute Enum.any?(todo.fields, &(&1.name == "matrix"))

      refute Enum.any?(todo.input_structs, fn s -> Enum.any?(s.fields, &(&1.name == "matrix")) end)
    end

    test "array attributes are excluded from the filter and sort surfaces" do
      todo = resource(Reader.read(@domains), "Todo")

      filter_names = Enum.map(todo.filter_struct.fields, & &1.name)

      for name <- ["tags", "scores", "labels", "nilTags", "notes", "matrix"] do
        refute name in filter_names, "#{name} must not be filterable"
        refute name in todo.sort_field.fields, "#{name} must not be sortable"
      end
    end

    test "an array attribute still reaches the create input struct with its array type" do
      todo = resource(Reader.read(@domains), "Todo")
      create = Enum.find(todo.input_structs, &(&1.struct_name == "CreateTodoInput"))

      # allow_nil?: false but `default []`, so it is accepted yet not required —
      # the array-ness must not disturb the existing required? rule.
      assert %{swift_type: "[String]", required?: false} =
               Enum.find(create.fields, &(&1.name == "tags"))
    end
  end

  describe "generic-action array arguments" do
    test "an array-of-scalar argument maps to a [Scalar] input field" do
      todo = resource(Reader.read(@domains), "Todo")
      struct = Enum.find(todo.input_structs, &(&1.struct_name == "BroadcastInput"))

      assert %{name: "tags", swift_type: "[String]", required?: false} =
               Enum.find(struct.fields, &(&1.name == "tags"))
    end

    test "an array-of-record argument generates a typed nested input struct" do
      todo = resource(Reader.read(@domains), "Todo")

      # The top-level input carries the array typed by the generated element struct.
      bulk_input = Enum.find(todo.input_structs, &(&1.struct_name == "BulkCreateInput"))

      assert %{name: "rows", swift_type: "[BulkCreateRowsItem]", required?: true} =
               Enum.find(bulk_input.fields, &(&1.name == "rows"))

      # The element struct is emitted, its fields' optionality read from allow_nil?.
      item = Enum.find(todo.input_structs, &(&1.struct_name == "BulkCreateRowsItem"))
      assert item, "expected a generated BulkCreateRowsItem struct"

      assert %{swift_type: "String", required?: true} =
               Enum.find(item.fields, &(&1.name == "label"))

      assert %{swift_type: "Int", required?: false} =
               Enum.find(item.fields, &(&1.name == "priority"))
    end
  end

  describe "generic-action map arguments" do
    test "a map-typed argument maps to the AshJSON dictionary" do
      struct = input_struct("EchoConfigInput")

      assert %{swift_type: "[String: AshJSON]", required?: false} =
               input_field(struct, "options")
    end

    test "an unconstrained array-of-map argument maps to [[String: AshJSON]]" do
      todo = resource(Reader.read(@domains), "Todo")
      struct = Enum.find(todo.input_structs, &(&1.struct_name == "BulkRawInput"))

      assert %{swift_type: "[[String: AshJSON]]"} = Enum.find(struct.fields, &(&1.name == "rows"))
    end
  end

  describe "generic-action constrained-map return (#70)" do
    test "an unconstrained :map return still maps to the untyped [String: AshJSON]" do
      todo = resource(Reader.read(@domains), "Todo")
      stats = Enum.find(todo.actions, &(&1.rpc_name == :stats))

      assert stats.generic_return == {:typed, "[String: AshJSON]"}
      # No struct is generated for an unconstrained map.
      refute Enum.any?(todo.input_structs, &(&1.struct_name == "StatsResult"))
    end

    test "a constrained :map return generates a typed Decodable result struct" do
      todo = resource(Reader.read(@domains), "Todo")
      upload = Enum.find(todo.actions, &(&1.rpc_name == :upload_start))

      # The return is the generated struct, not [String: AshJSON]. Tagged
      # `:typed_record` (not `:typed`) so the emitter threads the required `fields:`
      # selection for this field-selectable return (issue #73).
      assert upload.generic_return == {:typed_record, "UploadStartResult"}

      result = Enum.find(todo.input_structs, &(&1.struct_name == "UploadStartResult"))
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

    test "an {:array, :map} return field generates a typed, decodable nested struct" do
      todo = resource(Reader.read(@domains), "Todo")

      # Named with the result-struct prefix so it never collides with an
      # argument-side `clips` nested struct on the same action.
      item = Enum.find(todo.input_structs, &(&1.struct_name == "UploadStartResultClipsItem"))
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
    test "public aggregates are typed from their resolved type" do
      user = resource(Reader.read(@domains), "User")

      # count -> Int, exists -> Bool.
      assert attr_type(user, "todoCount") == "Int"
      assert attr_type(user, "hasTodos") == "Bool"
      # max/min/sum preserve the field's type; avg promotes :integer to :float -> Double.
      assert attr_type(user, "highestScore") == "Int"
      assert attr_type(user, "lowestScore") == "Int"
      assert attr_type(user, "totalScore") == "Int"
      assert attr_type(user, "averageScore") == "Double"
    end

    test "an aggregate whose resolved type is an enum is typed with a generated enum" do
      user = resource(Reader.read(@domains), "User")

      assert attr_type(user, "topPriority") == "UserTopPriority"
      enum = Enum.find(user.enums, &(&1.enum_name == "UserTopPriority"))
      assert Enum.sort(enum.cases) == [:high, :low, :medium]
    end

    test "an aggregate that resolves to no scalar/enum (a list) is skipped" do
      user = resource(Reader.read(@domains), "User")

      refute Enum.any?(user.fields, &(&1.name == "todoTitles"))
    end

    test "private aggregates are excluded" do
      user = resource(Reader.read(@domains), "User")

      refute Enum.any?(user.fields, &(&1.name == "secretCount"))
    end
  end

  describe "calculations (#52)" do
    test "a zero-argument scalar calculation is a typed field" do
      user = resource(Reader.read(@domains), "User")

      assert attr_type(user, "displayName") == "String"
    end

    test "a zero-argument calculation whose type is an enum is typed with a generated enum" do
      user = resource(Reader.read(@domains), "User")

      assert attr_type(user, "nameSize") == "UserNameSize"
      enum = Enum.find(user.enums, &(&1.enum_name == "UserNameSize"))
      assert Enum.sort(enum.cases) == [:long, :short]
    end

    test "argument-bearing calculations (optional or required argument) are skipped" do
      user = resource(Reader.read(@domains), "User")
      names = Enum.map(user.fields, & &1.name)

      refute "greeting" in names
      refute "nameMatches" in names
    end

    test "a calculation returning a non-scalar (map) type is skipped" do
      user = resource(Reader.read(@domains), "User")

      refute Enum.any?(user.fields, &(&1.name == "nameSummary"))
    end

    test "private calculations are excluded" do
      user = resource(Reader.read(@domains), "User")

      refute Enum.any?(user.fields, &(&1.name == "secretLabel"))
    end
  end

  describe "relationship fields" do
    test "belongs_to and has_many are typed with the related struct" do
      ir = Reader.read(@domains)

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

    test "an array-of-optional-elements field on a related struct is kept (#78)", %{ir: ir} do
      # The safety check strips one bracket layer to reach the element type; unless
      # it also drops the element's own `?`, `[String?]` resolves to the unknown
      # "String?" and the field disappears.
      assert attr_type(resource(ir, "Category"), "aliases") == "[String?]"
    end
  end

  describe "create/update action arguments (#83)" do
    test "a create action's arguments become input fields alongside its accepted attributes" do
      struct = input_struct("CreateTodoWithArgsInput")

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

    test "an array-of-record argument generates its nested struct" do
      item = input_struct("CreateTodoWithArgsChecklistItem")

      assert %{swift_type: "String", required?: true} = input_field(item, "label")
      assert %{swift_type: "Bool", required?: false} = input_field(item, "done")
    end

    test "an argument named like an attribute takes the argument's type" do
      # `score` is an integer attribute but a String argument on this action.
      assert %{swift_type: "String"} =
               input_field(input_struct("CreateTodoWithArgsInput"), "score")
    end

    test "an argument of an unmappable type is omitted from the input struct" do
      refute input_field(input_struct("CreateTodoWithArgsInput"), "grid")
    end

    test "an argument-only update (accept []) gets an input struct; a required argument stays required" do
      assert [%{name: "newTitle", swift_type: "String", required?: true}] =
               input_struct("RetitleTodoInput").fields
    end
  end

  describe "arguments named like a private attribute (#84)" do
    test "an update keeps an argument whose same-named attribute is private (#84)" do
      assert [%{name: "dueDate", swift_type: "String", required?: true}] =
               input_struct("SetTodoDueDateInput").fields
    end

    test "a generic action keeps an argument whose same-named attribute is private (#84)" do
      assert [%{name: "dueDate", swift_type: "String", required?: true}] =
               input_struct("CheckTodoDueDateInput").fields
    end

    test "the private attribute itself stays out of the resource fields" do
      todo = resource(Reader.read(@domains), "Todo")

      refute Enum.any?(todo.fields, &(&1.name == "dueDate"))
    end
  end
end
