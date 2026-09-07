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
        actions: [%{name, domain, resource, action, action_type, inputs, result_type}],
        types: [%{name, kind, fields: [%{name, type, optional}]}],
        enums: [%{name, values}]
      }

  `actions` covers every RPC-exposed action on every primary (RPC-exposed)
  resource. `types` covers every struct the emitter writes to the types file:
  a resource's own model struct (`kind: "resource"`) plus every generated input
  struct (`kind: "input"`, Encodable) and result struct (`kind: "result"`,
  Decodable) — including related-resource structs pulled in one hop out and
  nested per-field structs (e.g. an array-of-record argument's element). `enums`
  covers every generated Swift enum, resource-attribute or derived-field alike.

  The reader does not yet give union or embedded-resource values a distinct
  shape of their own — an attribute of either kind currently either resolves to
  a plain scalar field (module-bearing types keep the String fallback) or is
  dropped as unsupported, so there is nothing beyond `types`/`enums` to surface
  for them today. Once the reader gains a first-class union/embedded model,
  extend this document rather than diffing Swift text for that instead.

  Every list is sorted by name and the JSON encoding uses alphabetically sorted
  object keys throughout (`to_ordered/1`), so two runs over the same domains
  produce byte-identical output — this is asserted directly, not merely
  implied by the reader's own sorting (see `AshSwift.Codegen.ContractTest`).
  """

  alias AshSwift.Codegen.Reader

  @contract_version 1

  # Baked in at compile time from this project's own mix.exs — the contract
  # names the AshSwift version that produced it, the same way a Hex package
  # manifest would, so a consumer can tell which codegen build emitted a given
  # snapshot without cross-referencing a git SHA.
  @ash_swift_version Mix.Project.config()[:version]

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
      ash_swift_version: @ash_swift_version,
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
    domains
    |> build()
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
      domain: domain_name(resource.resource_module),
      action: to_string(action.action),
      action_type: to_string(action.action_type),
      inputs: action_inputs(action, resource),
      result_type: result_type(action, resource.type_name)
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
  # the emitter by the fixture-domain golden test: any action whose Swift
  # return type changes without a matching contract-test update signals drift.
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

    (resource_types ++ struct_types)
    |> Enum.uniq_by(& &1.name)
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

  # --- enums ------------------------------------------------------------

  defp collect_enums(all_resources) do
    all_resources
    |> Enum.flat_map(& &1.enums)
    |> Enum.uniq_by(& &1.enum_name)
    |> Enum.map(fn %{enum_name: name, cases: cases} ->
      %{name: name, values: cases |> Enum.map(&to_string/1) |> Enum.sort()}
    end)
    |> Enum.sort_by(& &1.name)
  end

  # --- misc ------------------------------------------------------------

  defp module_name(nil), do: nil
  defp module_name(module), do: module |> to_string() |> String.trim_leading("Elixir.")

  defp domain_name(nil), do: nil

  defp domain_name(module) do
    case Ash.Resource.Info.domain(module) do
      nil -> nil
      domain -> module_name(domain)
    end
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
