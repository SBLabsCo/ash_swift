defmodule AshSwift.Codegen.Contract do
  @moduledoc """
  Exports the codegen IR (`AshSwift.Codegen.Reader`) as a stable, JSON-encodable
  RPC contract document — the intermediate model the emitter renders into Swift,
  described independently of Swift syntax (issue #85).

  The intended consumer is a downstream CI gate: fetch the contract JSON at the
  last shipped client release and at the current PR head, then diff them to
  classify each change as additive (new optional field/action/enum value) or
  breaking (removed action/field/enum value, changed type, new required input).
  Diffing this document is far more robust than diffing the emitted Swift text,
  which churns on formatting and naming details that carry no contract meaning.

  ## Shape

      %{
        contract_version: 1,
        ash_swift_version: "0.1.0",
        actions: [%{name, domain, resource, action, action_type, sortable,
                     filterable, inputs, result_type, optional_pagination}],
        types: [%{name, kind, fields: [%{name, type, optional}]}],
        enums: [%{name, values}]
      }

  `actions` covers every action the reader models on every primary (RPC-exposed)
  resource — a generic action whose return or argument shape the reader can't
  map to Swift is skipped with a `Logger.warning` (`Reader`'s `warn_skip_generic/2`)
  rather than surfaced as an unsupported entry here, so it is simply absent
  from `actions` rather than present with an empty/placeholder shape.
  `sortable`/`filterable` mirror the action's `enable_sort?`/
  `enable_filter?` (and, for `sortable`, whether the resource has any sortable
  attribute at all — see `AshSwift.Codegen.Reader`'s `has_sortable_fields?`):
  either can flip a `sort:`/`filter:` parameter into or out of existence without
  touching `result_type`, so they are recorded as their own fields rather than
  left to be inferred from `types`/`enums` membership. `optional_pagination` is
  `nil` for every action except a list read that *supports* offset/keyset
  pagination without *requiring* it — there it is
  `%{type: "offset" | "keyset", result_type: "OffsetPage<T>" | "KeysetPage<T>"}`,
  describing the second, overloaded function `Emitter.method_specs/2` emits
  alongside the bare-array one (ADR-0007's optional-pagination addendum). A
  single action name can therefore describe **two** callable overloads; count
  `1 + (optional_pagination != nil && 1)` per action when comparing the
  contract's function count against the emitted Swift (see
  `AshSwift.Codegen.ContractTest`'s golden cross-check).

  `types` covers every struct the emitter writes to the types file: a
  resource's own model struct (`kind: "resource"`) plus every generated input
  struct (`kind: "input"`, Encodable), result struct (`kind: "result"`,
  Decodable) — including related-resource structs pulled in one hop out and
  nested per-field structs (e.g. an array-of-record argument's element) — and
  every generated `{Resource}Filter` (`kind: "filter"`, Encodable), fields
  listed alongside the `and`/`or`/`not` logical-combinator properties every
  filter carries. `enums` covers every generated Swift enum: resource-attribute
  or derived-field enums alongside every generated `{Resource}SortField`
  (its `values` are the sortable attribute names, exactly the enum's cases) —
  both render as a plain `public enum ...: String` declaration in the emitted
  Swift, so both belong in one list. A resource with no filterable (or
  sortable) action surface has no `Filter` (`SortField`) at all, matching the
  emitter, which never emits either as dead code — flipping `enable_filter?`/
  `enable_sort?` (or the last filterable/sortable attribute disappearing) is a
  visible diff here, not a silent one.

  The reader does not yet give union or embedded-resource values a distinct
  shape of their own — an attribute of either kind currently either resolves to
  a plain scalar field (module-bearing types keep the String fallback) or is
  dropped as unsupported, so there is nothing beyond `types`/`enums` to surface
  for them today. Once the reader gains a first-class union/embedded model,
  extend this document rather than diffing Swift text for that instead.

  Some fields carry deliberately different consumption rules: `ash_swift_version`
  is metadata (which AshSwift build produced the document, the same role a Hex
  package manifest's own version plays) and is excluded from additive/breaking
  classification — it changes on every release regardless of contract content,
  so diffing it would flag noise as a change. Likewise `domain` and
  `resource_module` on each action entry are provenance, not contract — pure
  breadcrumbs back to the Elixir module that produced the action, never
  reaching the emitted Swift (the client never sees a domain or resource
  module name); a server-side module rename changes them without changing the
  generated function signature at all, so they too are excluded from
  additive/breaking classification, on pain of a name-keyed structural diff
  flagging a harmless rename as breaking. `contract_version` is the
  document *shape*'s own version (this module's `@contract_version`); a
  consumer should assert it for **equality** before diffing anything else — a
  mismatch means the shape itself may have grown/renamed top-level keys, which
  a structural diff over the old shape would not safely interpret.

  What the contract does **not** see: a change that is wire-only rather than
  binary-shaped — e.g. `get_by_location` flipping which of `:identity`,
  `:input`, or `:get_by` the client should use to send a lookup key — has no
  representation here (or in the emitted Swift's compiled shape) because the
  generated function signature is unchanged either way. A gate built on this
  document, like a gate built on the emitted Swift, cannot see that class of
  change; it needs its own coverage (e.g. `AshSwift.Codegen.ReaderTest`).

  Every list is sorted by name and the JSON encoding uses alphabetically sorted
  object keys throughout (`to_ordered/1`), so two runs over the same domains
  produce byte-identical output — this is asserted directly, not merely
  implied by the reader's own sorting (see `AshSwift.Codegen.ContractTest`).
  """

  alias AshSwift.Codegen.{Emitter, Reader}

  @contract_version 1

  @doc """
  Builds the RPC contract document for `domains` as a plain Elixir map (atom
  keys, values are strings/numbers/lists/maps — already JSON-encodable). Every
  list is sorted by name.
  """
  @spec build([module()]) :: map()
  def build(domains) when is_list(domains) do
    domains |> Reader.read() |> build_from_ir()
  end

  @doc """
  Builds the contract document directly from a codegen IR map (the shape
  `AshSwift.Codegen.Reader.read/1` returns: `%{primary_resources, all_resources}`
  of plain resource/action/field maps — see its moduledoc for the shape).

  Split out from `build/1` so the IR -> contract mapping is unit-testable
  against hand-built IR fixtures, the same way `AshSwift.Codegen.ReaderTest`
  asserts on `Reader.read/1`'s output directly rather than only through
  rendered Swift: a test can hand this a small resource map, then a copy with
  one field added or one action removed, without compiling a real Ash resource
  for every case.
  """
  @spec build_from_ir(%{primary_resources: [map()], all_resources: [map()]}) :: map()
  def build_from_ir(%{primary_resources: primary, all_resources: all}) do
    %{
      contract_version: @contract_version,
      ash_swift_version: ash_swift_version(),
      actions: collect_actions(primary),
      types: collect_types(all),
      enums: collect_enums(all)
    }
  end

  @doc """
  Encodes `domains`' contract as deterministic, pretty-printed JSON: two calls
  on the same domains produce byte-identical output regardless of Elixir's
  internal map iteration order, because every object is re-emitted as a
  `Jason.OrderedObject` with alphabetically sorted keys before encoding.
  """
  @spec encode([module()]) :: String.t()
  def encode(domains) when is_list(domains) do
    domains |> build() |> encode_document()
  end

  @doc """
  Encodes an already-built contract document (`build/1`'s or `build_from_ir/1`'s
  return value) as deterministic, pretty-printed JSON. Split out from `encode/1`
  so a caller that needs to inspect the document before deciding whether to
  print it (e.g. `mix ash_swift.contract`'s zero-actions guard) doesn't have to
  read the manifest twice.
  """
  @spec encode_document(map()) :: String.t()
  def encode_document(document) when is_map(document) do
    document
    |> to_ordered()
    |> Jason.encode!(pretty: true)
  end

  # --- actions --------------------------------------------------------------

  defp collect_actions(primary_resources) do
    primary_resources
    |> Enum.flat_map(fn resource ->
      Enum.map(resource.actions, &action_entry(&1, resource))
    end)
    |> Enum.sort_by(&{&1.resource, &1.name})
  end

  defp action_entry(action, resource) do
    %{
      name: to_string(action.rpc_name),
      resource: resource.type_name,
      resource_module: module_name(resource.resource_module),
      domain: module_name(resource.domain),
      action: to_string(action.action),
      action_type: to_string(action.action_type),
      sortable: action.sortable?,
      filterable: action.filterable?,
      inputs: action_inputs(action, resource),
      result_type: result_type(action, resource.type_name),
      optional_pagination: optional_pagination(action, resource.type_name)
    }
  end

  # An action's input arguments, from whichever of its three possible sources
  # apply: lookup fields (get/get_by/identity), the primary-key identity params
  # (update/destroy), and its generated input struct's fields (create/update/
  # generic action). A plain list read has none of these — sort/filter/page/
  # fields are client query capabilities, not RPC-contract inputs, and are
  # deliberately out of scope here (issue #85 asks for action inputs, not the
  # full method signature).
  defp action_inputs(action, resource) do
    lookup_inputs =
      (action.get_by_params ++ action.primary_key_params)
      |> Enum.map(fn %{name: name, swift_type: type} ->
        %{name: to_string(name), type: type, required: true}
      end)

    struct_inputs =
      case find_input_struct(resource, action.input_struct_name) do
        nil ->
          []

        %{fields: fields} ->
          Enum.map(fields, fn %{name: name, swift_type: type, required?: required?} ->
            %{name: to_string(name), type: type, required: required?}
          end)
      end

    # `lookup_inputs` is listed first on purpose: for an `:update` action whose
    # accept list happens to also name the primary-key attribute (rare, but
    # legal — nothing stops a resource from allowing its own PK to be
    # reassigned), the same name shows up in both lists with different
    # `required` values — `true` from the identity param that selects which
    # record to update, `false` from the struct field (every update field is
    # optional; see `collect_action_inputs/5` in `Reader`). `uniq_by/2` keeps
    # the first occurrence, so the identity param wins: it is the value a
    # caller must always supply to make the call at all, which is the more
    # useful "required" answer for a single collapsed entry even though the
    # two names travel as genuinely separate wire keys (`identity` vs.
    # `input.{name}`) in the emitted Swift.
    (lookup_inputs ++ struct_inputs)
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

  defp find_input_struct(_resource, nil), do: nil

  defp find_input_struct(resource, struct_name) do
    Enum.find(resource.input_structs, &(&1.struct_name == struct_name))
  end

  # Mirrors the return-type half of Emitter.method_spec/2 (the Swift-syntax
  # half — params, request type, docstring — is deliberately not reproduced
  # here; only the resulting type is part of the contract). Kept in sync with
  # the emitter by the fixture-domain golden cross-check
  # (`AshSwift.Codegen.ContractTest` "the contract's {action name, overloads} set
  # equals the functions Emitter.render_functions/1 emits"): it renders
  # `AshSwift.Test.Domain` through the real emitter and
  # asserts every contract result_type/optional_pagination.result_type shows up
  # as a return type in the generated Swift, so any drift between this and
  # `Emitter.method_spec/2` fails a real test rather than resting on this
  # comment alone.
  defp result_type(%{action_type: :read, is_get?: false, pagination_type: :offset}, type_name),
    do: "OffsetPage<#{type_name}>"

  defp result_type(%{action_type: :read, is_get?: false, pagination_type: :keyset}, type_name),
    do: "KeysetPage<#{type_name}>"

  defp result_type(%{action_type: :read, is_get?: false}, type_name), do: "[#{type_name}]"

  defp result_type(%{action_type: :read, is_get?: true, not_found_error?: true}, type_name),
    do: type_name

  defp result_type(%{action_type: :read, is_get?: true}, type_name), do: "#{type_name}?"

  defp result_type(%{action_type: :create}, type_name), do: type_name
  defp result_type(%{action_type: :update}, type_name), do: type_name
  defp result_type(%{action_type: :destroy}, _type_name), do: nil

  defp result_type(%{action_type: :action, generic_return: :void}, _type_name), do: nil

  defp result_type(%{action_type: :action, generic_return: {kind, swift_type}}, _type_name)
       when kind in [:typed, :typed_record],
       do: swift_type

  defp result_type(_action, _type_name), do: nil

  # The second, overloaded function `Emitter.method_specs/2` emits for a list
  # read that *supports* offset/keyset pagination without *requiring* it (see
  # `Reader`'s `optional_pagination_type`) — nil everywhere else, including for
  # a required-pagination read (that one function is already fully described by
  # `result_type/2` above; `optional_pagination_type` is `:none` there by
  # construction, see `Reader.optional_action_pagination_type/1`'s
  # mutual-exclusivity guard).
  defp optional_pagination(%{optional_pagination_type: :none}, _type_name), do: nil

  defp optional_pagination(%{optional_pagination_type: :offset}, type_name),
    do: %{type: "offset", result_type: "OffsetPage<#{type_name}>"}

  defp optional_pagination(%{optional_pagination_type: :keyset}, type_name),
    do: %{type: "keyset", result_type: "KeysetPage<#{type_name}>"}

  # --- types ------------------------------------------------------------

  defp collect_types(all_resources) do
    resource_types =
      Enum.map(all_resources, fn resource ->
        %{
          name: resource.type_name,
          kind: "resource",
          fields: type_fields(resource.fields)
        }
      end)

    struct_types =
      Enum.flat_map(all_resources, fn resource ->
        Enum.map(resource.input_structs, &input_struct_type/1)
      end)

    filter_types =
      Enum.flat_map(all_resources, fn resource ->
        case resource.filter_struct do
          nil -> []
          %{type_name: name, fields: fields} -> [filter_struct_type(name, fields)]
        end
      end)

    (resource_types ++ struct_types ++ filter_types)
    |> dedupe_by_name!("type")
    |> Enum.sort_by(& &1.name)
  end

  # A resource model field is always Optional in the generated struct — every
  # selectable field decodes as `nil` when field selection omits it (see
  # Emitter.render_fields's docstring). Recorded explicitly (rather than
  # omitted) so the contract states this rather than assuming a reader of the
  # JSON already knows the convention.
  defp type_fields(fields) do
    fields
    |> Enum.map(fn %{name: name, swift_type: type} ->
      %{name: to_string(name), type: type, optional: true}
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp input_struct_type(%{struct_name: name, fields: fields} = struct) do
    %{
      name: name,
      kind: if(Map.get(struct, :decodable?, false), do: "result", else: "input"),
      fields:
        fields
        |> Enum.map(fn %{name: fname, swift_type: type, required?: required?} ->
          %{name: to_string(fname), type: type, optional: not required?}
        end)
        |> Enum.sort_by(& &1.name)
    }
  end

  # Mirrors Emitter.render_filter_struct/1: one Optional operator-generic
  # property per filterable attribute, plus the fixed `and`/`or`/`not`
  # logical-combinator properties every filter struct carries (each an Optional
  # array of the same filter type) — read from `Emitter.filter_combinators/0`
  # rather than restated as a literal here, so a combinator added there is
  # reflected here automatically instead of silently under-reported (see the
  # type cross-check test in `AshSwift.Codegen.ContractTest`). A filter's own
  # name doubles as its element type, so the combinator field type is simply
  # `[{name}]`.
  defp filter_struct_type(name, fields) do
    predicate_fields =
      Enum.map(fields, fn %{name: fname, swift_type: type} ->
        %{name: to_string(fname), type: type, optional: true}
      end)

    combinator_fields =
      Enum.map(Emitter.filter_combinators(), fn combinator ->
        %{name: combinator, type: "[#{name}]", optional: true}
      end)

    %{
      name: name,
      kind: "filter",
      fields: (predicate_fields ++ combinator_fields) |> Enum.sort_by(& &1.name)
    }
  end

  # --- enums ------------------------------------------------------------

  defp collect_enums(all_resources) do
    domain_enums =
      all_resources
      |> Enum.flat_map(& &1.enums)
      |> Enum.map(fn %{enum_name: name, cases: cases} ->
        %{name: name, values: cases |> Enum.map(&to_string/1) |> Enum.sort()}
      end)

    # Emitter.render_sort_field_enum/1 emits `{Resource}SortField` as a plain
    # `public enum ...: String` exactly like an attribute-derived enum — its
    # cases are the resource's sortable attribute names, so it belongs in this
    # same list rather than a separate one (see moduledoc).
    sort_field_enums =
      Enum.flat_map(all_resources, fn resource ->
        case resource.sort_field do
          nil -> []
          %{type_name: name, fields: fields} -> [%{name: name, values: Enum.sort(fields)}]
        end
      end)

    (domain_enums ++ sort_field_enums)
    |> dedupe_by_name!("enum")
    |> Enum.sort_by(& &1.name)
  end

  # --- misc ------------------------------------------------------------

  # The installed ash_swift's own version, read from the compiled application
  # spec (the same place `mix hex.info ash_swift` or a runtime
  # `Application.spec/2` call would) rather than `Mix.Project.config()[:version]`
  # — the latter only resolves inside *this* project's own `mix` invocations
  # (e.g. its own test suite), returning `nil` for a downstream consumer that
  # calls `AshSwift.Codegen.contract/1` as a compiled dependency. `:vsn` comes
  # back as a charlist (the compiled `.app` resource format), hence `to_string/1`.
  defp ash_swift_version do
    case Application.spec(:ash_swift, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  defp module_name(nil), do: nil
  defp module_name(module), do: module |> to_string() |> String.trim_leading("Elixir.")

  # Groups entries by `name` and raises if any group holds more than one
  # distinct entry — a same-named type/enum with different content is exactly
  # the collision `AshSwift.Codegen.build_files/1` (via
  # `Reader.expand_with_related/2`) already raises on for the emitted Swift
  # itself; silently keeping whichever entry `Enum.uniq_by/2` happened to see
  # first would hide the same defect here instead of surfacing it.
  defp dedupe_by_name!(entries, kind) do
    entries
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn
      {_name, [entry]} ->
        entry

      {name, duplicates} ->
        case Enum.uniq(duplicates) do
          [entry] ->
            entry

          _distinct ->
            Mix.raise(
              "AshSwift.Codegen.Contract: #{kind} name #{inspect(name)} maps to multiple, " <>
                "different definitions — #{inspect(duplicates)}. This is the same naming " <>
                "collision codegen itself would refuse to emit; rename the colliding " <>
                "resource/attribute/field."
            )
        end
    end)
  end

  # --- deterministic JSON ------------------------------------------------

  # Elixir's plain-map iteration order is not documented as stable across
  # releases, so `Jason.encode!/2` given a bare map cannot be trusted for
  # byte-identical output on its own (the very thing this document exists to
  # guarantee). Recursing through the built document and re-wrapping every map
  # as a `Jason.OrderedObject` with its keys sorted alphabetically pins the key
  # order explicitly instead of relying on it.
  defp to_ordered(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), to_ordered(v)} end)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Jason.OrderedObject.new()
  end

  defp to_ordered(list) when is_list(list), do: Enum.map(list, &to_ordered/1)
  defp to_ordered(other), do: other
end
