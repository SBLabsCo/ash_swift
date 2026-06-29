defmodule AshSwift.Codegen.Reader do
  @moduledoc """
  Reads `Ash.Info.Manifest` into the intermediate representation (IR) the
  emitters render. `read/1` is the sole entry point: domains in, a
  `%{primary_resources, all_resources}` map of plain resource/action/field maps
  out. This is the manifest-facing half of codegen (ADR-0009) — it knows about
  Ash, AshTypescript, and `AshSwift.Codegen.TypeMap`; the emitter half is pure
  string work on the maps produced here.
  """

  require Logger

  alias Ash.Info.Manifest
  alias Ash.Info.Manifest.Resource, as: ManifestResource
  alias AshSwift.Codegen.TypeMap
  alias AshTypescript.FieldFormatter
  alias AshTypescript.Resource.Info, as: ResourceInfo
  alias AshTypescript.Rpc.Info, as: RpcInfo

  # Built-in Swift types that are always safe to reference from related-resource
  # structs (no generated struct needed, never "2 hops away"). Includes scalar
  # types and AshJSON, which lives in the runtime package.
  @builtin_swift_types MapSet.new([
                         "String",
                         "Bool",
                         "Int",
                         "Double",
                         "Date",
                         "AshJSON"
                       ])

  # The comparable scalar Swift types the backend can sort a read by. An
  # attribute mapping to one of these (or an enum) is emitted as a sort field;
  # composite types (e.g. Ash.Type.Map → "[String: AshJSON]") are not — see
  # sortable_attribute?/1.
  @sortable_swift_types MapSet.new(["String", "Bool", "Int", "Double", "Date"])

  # The Ash.Info.Manifest JSON-schema version this codegen was written against.
  # Guarded in build_manifest/1 so a future Ash that bumps the manifest shape
  # fails loudly with an actionable message rather than as a confusing nil or
  # key-not-found error deep inside the emitters.
  @manifest_schema_version "1.0.0"

  @doc """
  Reads the given domains into the IR the emitters render.

  Returns `%{primary_resources: primary, all_resources: all}` where `primary`
  is the RPC-exposed resources (the function surface) and `all` additionally
  includes one-hop related resources (the type surface).
  """
  def read(domains) do
    manifest = build_manifest(domains)
    primary = collect_resources(domains, manifest)
    all = expand_with_related(primary, manifest)
    %{primary_resources: primary, all_resources: all}
  end

  # Generates the Ash manifest scoped to exactly the RPC-exposed action
  # entrypoints of the given domains, and returns its lookup maps (keyed by
  # resource module, {resource, action} pair, and named-type module). Scoping via
  # `:action_entrypoints` keeps codegen independent of the host app's
  # `:ash_domains` config: `build_files([AnyDomain])` works whether or not that
  # domain is configured app-wide (the test suite relies on this).
  #
  # The manifest is the sole resource-metadata source (ADR-0009): which resources
  # and actions are exposed still comes from the `typescript_rpc` DSL, but every
  # field, type, relationship, action input, and pagination detail is read from
  # the manifest rather than `Ash.Resource.Info`.
  defp build_manifest([]), do: %{resources: %{}, actions: %{}, types: %{}}

  defp build_manifest([first | _] = domains) do
    assert_manifest_schema_version!()

    entrypoints =
      domains
      |> Enum.flat_map(&RpcInfo.typescript_rpc/1)
      |> Enum.flat_map(fn %{resource: resource, rpc_actions: rpc_actions} ->
        Enum.map(rpc_actions, fn rpc_action -> {resource, rpc_action.action} end)
      end)

    {:ok, manifest} =
      Manifest.generate(
        otp_app: Application.get_application(first),
        action_entrypoints: entrypoints
      )

    %{
      resources: Manifest.resource_lookup(manifest),
      actions: Manifest.action_lookup(manifest),
      types: Manifest.type_lookup(manifest)
    }
  end

  # Pins the manifest schema version codegen was written against. A mismatch means
  # Ash changed the manifest shape; surface it here with guidance instead of
  # letting the emitters fail obscurely on a renamed/removed field.
  defp assert_manifest_schema_version! do
    actual = Manifest.schema_version()

    if actual != @manifest_schema_version do
      Mix.raise(
        "AshSwift codegen targets Ash.Info.Manifest schema #{@manifest_schema_version}, but the " <>
          "installed Ash reports #{actual}. The manifest shape may have changed — review " <>
          "AshSwift.Codegen against the new manifest before regenerating."
      )
    end
  end

  # A resource's public attributes, normalised into the minimal shape the
  # decision helpers consume: the raw name (for the field formatter), the
  # underlying Ash type module (for Swift mapping and filter grouping),
  # nullability and default presence (for input-struct required? detection), and
  # the enum value list when the attribute is an enum. Sourced from the manifest
  # field list, which is public-only and already sorted by name.
  defp manifest_attributes(mres, types) do
    mres
    |> ManifestResource.fields_by_kind(:attribute)
    |> Enum.map(fn field ->
      %{
        name: field.name,
        ash_type: field.type.module,
        allow_nil?: field.allow_nil?,
        has_default?: field.has_default?,
        enum_values: manifest_enum_values(field.type, types)
      }
    end)
  end

  # The enum value list for a manifest field type, or nil when it isn't an enum.
  # An inline `Ash.Type.Atom` with a one_of constraint carries `kind: :enum` and
  # its `values` directly; a named `Ash.Type.Enum` is a `:type_ref` resolved
  # through the type lookup to its `:enum` definition.
  defp manifest_enum_values(%{kind: :enum, values: values}, _types) when is_list(values),
    do: values

  defp manifest_enum_values(%{kind: :type_ref, module: module}, types) do
    case Map.get(types, module) do
      %{kind: :enum, values: values} when is_list(values) -> values
      _ -> nil
    end
  end

  defp manifest_enum_values(_type, _types), do: nil

  # Collects every RPC-exposed resource across the given domains, normalised into
  # a sorted list of maps the renderers consume. Sorting by Swift type name keeps
  # output deterministic regardless of domain/declaration order.
  defp collect_resources(domains, manifest) do
    domains
    |> Enum.flat_map(&RpcInfo.typescript_rpc/1)
    |> Enum.map(fn %{resource: resource, rpc_actions: rpc_actions} ->
      type_name = ResourceInfo.typescript_type_name!(resource)
      mres = Map.fetch!(manifest.resources, resource)
      {fields, enums} = collect_fields(mres, type_name, manifest.types)
      formatter = AshTypescript.output_field_formatter() || :camel_case

      # A resource's sortable public attributes, computed once. When empty, the
      # resource has no sort surface: a sortable read with zero sortable attributes
      # must NOT emit a `{Resource}SortField` enum (an empty raw-value enum does not
      # compile in Swift) nor a `sort:` parameter referencing it. Folding this into
      # each action's `sortable?` mirrors how `enable_sort?: false` drops the sort
      # surface (issue #41).
      sortable_fields = collect_sortable_fields(mres, formatter, manifest.types)
      has_sortable_fields? = not Enum.empty?(sortable_fields)

      # Build actions and, in the same pass, collect the input structs to emit.
      {actions_unsorted, input_structs_unsorted} =
        Enum.reduce(rpc_actions, {[], []}, fn rpc_action, {actions_acc, structs_acc} ->
          maction = Map.fetch!(manifest.actions, {resource, rpc_action.action})

          # Generic (`:action`-type) actions are shaped differently from CRUD —
          # their inputs are action *arguments* (not attributes) and their return
          # is nil (void) or a custom type — so they get their own collector that
          # may also skip an action whose return needs field selection (#54).
          if maction.type == :action do
            collect_generic_action(
              maction,
              rpc_action,
              resource,
              formatter,
              {actions_acc, structs_acc}
            )
          else
            collect_crud_action(
              maction,
              rpc_action,
              resource,
              mres,
              type_name,
              formatter,
              manifest.types,
              has_sortable_fields?,
              {actions_acc, structs_acc}
            )
          end
        end)

      collect_query_surface(
        actions_unsorted,
        input_structs_unsorted,
        resource,
        type_name,
        fields,
        enums,
        mres,
        formatter,
        manifest.types,
        sortable_fields
      )
    end)
    |> Enum.sort_by(& &1.type_name)
  end

  # The CRUD (read/create/update/destroy) per-action collector: unchanged from the
  # original inline reduce body, extracted so the generic-action path can sit
  # beside it (#54).
  defp collect_crud_action(
         maction,
         rpc_action,
         resource,
         mres,
         type_name,
         formatter,
         types,
         has_sortable_fields?,
         {actions_acc, structs_acc}
       ) do
    {is_get?, get_by_params, get_by_location} =
      if maction.type == :read do
        build_get_info(maction, rpc_action, resource, formatter, mres)
      else
        {false, [], nil}
      end

    pagination_type =
      if maction.type == :read do
        action_pagination_type(maction)
      else
        :none
      end

    # Optional pagination (required?: false but offset?/keyset? supported) on a
    # list read. These don't change the bare `[T]` function; they gain a second,
    # *overloaded* paginated function (see method_specs/2). Get actions and
    # required-pagination actions are excluded — :none means "no overload".
    optional_pagination_type =
      if maction.type == :read and not is_get? do
        optional_action_pagination_type(maction)
      else
        :none
      end

    not_found_error? =
      case Map.get(rpc_action, :not_found_error?) do
        nil -> AshTypescript.Rpc.not_found_error?()
        value -> value
      end

    # Sorting is offered only on list (non-get) read actions whose RPC
    # action leaves `enable_sort?` at its default of true. A false flag
    # drops the sort: parameter so a forbidden sort is a compile error.
    # Also requires the resource to actually have sortable fields — a sort
    # over an empty SortField enum is meaningless and won't compile (#41).
    sortable? =
      maction.type == :read and not is_get? and sort_enabled?(rpc_action) and
        has_sortable_fields?

    # Filtering is offered on the same surface as sorting — list (non-get)
    # read actions whose RPC action leaves `enable_filter?` at its default
    # of true. A false flag drops the filter: parameter so a forbidden
    # filter is a compile error, not a silently-ignored argument.
    filterable? = maction.type == :read and not is_get? and filter_enabled?(rpc_action)

    {input_struct_name, primary_key_params} =
      case maction.type do
        type when type in [:create, :update] ->
          struct_name = pascal_case(rpc_action.name) <> "Input"

          {struct_name, build_get_by_params(mres.primary_key, resource, formatter)}

        :destroy ->
          {nil, build_get_by_params(mres.primary_key, resource, formatter)}

        _ ->
          {nil, []}
      end

    action = %{
      rpc_name: rpc_action.name,
      action: rpc_action.action,
      action_type: maction.type,
      is_get?: is_get?,
      get_by_params: get_by_params,
      get_by_location: get_by_location,
      not_found_error?: not_found_error?,
      input_struct_name: input_struct_name,
      primary_key_params: primary_key_params,
      pagination_type: pagination_type,
      optional_pagination_type: optional_pagination_type,
      sortable?: sortable?,
      filterable?: filterable?
    }

    new_struct =
      if input_struct_name do
        inputs = collect_action_inputs(maction, mres, type_name, formatter, types)
        [%{struct_name: input_struct_name, fields: inputs}]
      else
        []
      end

    {[action | actions_acc], new_struct ++ structs_acc}
  end

  # Per-action collector for generic (`:action`-type) actions (#54). Inputs are
  # action *arguments* mapped straight from their manifest type (not resource
  # attributes); the return is classified by generic_action_return/1. An action
  # whose return needs field selection or is an unmapped type is skipped with a
  # warning rather than emitted with a wrong decode — the accumulator passes
  # through unchanged.
  defp collect_generic_action(
         maction,
         rpc_action,
         resource,
         formatter,
         {actions_acc, structs_acc} = acc
       ) do
    with gen_return when gen_return != :unsupported <- generic_action_return(maction.returns),
         {:ok, inputs} <- collect_generic_action_inputs(maction, resource, formatter) do
      input_struct_name = if inputs == [], do: nil, else: pascal_case(rpc_action.name) <> "Input"

      action = %{
        rpc_name: rpc_action.name,
        action: rpc_action.action,
        action_type: :action,
        is_get?: false,
        get_by_params: [],
        get_by_location: nil,
        not_found_error?: false,
        input_struct_name: input_struct_name,
        primary_key_params: [],
        pagination_type: :none,
        optional_pagination_type: :none,
        sortable?: false,
        filterable?: false,
        generic_return: gen_return
      }

      new_struct =
        if input_struct_name,
          do: [%{struct_name: input_struct_name, fields: inputs}],
          else: []

      {[action | actions_acc], new_struct ++ structs_acc}
    else
      # A return that needs field selection / maps to no Swift type, or an argument
      # of an unmappable type (e.g. a list/array arg) — skip the whole action with
      # a warning rather than emit a wrong decode or a String-guessed input field.
      :unsupported ->
        warn_skip_generic(
          maction,
          "returns #{inspect(maction.returns && maction.returns.kind)}, which needs field " <>
            "selection or maps to no Swift type"
        )

        acc

      {:unsupported, arg_name} ->
        warn_skip_generic(
          maction,
          "has argument #{inspect(arg_name)} of a type that maps to no Swift type"
        )

        acc
    end
  end

  defp warn_skip_generic(maction, reason) do
    Logger.warning(
      "AshSwift: generic action #{inspect(maction.name)} #{reason}; skipping. Typed-record " <>
        "returns (field selection) are tracked in issue #56; other unmapped shapes are out of " <>
        "scope for the generic-action slice (#54)."
    )
  end

  # Maps a generic action's arguments to input-struct fields. Unlike create/update
  # inputs (resolved against resource attributes), a generic action's inputs are
  # action arguments carrying their own manifest type, so the Swift type comes from
  # TypeMap.generic_swift_type/1 and optionality from `input.required?` (the presence flag
  # the Argument moduledoc points consumers at). If ANY argument has an unmappable
  # type (module: nil array, struct, …), the whole action is unsupported —
  # returning {:unsupported, name} so the caller skips it, symmetric with the
  # return-type gate. Otherwise returns {:ok, fields} sorted by name.
  defp collect_generic_action_inputs(maction, resource, formatter) do
    maction.inputs
    |> Enum.reduce_while({:ok, []}, fn input, {:ok, acc} ->
      case TypeMap.generic_swift_type(input.type) do
        {:ok, swift_type} ->
          field = %{
            name: FieldFormatter.format_field_for_client(input.name, resource, formatter),
            swift_type: swift_type,
            required?: input.required?
          }

          {:cont, {:ok, [field | acc]}}

        :unsupported ->
          {:halt, {:unsupported, input.name}}
      end
    end)
    |> case do
      {:ok, fields} -> {:ok, Enum.sort_by(fields, & &1.name)}
      unsupported -> unsupported
    end
  end

  # Builds a resource's query-surface types (sortable-field enum, filter struct)
  # from its collected actions, and assembles the final resource map the renderers
  # consume. Extracted from collect_resources/2 so the per-action reduce can route
  # CRUD and generic actions to separate collectors (#54).
  defp collect_query_surface(
         actions_unsorted,
         input_structs_unsorted,
         resource,
         type_name,
         fields,
         enums,
         mres,
         formatter,
         types,
         sortable_fields
       ) do
    # A resource needs a typed sortable-field enum only when at least one of its
    # actions actually exposes sorting. Because `sortable?` already requires
    # `has_sortable_fields?`, this is false when there are no sortable fields, so
    # no empty enum is emitted (#41). Reuses the fields computed above.
    sort_field =
      if Enum.any?(actions_unsorted, & &1.sortable?) do
        %{type_name: type_name <> "SortField", fields: sortable_fields}
      else
        nil
      end

    # A resource needs a typed {Resource}Filter only when at least one of its
    # actions exposes filtering; otherwise the struct would be dead code.
    filter_struct =
      if Enum.any?(actions_unsorted, & &1.filterable?) do
        %{
          type_name: type_name <> "Filter",
          fields: collect_filter_fields(mres, type_name, formatter, types)
        }
      else
        nil
      end

    %{
      resource_module: resource,
      type_name: type_name,
      fields: fields,
      enums: enums,
      actions: Enum.sort_by(actions_unsorted, & &1.rpc_name),
      input_structs: input_structs_unsorted |> Enum.sort_by(& &1.struct_name),
      sort_field: sort_field,
      filter_struct: filter_struct
    }
  end

  # Collects a resource's public-attribute names (client-formatted, sorted) for
  # the typed sortable-field enum. Relationships, aggregates, and calculations
  # are out of scope for M2 sorting.
  defp collect_sortable_fields(mres, formatter, types) do
    mres
    |> manifest_attributes(types)
    |> Enum.filter(&sortable_attribute?/1)
    |> Enum.map(fn attr ->
      FieldFormatter.format_field_for_client(attr.name, mres.module, formatter)
    end)
    |> Enum.sort()
  end

  # Whether the backend can order a read by this attribute. Enum attributes and
  # comparable scalars (the types that map to String/Bool/Int/Double/Date) are
  # sortable; composite types like `Ash.Type.Map` (a JSON object → `[String:
  # AshJSON]`) are not — Ash returns an error when asked to sort by them, so
  # emitting them as typed sort fields would be a runtime footgun with no valid
  # use. Relationship/aggregate/calculation sorting stays out of scope for M2.
  defp sortable_attribute?(attr) do
    case TypeMap.extract_enum_cases(attr) do
      {:ok, _} -> true
      :not_enum -> MapSet.member?(@sortable_swift_types, TypeMap.ash_type_to_swift(attr.ash_type))
    end
  end

  # Reads the RPC action's `enable_sort?` flag, defaulting to true (the
  # AshTypescript default) when unset. This relies on AshTypescript's Spark
  # entity carrying the option through on the rpc_action struct — the same
  # pass-through contract `not_found_error?` above depends on.
  defp sort_enabled?(rpc_action), do: Map.get(rpc_action, :enable_sort?, true)

  # Reads the RPC action's `enable_filter?` flag, defaulting to true (the
  # AshTypescript default). Same Spark pass-through contract as `enable_sort?`.
  defp filter_enabled?(rpc_action), do: Map.get(rpc_action, :enable_filter?, true)

  # Collects the typed filter properties for a resource: one per public,
  # filterable attribute (enums included), client-formatted and sorted. Each maps
  # to a hand-written operator generic from AshSwiftRuntime instantiated over the
  # attribute's Swift value type. Composite types (Ash.Type.Map → a JSON object)
  # are excluded — filtering a whole JSON blob by equality is a footgun the
  # backend rejects, mirroring the sort-field exclusion. The and/or/not logical
  # combinators are added on top of these per-attribute predicates (issue #36, see
  # render_filter_struct); relationship/aggregate/calculation filtering stays out
  # of M2 scope.
  defp collect_filter_fields(mres, type_name, formatter, types) do
    mres
    |> manifest_attributes(types)
    |> Enum.flat_map(fn attr ->
      case filter_field(attr, mres.module, type_name, formatter) do
        nil -> []
        field -> [field]
      end
    end)
    |> Enum.sort_by(& &1.name)
  end

  # Builds one filter property %{name, swift_type} for a public attribute, or nil
  # when the attribute's type isn't filterable (composite types like Ash.Type.Map).
  # swift_type is the operator generic (e.g. "NullableComparableOperators<Int>"):
  # the operator GROUP is driven by the Ash type (so a Decimal — wire String —
  # still gets the comparable group), while the generic's value type is the
  # mapped Swift type (enums use their generated Swift enum). A nullable attribute
  # selects the `Nullable*` variant, which adds the `isNil` operator.
  #
  # The single `TypeMap.extract_enum_cases/1` call decides both axes: enums share the
  # equality+membership group (eq/notEq/in) and filter over their generated Swift
  # enum; everything else takes its group and value type from the Ash scalar type.
  defp filter_field(attr, resource, type_name, formatter) do
    name = FieldFormatter.format_field_for_client(attr.name, resource, formatter)

    {group, value_type} =
      case TypeMap.extract_enum_cases(attr) do
        {:ok, _} ->
          {:enum, enum_type_name(type_name, name)}

        :not_enum ->
          {TypeMap.scalar_filter_group(attr.ash_type), TypeMap.ash_type_to_swift(attr.ash_type)}
      end

    case group do
      :exclude ->
        nil

      _ ->
        generic = TypeMap.operator_generic_name(group, attr.allow_nil?)
        %{name: name, swift_type: "#{generic}<#{value_type}>"}
    end
  end

  # Returns a tuple {fields, enums} for the resource.
  #
  # fields: sorted list of %{name, swift_type} for public scalar attributes and
  # public relationships. Field names go through the same formatter AshTypescript
  # uses for output. Enum attributes produce a generated Swift enum type name
  # instead of the default "String" fallback.
  #
  # enums: sorted list of %{enum_name, cases} for each attribute whose Ash type
  # is an enum (Ash.Type.Atom with one_of constraint, or Ash.Type.Enum subtype).
  defp collect_fields(mres, type_name, types) do
    formatter = AshTypescript.output_field_formatter() || :camel_case
    resource = mres.module

    {attr_fields, enums} =
      mres
      |> manifest_attributes(types)
      |> Enum.reduce({[], []}, fn attr, {fields_acc, enums_acc} ->
        formatted_name = FieldFormatter.format_field_for_client(attr.name, resource, formatter)

        case TypeMap.extract_enum_cases(attr) do
          {:ok, cases} ->
            en_name = enum_type_name(type_name, formatted_name)
            field = %{name: formatted_name, swift_type: en_name}
            enum = %{enum_name: en_name, cases: cases}
            {[field | fields_acc], [enum | enums_acc]}

          :not_enum ->
            field = %{name: formatted_name, swift_type: TypeMap.ash_type_to_swift(attr.ash_type)}
            {[field | fields_acc], enums_acc}
        end
      end)

    {agg_fields, agg_enums} =
      collect_aggregate_fields(mres, type_name, resource, formatter, types)

    {calc_fields, calc_enums} =
      collect_calculation_fields(mres, type_name, resource, formatter, types)

    rel_fields =
      mres
      |> ManifestResource.all_relationships()
      |> Enum.flat_map(fn rel ->
        case ResourceInfo.typescript_type_name(rel.destination) do
          {:ok, dest_type} ->
            swift_type =
              case rel.cardinality do
                :one -> dest_type
                :many -> "[#{dest_type}]"
              end

            name = FieldFormatter.format_field_for_client(rel.name, resource, formatter)
            [%{name: name, swift_type: swift_type}]

          :error ->
            []
        end
      end)

    fields =
      (attr_fields ++ agg_fields ++ calc_fields ++ rel_fields) |> Enum.sort_by(& &1.name)

    sorted_enums = (enums ++ agg_enums ++ calc_enums) |> Enum.sort_by(& &1.enum_name)
    {fields, sorted_enums}
  end

  # Classifies a generic action's return: nil -> :void (a side-effecting action);
  # otherwise through TypeMap.generic_swift_type/1 (scalar/map -> {:typed, t};
  # anything needing field selection or otherwise unmapped -> :unsupported).
  # Resource/struct returns are Tier C — they need field selection (issue #56).
  defp generic_action_return(nil), do: :void

  defp generic_action_return(type) do
    case TypeMap.generic_swift_type(type) do
      {:ok, swift_type} -> {:typed, swift_type}
      :unsupported -> :unsupported
    end
  end

  # Public aggregates as Optional model fields. The manifest already excludes
  # private aggregates, so this is public-only by construction. Emission rules are
  # shared with calculations via emit_derived_fields/5.
  defp collect_aggregate_fields(mres, type_name, resource, formatter, types) do
    mres
    |> ManifestResource.fields_by_kind(:aggregate)
    |> emit_derived_fields(type_name, resource, formatter, types)
  end

  # Public calculations as Optional model fields (issue #52). Mechanically
  # identical to aggregates — same fields_by_kind accessor, same emit_derived_fields/5
  # type mapping, same `.scalar("name")` wire path — with one calculation-specific
  # gate: only a calculation that takes *no arguments at all* is selectable via the
  # plain `.scalar` path. Any argument-bearing calculation — even one whose
  # arguments are all optional — is rejected by the reused AshTypescript RPC
  # pipeline with "Calculation requires arguments" unless selected through the
  # args-bearing shape ({ calcName: { args: {...} } }), which doesn't exist yet.
  # So argument-bearing calculations are deferred to M3 and dropped here rather
  # than emitted as fields that fail at request time. (The issue's PRD assumed
  # all-optional-arg calcs were zero-arg-selectable; probing the live pipeline
  # showed otherwise — see lessons.md.) The manifest is public-only, so private
  # calculations are excluded for free.
  defp collect_calculation_fields(mres, type_name, resource, formatter, types) do
    mres
    |> ManifestResource.fields_by_kind(:calculation)
    |> Enum.reject(&calculation_takes_arguments?/1)
    |> emit_derived_fields(type_name, resource, formatter, types)
  end

  # The manifest represents a zero-argument calculation with `arguments: []`, so
  # `[]` is the real zero-arg signal; the `|| []` only guards a defensively-nil
  # field (the per-argument `required?` being nil — see lessons.md — is a separate
  # thing and doesn't enter here).
  defp calculation_takes_arguments?(field) do
    not Enum.empty?(field.arguments || [])
  end

  # Maps a list of derived (aggregate/calculation) manifest Fields to
  # {fields, enums} in the shape collect_fields/3 expects, mirroring its attribute
  # reduce: an enum-typed field produces a generated Swift enum plus a typed field;
  # a scalar field maps through TypeMap.ash_type_to_swift; anything else is skipped
  # (see TypeMap.derived_scalar_kinds/0).
  defp emit_derived_fields(fields, type_name, resource, formatter, types) do
    Enum.reduce(fields, {[], []}, fn field, {fields_acc, enums_acc} ->
      formatted_name = FieldFormatter.format_field_for_client(field.name, resource, formatter)

      case manifest_enum_values(field.type, types) do
        values when is_list(values) ->
          en_name = enum_type_name(type_name, formatted_name)
          enum = %{enum_name: en_name, cases: values}
          {[%{name: formatted_name, swift_type: en_name} | fields_acc], [enum | enums_acc]}

        nil ->
          # Guard on a concrete module too: the gate's intent is skip-when-uncertain,
          # and TypeMap.ash_type_to_swift/1 String-fallbacks an unknown/nil module — exactly
          # the silent mis-decode this gate exists to prevent. Ash populates module
          # for standard scalars, so this only excludes genuinely unresolvable types.
          if field.type.kind in TypeMap.derived_scalar_kinds() and not is_nil(field.type.module) do
            field_map = %{
              name: formatted_name,
              swift_type: TypeMap.ash_type_to_swift(field.type.module)
            }

            {[field_map | fields_acc], enums_acc}
          else
            {fields_acc, enums_acc}
          end
      end
    end)
  end

  # Augments the primary resource list with any related resources referenced by
  # their relationships that aren't already in the primary set. The related
  # resource's struct must be in the types file so the nested field decodes
  # correctly. Only one hop of relationship expansion is performed for M1.
  #
  # Related entries share the same map shape as primary entries (resource_module:
  # nil, actions: []) so render_types and render_functions always see uniform
  # maps regardless of which list they iterate.
  #
  # 2-hop guard: a related resource's own relationship fields may point to types
  # that are never emitted (2 hops away). Those fields are dropped so the
  # generated Swift compiles without undefined-type references. Enum fields are
  # always safe because their type is defined in the same file.
  defp expand_with_related(primary_resources, manifest) do
    primary_type_names = MapSet.new(primary_resources, & &1.type_name)

    related_raw =
      primary_resources
      |> Enum.flat_map(fn %{resource_module: resource} ->
        manifest.resources
        |> Map.fetch!(resource)
        |> ManifestResource.all_relationships()
        |> Enum.flat_map(fn rel ->
          # Skip when the destination has no Swift type name, is already a primary
          # resource, or isn't present in the manifest (e.g. not reachable as a
          # full resource entry). Each case yields no extra related struct.
          with {:ok, type_name} <- ResourceInfo.typescript_type_name(rel.destination),
               false <- MapSet.member?(primary_type_names, type_name),
               %{} = dest_mres <- Map.get(manifest.resources, rel.destination) do
            {fields, enums} = collect_fields(dest_mres, type_name, manifest.types)
            [%{type_name: type_name, fields: fields, enums: enums}]
          else
            _ -> []
          end
        end)
      end)
      |> Enum.uniq_by(& &1.type_name)

    all_type_names =
      MapSet.union(primary_type_names, MapSet.new(related_raw, & &1.type_name))

    # Enum types defined in this file are always safe to reference — include
    # them in the known-type set so the 2-hop guard doesn't drop enum fields.
    # Note: `related_raw` entries use the slim %{type_name, fields, enums} shape
    # (no :resource_module or :actions keys), so only :enums is accessed here.
    all_enum_type_names =
      (primary_resources ++ related_raw)
      |> Enum.flat_map(& &1.enums)
      |> MapSet.new(& &1.enum_name)

    collision = MapSet.intersection(all_type_names, all_enum_type_names)

    unless Enum.empty?(collision) do
      names = collision |> MapSet.to_list() |> Enum.sort() |> Enum.map_join(", ", &"\"#{&1}\"")

      Mix.raise(
        "AshSwift codegen: enum type name(s) #{names} conflict with resource struct name(s) — " <>
          "rename the field that generates this enum or rename the resource."
      )
    end

    related =
      Enum.map(related_raw, fn %{type_name: type_name, fields: fields, enums: enums} ->
        safe_fields =
          Enum.filter(fields, fn %{swift_type: swift_type} ->
            swift_type_safe?(swift_type, all_type_names, all_enum_type_names)
          end)

        %{
          resource_module: nil,
          type_name: type_name,
          fields: safe_fields,
          enums: enums,
          actions: [],
          input_structs: [],
          sort_field: nil,
          filter_struct: nil
        }
      end)

    (primary_resources ++ related) |> Enum.sort_by(& &1.type_name)
  end

  # Computes the Swift enum type name from the resource's Swift type name and the
  # formatted field name. E.g. type_name="Todo", field_name="priority" → "TodoPriority".
  # Only the first character of field_name is uppercased; the rest is preserved so
  # camelCase field names like "deliveryStatus" → "TodoDeliveryStatus".
  defp enum_type_name(type_name, field_name) do
    capitalized =
      case field_name do
        <<first::utf8, rest::binary>> -> String.upcase(<<first::utf8>>) <> rest
        "" -> ""
      end

    type_name <> capitalized
  end

  # Returns true when a Swift type expression is safe to use in a related
  # resource struct — i.e., all referenced types are either built-in or
  # defined in the emitted output (resource types, enums).
  #
  # Handles: scalars ("String?"), arrays ("[Todo]?"), and dicts ("[String: AshJSON]").
  # The dict case strips the leading "[String: " and trailing "]" to get the
  # value type, then checks it independently.
  #
  # Known limitation: nested generics (e.g. "[String: [AshJSON]]") are not
  # handled — stripping one bracket layer yields "[AshJSON]" as the value type,
  # which won't match any entry in the builtin or type-name sets. No current code
  # path generates such types, so this is a future-maintainer note, not a bug.
  defp swift_type_safe?(swift_type, all_type_names, all_enum_type_names) do
    bare =
      swift_type
      |> String.trim_trailing("?")
      |> String.trim_leading("[")
      |> String.trim_trailing("]")

    if String.starts_with?(bare, "String: ") do
      value_type = String.replace_prefix(bare, "String: ", "")
      builtin_or_known?(value_type, all_type_names, all_enum_type_names)
    else
      builtin_or_known?(bare, all_type_names, all_enum_type_names)
    end
  end

  defp builtin_or_known?(type_name, all_type_names, all_enum_type_names) do
    MapSet.member?(@builtin_swift_types, type_name) or
      MapSet.member?(all_type_names, type_name) or
      MapSet.member?(all_enum_type_names, type_name)
  end

  # Determines whether a read action is a get action and, if so, collects the
  # lookup field params and where to place them in the request body.
  #
  # Returns {is_get?, get_by_params, location} where:
  #   - get_by_params: list of %{name, swift_type} for the lookup fields
  #   - location: :input (native get_by on the action) | :get_by (RPC-level get_by)
  defp build_get_info(maction, rpc_action, resource, formatter, mres) do
    # Load-bearing invariant: for a `get?` action the manifest surfaces *exactly*
    # the lookup fields as inputs (e.g. `get_by :id` → inputs `[:id]`), with no
    # other arguments mixed in. If a future get action gains an extra argument,
    # `native_get_by` would over-include it and emit a spurious Swift parameter —
    # the golden snapshot would catch the regression. A pure `get?` action with no
    # explicit lookup fields has empty inputs and falls through to the primary key.
    native_get_by = if maction.get?, do: Enum.map(maction.inputs, & &1.name), else: []
    rpc_get_by = Map.get(rpc_action, :get_by) || []
    rpc_get? = Map.get(rpc_action, :get?, false)

    cond do
      native_get_by != [] ->
        # get_by on the Ash action itself: fields travel in the `input` body key.
        {true, build_get_by_params(native_get_by, resource, formatter), :input}

      rpc_get_by != [] ->
        # get_by on the RPC action entity: fields travel in the `getBy` body key.
        {true, build_get_by_params(rpc_get_by, resource, formatter), :get_by}

      rpc_get? || maction.get? ->
        # Pure get? (no explicit field list): look up by primary key via `input`.
        {true, build_get_by_params(mres.primary_key, resource, formatter), :input}

      true ->
        {false, [], nil}
    end
  end

  # Maps a list of field atoms to the %{name, swift_type} shapes method_spec uses.
  defp build_get_by_params(fields, resource, formatter) do
    Enum.map(fields, fn field ->
      name = FieldFormatter.format_field_for_client(field, resource, formatter)
      %{name: name, swift_type: "String"}
    end)
  end

  # Collects the accepted input fields for a create or update action, mapping
  # each to its Swift type and whether it is required (create only).
  #
  # Only public attributes in the action's accept list are included; arguments
  # and non-public attributes are skipped. All update fields are optional because
  # update is always a partial operation.
  defp collect_action_inputs(maction, mres, type_name, formatter, types) do
    resource = mres.module

    attrs_map =
      mres
      |> manifest_attributes(types)
      |> Map.new(fn attr -> {attr.name, attr} end)

    maction.inputs
    |> Enum.flat_map(fn input ->
      case Map.get(attrs_map, input.name) do
        nil ->
          Logger.warning(
            "AshSwift: input #{inspect(input.name)} of action #{inspect(maction.name)} " <>
              "is not a public attribute and will be omitted from the generated input struct. " <>
              "Action arguments are not yet supported."
          )

          []

        attr ->
          formatted_name = FieldFormatter.format_field_for_client(input.name, resource, formatter)

          swift_type =
            case TypeMap.extract_enum_cases(attr) do
              {:ok, _} -> enum_type_name(type_name, formatted_name)
              :not_enum -> TypeMap.ash_type_to_swift(attr.ash_type)
            end

          required? = maction.type == :create and not attr.allow_nil? and not attr.has_default?
          [%{name: formatted_name, swift_type: swift_type, required?: required?}]
      end
    end)
    |> Enum.sort_by(& &1.name)
  end

  # snake_case to PascalCase (e.g. create_todo → CreateTodo).
  defp pascal_case(name) do
    name |> to_string() |> String.split("_", trim: true) |> Enum.map_join(&String.capitalize/1)
  end

  # Determines the pagination type for a read action by inspecting the action's
  # pagination configuration. Returns :offset, :keyset, or :none.
  #
  # Only returns a paginated type when `required?: true` — actions where pagination
  # is optional still return `[T]` (no page param sent → bare array response).
  # Actions where both offset? and keyset? are enabled default to :offset.
  defp action_pagination_type(maction) do
    case maction.pagination do
      %{required?: true, offset?: true} -> :offset
      %{required?: true, keyset?: true} -> :keyset
      _ -> :none
    end
  end

  # The pagination type for a read action that *supports* offset/keyset but does
  # NOT require it (ADR-0007's deferred gap). Returns :offset, :keyset, or :none.
  #
  # Required-pagination actions are handled by action_pagination_type/1 (they get a
  # paginated return outright), so they're :none here. Prefers offset when both are
  # supported — mirroring action_pagination_type/1 and keeping a single page type
  # per action. The default ETS `:read` action carries offset?/keyset? true with
  # required?: false, so plain list reads land in :offset here.
  defp optional_action_pagination_type(maction) do
    case maction.pagination do
      # Mutual-exclusivity guard: required-pagination actions are emitted as a
      # single typed function by action_pagination_type/1, so they are :none here.
      # This clause MUST stay first — otherwise an action with `required?: true,
      # offset?: true` would match `%{offset?: true}` below and produce a duplicate
      # overload on top of the required-pagination function.
      %{required?: true} -> :none
      %{offset?: true} -> :offset
      %{keyset?: true} -> :keyset
      _ -> :none
    end
  end
end
