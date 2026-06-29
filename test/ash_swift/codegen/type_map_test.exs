defmodule AshSwift.Codegen.TypeMapTest do
  @moduledoc """
  Direct table tests for the Ash-type → Swift mapping. Before the TypeMap
  extraction these mappings were only observable through rendered Swift
  substrings in codegen_test; here they are asserted as the flat tables they are.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshSwift.Codegen.TypeMap

  describe "ash_type_to_swift/1" do
    test "maps each known Ash scalar to its Swift counterpart" do
      assert TypeMap.ash_type_to_swift(Ash.Type.UUID) == "String"
      assert TypeMap.ash_type_to_swift(Ash.Type.String) == "String"
      assert TypeMap.ash_type_to_swift(Ash.Type.CiString) == "String"
      assert TypeMap.ash_type_to_swift(Ash.Type.Boolean) == "Bool"
      assert TypeMap.ash_type_to_swift(Ash.Type.Integer) == "Int"
      assert TypeMap.ash_type_to_swift(Ash.Type.Float) == "Double"
      assert TypeMap.ash_type_to_swift(Ash.Type.Decimal) == "String"
      assert TypeMap.ash_type_to_swift(Ash.Type.Date) == "String"
      assert TypeMap.ash_type_to_swift(Ash.Type.UtcDatetime) == "Date"
      assert TypeMap.ash_type_to_swift(Ash.Type.UtcDatetimeUsec) == "Date"
      assert TypeMap.ash_type_to_swift(Ash.Type.NaiveDatetime) == "String"
      assert TypeMap.ash_type_to_swift(Ash.Type.Map) == "[String: AshJSON]"
      assert TypeMap.ash_type_to_swift(Ash.Type.Atom) == "String"
    end

    test "an unmapped type falls back to String and warns" do
      log =
        capture_log(fn ->
          assert TypeMap.ash_type_to_swift(Ash.Type.Term) == "String"
        end)

      assert log =~ "no Swift type mapping for Ash type"
    end
  end

  describe "generic_swift_type/1" do
    test "a map kind maps to the AshJSON dictionary" do
      assert TypeMap.generic_swift_type(%{kind: :map}) == {:ok, "[String: AshJSON]"}
    end

    test "a scalar kind with a concrete module maps through ash_type_to_swift" do
      assert TypeMap.generic_swift_type(%{kind: :integer, module: Ash.Type.Integer}) ==
               {:ok, "Int"}
    end

    test "a scalar kind with a nil module is unsupported (refuses to String-guess)" do
      assert TypeMap.generic_swift_type(%{kind: :integer, module: nil}) == :unsupported
    end

    test "a non-scalar kind (array/enum/struct) is unsupported" do
      assert TypeMap.generic_swift_type(%{kind: :array, module: nil}) == :unsupported
      assert TypeMap.generic_swift_type(%{kind: :enum, module: Some.Enum}) == :unsupported
    end
  end

  describe "scalar_filter_group/1" do
    test "numeric and date/datetime types are comparable" do
      for type <- [
            Ash.Type.Integer,
            Ash.Type.Float,
            Ash.Type.Decimal,
            Ash.Type.Date,
            Ash.Type.UtcDatetime,
            Ash.Type.UtcDatetimeUsec,
            Ash.Type.NaiveDatetime
          ] do
        assert TypeMap.scalar_filter_group(type) == :comparable
      end
    end

    test "boolean is equatable, map is excluded, everything else defaults to enum" do
      assert TypeMap.scalar_filter_group(Ash.Type.Boolean) == :equatable
      assert TypeMap.scalar_filter_group(Ash.Type.Map) == :exclude
      assert TypeMap.scalar_filter_group(Ash.Type.String) == :enum
      assert TypeMap.scalar_filter_group(Ash.Type.UUID) == :enum
      assert TypeMap.scalar_filter_group(Ash.Type.Atom) == :enum
    end
  end

  describe "operator_generic_name/2" do
    test "maps (group, nullable?) to the runtime operator generic" do
      assert TypeMap.operator_generic_name(:equatable, false) == "EquatableOperators"
      assert TypeMap.operator_generic_name(:equatable, true) == "NullableEquatableOperators"
      assert TypeMap.operator_generic_name(:enum, false) == "EnumOperators"
      assert TypeMap.operator_generic_name(:enum, true) == "NullableEnumOperators"
      assert TypeMap.operator_generic_name(:comparable, false) == "ComparableOperators"
      assert TypeMap.operator_generic_name(:comparable, true) == "NullableComparableOperators"
    end
  end

  describe "extract_enum_cases/1" do
    test "a precomputed value list is an enum" do
      assert TypeMap.extract_enum_cases(%{enum_values: [:low, :high]}) == {:ok, [:low, :high]}
    end

    test "a nil value list is not an enum" do
      assert TypeMap.extract_enum_cases(%{enum_values: nil}) == :not_enum
    end
  end

  describe "derived_scalar_kinds/0" do
    test "exposes the scalar kinds the reader gates derived fields on" do
      kinds = TypeMap.derived_scalar_kinds()
      assert :integer in kinds
      assert :utc_datetime in kinds
      # Composite/array/enum kinds are deliberately absent — derived fields of
      # those shapes are dropped rather than mis-typed.
      refute :array in kinds
      refute :map in kinds
      refute :enum in kinds
    end
  end
end
