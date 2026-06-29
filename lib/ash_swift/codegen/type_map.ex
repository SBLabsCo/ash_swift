defmodule AshSwift.Codegen.TypeMap do
  @moduledoc """
  The Ash-type → Swift mapping for codegen: the single place that answers
  "what is this Ash type in Swift?" — the scalar/map Swift type, the filter
  operator group for an attribute, and enum-case classification.

  Reader-side only: the emitters consume the `swift_type` strings this produces,
  they never call back into it. Kept as a focused module so the type table is
  directly unit-testable (`ash_type_to_swift(Ash.Type.UUID) == "String"`) rather
  than only observable through rendered Swift.
  """

  require Logger

  # Maps an Ash attribute type to its Swift counterpart. Enum attributes are
  # handled before this is called (via extract_enum_cases/1); this covers the
  # remaining scalar types and falls back to String for unknown types.
  #
  # Wire-format notes (confirmed from Jason.encode!/1 behaviour):
  #   Decimal        → JSON string "123.45" — Swift String preserves precision
  #   Date           → JSON string "2024-01-15" (date-only, no time component)
  #   UtcDatetime    → JSON string "2024-01-15T10:30:00Z" (ISO 8601 UTC)
  #   UtcDatetimeUsec → JSON string "2024-01-15T10:30:00.123456Z" (with μs)
  #   NaiveDatetime  → JSON string "2024-01-15T10:30:00" (no timezone)
  #   Map            → JSON object {…} — AshJSON handles any JSON value shape
  def ash_type_to_swift(Ash.Type.UUID), do: "String"
  def ash_type_to_swift(Ash.Type.String), do: "String"
  # CiString is a case-insensitive string; the wire value is a plain JSON string.
  def ash_type_to_swift(Ash.Type.CiString), do: "String"
  def ash_type_to_swift(Ash.Type.Boolean), do: "Bool"
  def ash_type_to_swift(Ash.Type.Integer), do: "Int"
  def ash_type_to_swift(Ash.Type.Float), do: "Double"
  # Decimal arrives as a JSON string ("123.45") — String is the faithful Swift
  # type that preserves arbitrary precision without a custom decoder.
  def ash_type_to_swift(Ash.Type.Decimal), do: "String"
  # Date-only ("2024-01-15"): Swift has no date-only type; String is correct.
  def ash_type_to_swift(Ash.Type.Date), do: "String"
  # UTC datetimes arrive as ISO 8601 strings with "Z" suffix. AshRpcClient
  # configures its JSONDecoder with a custom date strategy to decode them into
  # Foundation Date values (see AshRpcClient.swift).
  def ash_type_to_swift(Ash.Type.UtcDatetime), do: "Date"
  def ash_type_to_swift(Ash.Type.UtcDatetimeUsec), do: "Date"
  # NaiveDatetime has no timezone info ("2024-01-15T10:30:00"); String avoids
  # the ambiguity of interpreting it in a caller-supplied timezone.
  def ash_type_to_swift(Ash.Type.NaiveDatetime), do: "String"
  # Map arrives as an arbitrary JSON object. AshJSON (from AshSwiftRuntime)
  # handles any JSON value shape with a typed recursive enum.
  def ash_type_to_swift(Ash.Type.Map), do: "[String: AshJSON]"
  # Atom without one_of constraints falls back to String. Atoms WITH one_of are
  # caught by extract_enum_cases/1 before reaching this function and become typed
  # Swift enums. A full atom-to-enum mapping is tracked in issue #24 (M2 plan).
  def ash_type_to_swift(Ash.Type.Atom), do: "String"
  # Catch-all: emit a warning so unmapped types are visible rather than silently
  # stringified. Open an issue to add the explicit mapping if you hit this.
  def ash_type_to_swift(type) do
    Logger.warning(
      "AshSwift: no Swift type mapping for Ash type #{inspect(type)}; " <>
        "falling back to String. Open an issue to add an explicit mapping."
    )

    "String"
  end

  # The manifest field `kind`s whose value maps to a scalar Swift type (and so a
  # derived field — aggregate/calculation — or a generic action's scalar return
  # can be emitted with a concrete Swift type rather than dropped). A type whose
  # kind is absent here — array/tuple/union/struct/enum/resource — is dropped
  # rather than String-fallbacked: a derived field's type is computed, not
  # author-controlled, so a wrong guess silently mis-decodes whereas omission is
  # safe. Enum-typed derived fields are handled before this gate (via
  # manifest_enum_values), so :enum/:type_ref are intentionally absent here.
  @derived_scalar_kinds ~w(string ci_string atom uuid integer float decimal
                           boolean date utc_datetime utc_datetime_usec
                           naive_datetime)a

  @doc """
  The manifest field kinds that map to a scalar Swift type. Exposed for the
  reader's runtime membership checks; `generic_swift_type/1` guards on the
  module attribute directly.
  """
  def derived_scalar_kinds, do: @derived_scalar_kinds

  # The Swift type for a generic action's argument or scalar/map return — the
  # shared classifier behind both generic_action_return/1 and the input collector.
  # These types are *computed* (a return) or carry no module (a list/array argument
  # is `kind: :array, module: nil`), so — exactly like emit_derived_fields — this
  # gates on kind/module and refuses to String-guess: a map maps to AshJSON, a
  # mapped scalar to its Swift type, and anything else (array/tuple/union/struct/
  # enum/resource) is :unsupported. `ash_type_to_swift` would silently return
  # "String" for a nil module, which is the mis-type this gate exists to prevent.
  def generic_swift_type(%{kind: :map}), do: {:ok, "[String: AshJSON]"}

  def generic_swift_type(%{kind: kind, module: module})
      when kind in @derived_scalar_kinds and not is_nil(module),
      do: {:ok, ash_type_to_swift(module)}

  def generic_swift_type(_), do: :unsupported

  # Returns {:ok, cases} when the normalised attribute is an enum, :not_enum
  # otherwise. Enum-ness (inline Ash.Type.Atom one_of, or a named Ash.Type.Enum
  # subtype) is precomputed from the manifest field type in manifest_attributes/2.
  def extract_enum_cases(%{enum_values: values}) when is_list(values), do: {:ok, values}
  def extract_enum_cases(%{enum_values: nil}), do: :not_enum

  # The operator group an attribute's filter predicate exposes, keyed on the Ash
  # type. Comparable types (numbers, dates) get the ordered operator set; Boolean
  # is equality-only; Map is excluded from filtering entirely; everything else
  # (String, CiString, UUID, Atom, …) falls to the equality+membership group.
  #
  # NOTE: this is keyed on the Ash type, deliberately distinct from sorting's
  # `@sortable_swift_types` (keyed on the mapped Swift type, in AshSwift.Codegen) —
  # they answer different questions. When you add a new scalar to
  # `ash_type_to_swift/1`, decide its operator group HERE as well, or it falls
  # through to the :enum default.
  def scalar_filter_group(type)
      when type in [
             Ash.Type.Integer,
             Ash.Type.Float,
             Ash.Type.Decimal,
             Ash.Type.Date,
             Ash.Type.UtcDatetime,
             Ash.Type.UtcDatetimeUsec,
             Ash.Type.NaiveDatetime
           ],
      do: :comparable

  def scalar_filter_group(Ash.Type.Boolean), do: :equatable
  def scalar_filter_group(Ash.Type.Map), do: :exclude
  # String, CiString, UUID, unconstrained Atom, and any unmapped scalar fall to
  # the equality+membership group — matching AshTypescript's `default` filter
  # classification (eq/notEq/in over the mapped Swift type, which is String).
  def scalar_filter_group(_type), do: :enum

  # Maps an (operator group, nullable?) pair to its AshSwiftRuntime generic. The
  # Nullable* variants add the `isNil` operator; the bare variants omit it, so a
  # non-null attribute exposes exactly its type-driven operator set and nothing more.
  def operator_generic_name(:equatable, false), do: "EquatableOperators"
  def operator_generic_name(:equatable, true), do: "NullableEquatableOperators"
  def operator_generic_name(:enum, false), do: "EnumOperators"
  def operator_generic_name(:enum, true), do: "NullableEnumOperators"
  def operator_generic_name(:comparable, false), do: "ComparableOperators"
  def operator_generic_name(:comparable, true), do: "NullableComparableOperators"

  # `:exclude` (e.g. Ash.Type.Map) must never reach here — excluded attributes are
  # dropped before an operator is built (see filter_field/4, which returns nil for
  # the :exclude group). Guard the contract explicitly: as a public function this
  # gives a future caller an actionable error instead of a bare FunctionClauseError.
  def operator_generic_name(:exclude, _nullable?) do
    raise ArgumentError,
          "operator_generic_name/2 received :exclude — excluded attributes carry no " <>
            "filter operator and must be dropped upstream before an operator is built"
  end
end
