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

  describe "generic-action gating (#54)" do
    test "generic actions whose shape needs field selection are dropped; supported ones kept" do
      todo = resource(Reader.read(@domains), "Todo")
      rpc_names = Enum.map(todo.actions, & &1.rpc_name)

      # :broadcast (a record-typed argument) and :summarize (a resource return)
      # need field selection that the generic-action slice doesn't emit yet (#56).
      refute :broadcast in rpc_names
      refute :summarize in rpc_names

      # Void and scalar/map generic actions are supported and kept — including the
      # void branch of generic_action_return/1 (nil -> :void), exercised by :ping_void.
      assert :stats in rpc_names
      assert :ping in rpc_names
      assert :ping_void in rpc_names
    end
  end
end
