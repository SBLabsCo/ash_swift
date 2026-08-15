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

  describe "enum classification" do
    test "an attribute with a one_of / Ash.Type.Enum type becomes a typed enum in the IR" do
      todo = resource(Reader.read(@domains), "Todo")
      enum_names = Enum.map(todo.enums, & &1.enum_name)

      assert "TodoPriority" in enum_names
      assert "TodoStatus" in enum_names

      priority = Enum.find(todo.enums, &(&1.enum_name == "TodoPriority"))
      assert priority.cases == [:low, :medium, :high]
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
    end
  end

  describe "sort surface" do
    test "a resource with sortable attributes gets a typed SortField enum in the IR" do
      todo = resource(Reader.read(@domains), "Todo")
      refute is_nil(todo.sort_field)

      assert todo.sort_field.type_name == "TodoSortField"
      assert "title" in todo.sort_field.fields
    end
  end

  describe "get? lookup location (#66)" do
    test "a pure get? action looks the record up by primary key via :identity" do
      todo = resource(Reader.read(@domains), "Todo")
      fetch = Enum.find(todo.actions, &(&1.rpc_name == :fetch_todo))

      assert fetch.get_by_location == :identity
      assert Enum.map(fetch.get_by_params, & &1.name) == ["id"]
    end

    test "a native get_by action still travels via :input, not :identity" do
      todo = resource(Reader.read(@domains), "Todo")
      get_todo = Enum.find(todo.actions, &(&1.rpc_name == :get_todo))

      assert get_todo.get_by_location == :input
    end

    test "an RPC-level get_by action still travels via :get_by" do
      todo = resource(Reader.read(@domains), "Todo")
      find_by_title = Enum.find(todo.actions, &(&1.rpc_name == :find_todo_by_title))

      assert find_by_title.get_by_location == :get_by
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
end
