defmodule AshSwift.Codegen.Reader do
  @moduledoc """
  Reads `Ash.Info.Manifest` into the intermediate representation (IR) the
  emitters render. `read/1` is the sole entry point: domains in, a
  `%{primary_resources, all_resources}` map of plain resource/action/field maps
  out. This is the manifest-facing half of codegen (ADR-0009) — it knows about
  Ash, AshTypescript, and `AshSwift.Codegen.TypeMap`; the emitter half is pure
  string work on the maps produced here.

  ## IR shape

  `read/1` returns `%{primary_resources: [resource], all_resources: [resource]}`,
  both sorted by `type_name`. `primary_resources` are the RPC-exposed resources
  (the only ones with functions emitted); `all_resources` additionally folds in
  related resources one hop out (their structs must exist for nested fields to
  decode — see `expand_with_related/2`).

  Each `resource` is a plain map with uniform keys (a related-only entry fills the
  function-side keys with empty placeholders so the emitter sees one shape):

      %{
        resource_module: module | nil,        # nil for a related-only entry
        domain:          module | nil,        # nil for a related-only entry (ADR-0009: read
                                              # straight off the IR, not Ash.Resource.Info.domain/1)
        type_name:       "Todo",                # validated plain Swift identifier; see the uniqueness invariant below
        fields:          [field],                 # attributes + relationships + derived; see Field below
        enums:           [%{enum_name, cases: [%{name, raw}]}],  # raw: wire string, nil when equal to name
        actions:         [action],                # [] for a related-only entry
        input_structs:   [%{struct_name, fields, decodable?}],  # decodable? true => Decodable result struct, else Encodable input
        sort_field:      %{type_name, fields} | nil,   # fields: [name_string]; nil when no sortable surface
        filter_struct:   %{type_name, fields} | nil    # fields: [%{name, swift_type}]; nil when no filterable surface
      }

  **Uniqueness invariant.** Every top-level Swift name the entries declare
  (`type_name`, each `enum_name`, each input/result `struct_name`,
  `sort_field.type_name`, `filter_struct.type_name`, plus the Emitter's fixed
  client struct `client_struct_name/0`, `AshRpc`) has exactly one owner across
  `all_resources`; `assert_unique_swift_names!/1` raises otherwise. Consumers
  (the Emitter, `Contract`) may rely on it.

  ### Field

  A model-struct field is always `%{name, swift_type, destination}`. For a
  **relationship** field `destination` is the destination resource module its
  Swift type refers to; the 2-hop guard in `expand_with_related/2` keeps such a
  field only when that resource's model struct is emitted in the file. For every
  other field (attribute, aggregate, calculation) `destination` is `nil`: its
  type is a built-in or an enum defined alongside it, so it is always safe to
  reference. (Not to be confused with a resource entry's `resource_module`.)

  ### Action

  Every `action` is a map with these keys. CRUD (`:read | :create | :update |
  :destroy`) and generic (`:action`) actions share the uniform keys.
  `input_required?` is present on CRUD actions only (always `false` outside a
  read or destroy with a required input: an argument, or an accepted attribute
  a soft destroy lists in `require_attributes`) and `generic_return` and
  `generic_return_resource` on generic actions only;
  every other key is present on every kind. A `[read only]` tag below means the
  value is *meaningful* only on reads, not that the key is absent elsewhere.

      %{
        rpc_name:        atom,                 # RPC action name; the Swift method name source (its lower-camelled form is validated as a Swift identifier; Reader raises otherwise)
        action:          atom,                 # the underlying Ash action name
        action_type:     :read | :create | :update | :destroy | :action,
        get:             nil | :pure | {:input, [param]} | {:get_by, [param]},  # see below; param is %{name, swift_type}
        not_found_error?: boolean,             # meaningful only when `get` is non-nil => returns T and throws on missing, false => T?;
                                               # on CRUD non-gets it carries the configured default; on generic actions it is always false.
                                               # ignored in both cases
        input_struct_name: String.t() | nil,   # the `{Name}Input` struct. create/update: always set; read: set only when it has
                                               # non-lookup arguments; destroy: set only when it declares arguments or (soft
                                               # destroy) accepts attributes (#102);
                                               # generic: set only when it has inputs
        input_required?: boolean,              # [CRUD only; absent on generic] meaningful only for reads and destroys: whether
                                               # `input:` must be supplied (some input is required: an argument, or an
                                               # accepted attribute a soft destroy lists in `require_attributes`); false otherwise
        primary_key_params: [%{name, swift_type}],  # update/destroy: the resource's PK params; [] for create/read/generic.
                                               # The identity that addresses the record; the emitter sends it as `identity`
        pagination_type: :offset | :keyset | :none,           # required pagination => paginated return; :none for gets (Emitter raises otherwise)
        optional_pagination_type: :offset | :keyset | :none,  # supported-but-optional => extra paginated overload; :none for gets (Emitter raises otherwise; Contract.optional_pagination/2 relies on it)
        sortable?:       boolean,              # list reads only (false for gets; Emitter raises otherwise)
        filterable?:     boolean,              # list reads only (false for gets; Emitter raises otherwise)
        generic_return:  :void | {:typed, swift_type} | {:typed_record, swift_type}  # [generic only]; a resource return's swift_type is the model type ("Todo"), "Todo?" when the action has allow_nil? true
        generic_return_resource: module | nil,  # [generic only] the resource a resource/struct return targets; expand_with_related/2 emits its model struct
      }

  `get` says whether an action is a single-record read and, if so, where its
  lookup travels on the wire. It is a closed set of four forms, so an
  impossible combination (a lookup param without a get, say) cannot be built:

    * `nil` — not a get (non-read actions, generic actions, list reads).
    * `{:input, params}` — a native Ash `get_by`, its fields sent inside the
      `input` dict.
    * `{:get_by, params}` — an RPC-level `get_by`, its fields sent under the
      request's `getBy`.
    * `:pure` — a pure `get?` action with no lookup channel: it narrows itself
      through its own arguments, sent as `input:`, and sends no identity (the
      RPC pipeline never reads `identity` for a read, see #91 and
      docs/agents/lessons.md). It still emits a get function, with no lookup
      parameter.

  Each `param` is a `%{name, swift_type}` map. The emitter picks the get clause
  on any non-nil `get`.

  The two query-surface fields differ in shape, so mind which you assert on:

    * `sort_field.fields` is a list of camelCase attribute-name **strings**
      (`["dueAt", "title", …]`) — the cases of the generated `{Resource}SortField`
      enum.
    * `filter_struct.fields` is a list of **maps** `%{name, swift_type}`, where
      `swift_type` is the operator generic (e.g. `"NullableComparableOperators<Int>"`).
  """

  require Logger

  alias Ash.Info.Manifest
  alias Ash.Info.Manifest.Resource, as: ManifestResource
  alias AshSwift.Codegen.Naming
  alias AshSwift.Codegen.TypeMap
  alias AshTypescript.FieldFormatter
  alias AshTypescript.Resource.Info, as: ResourceInfo
  alias AshTypescript.Rpc.Info, as: RpcInfo

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
  # the manifest rather than `Ash.Resource.Info`, except the argument/get_by
  # facts the manifest lacks, which `ash_action_facts/2` reads in one place (a
  # deliberate ADR-0009 deviation).
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
  # manifest type of the attribute's *value* plus its Ash type module (for Swift
  # mapping and filter grouping), the two array flags, nullability and default
  # presence (for input-struct required? detection), and the enum value list when
  # the attribute is an enum. Sourced from the manifest field list, which is
  # public-only and already sorted by name.
  defp manifest_attributes(mres, types) do
    mres
    |> ManifestResource.fields_by_kind(:attribute)
    |> Enum.map(fn field ->
      {value_type, array?, nil_items?} = unwrap_array(field.type)

      %{
        name: field.name,
        value_type: value_type,
        ash_type: value_type.module,
        array?: array?,
        nil_items?: nil_items?,
        allow_nil?: field.allow_nil?,
        has_default?: field.has_default?,
        enum_values: manifest_enum_values(value_type, types)
      }
    end)
  end

  # Splits an attribute's manifest type into {value_type, array?, nil_items?}.
  #
  # An array attribute (`{:array, :string}`) carries `kind: :array` with `module:
  # nil` and its real value type under `item_type` — so reading `type.module`
  # directly yields nil and String-guesses the whole attribute (issue #78).
  # Unwrapping here means every attribute consumer downstream sees one shape: the
  # element's manifest type plus the two array facts that change the emitted Swift.
  #
  # The two nullabilities are deliberately distinct and must not be conflated: the
  # field's own `allow_nil?` says whether the *array* may be nil, while the array
  # type's `nil_items?` constraint says whether its *elements* may be nil —
  # `[String]?` vs `[String?]`. Ash defaults `nil_items?` to false, so an element
  # is non-optional unless the resource explicitly opted in.
  defp unwrap_array(%{kind: :array, item_type: %{} = item} = type) do
    nil_items? = Keyword.get(type.constraints || [], :nil_items?, false) == true
    {item, true, nil_items?}
  end

  defp unwrap_array(type), do: {type, false, false}

  # The Swift type for one attribute, plus the Swift enum it generates (or nil).
  # Returns `:unsupported` when the attribute maps to no Swift type at all.
  #
  # An enum attribute takes its generated Swift enum name; everything else maps
  # its Ash type module. An array attribute maps its *element* that way and wraps
  # the result in `[...]`, making the element itself optional when the array
  # permits nil members.
  #
  # A manifest type with no module has no Ash type to map at all — a nested array
  # is the case that reaches here, since Ash resolves the inner `{:array, _}` to a
  # `kind: :array` type with `module: nil`. `TypeMap.ash_type_to_swift/1` would
  # String-guess it, which is the silent decode-breaking mis-type of issue #78, so
  # it is refused here instead. This mirrors the gate `emit_derived_fields/5` and
  # `TypeMap.generic_swift_type/1` already apply on their own nil-module types.
  #
  # The gate is deliberately nil-module-only. A type that carries a module but has
  # no explicit mapping keeps the existing `ash_type_to_swift/1` String fallback so
  # custom types (e.g. an `Ash.Type.NewType`) are not regressed by this change.
  # Tuples and unions fall in that group, not this one: Ash's `TypeResolver` sets
  # `module: Ash.Type.Tuple` / `module: Ash.Type.Union`, so they take the
  # module-bearing branch below and are still emitted as `String`.
  defp attribute_swift_type(attr, formatted_name, type_name, resource) do
    element =
      case TypeMap.extract_enum_cases(attr) do
        {:ok, cases} ->
          enum_name = enum_type_name(type_name, formatted_name)
          {:ok, enum_name, %{enum_name: enum_name, cases: check_enum_cases!(cases, resource)}}

        :not_enum ->
          case attr.value_type do
            %{module: nil} -> :unsupported
            %{module: module} -> {:ok, TypeMap.ash_type_to_swift(module), nil}
          end
      end

    case element do
      {:ok, swift, enum} -> {:ok, wrap_array(swift, attr), enum}
      :unsupported -> :unsupported
    end
  end

  defp wrap_array(swift, %{array?: false}), do: swift
  defp wrap_array(swift, %{array?: true, nil_items?: true}), do: "[#{swift}?]"
  defp wrap_array(swift, %{array?: true}), do: "[#{swift}]"

  # An attribute whose type maps to no Swift type is omitted from the generated
  # output rather than String-guessed. Omission is the safe failure mode: a
  # missing property is a compile error at the consumer's use site, whereas a
  # wrong-typed one compiles and then throws `typeMismatch` at decode time on
  # device — the exact shape of issue #78.
  defp warn_unsupported_attribute(attr, resource) do
    what =
      if attr.array?,
        do: "is an array whose element type (#{inspect(attr.value_type.kind)})",
        else: "has a type (#{inspect(attr.value_type.kind)}) that"

    Logger.warning(
      "AshSwift: attribute #{inspect(resource)}.#{attr.name} #{what} maps to no Swift type; " <>
        "omitting it from the generated output. Open an issue if you need this type supported."
    )
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
    |> Enum.flat_map(fn domain ->
      # `RpcInfo.typescript_rpc/1` entries are `AshTypescript.Rpc.Resource` structs
      # (a fixed defstruct), so the owning domain can't be stashed onto them with
      # `Map.put/3` — it's paired alongside instead, and unpacked in the very next
      # step. This is how `domain` (ADR-0009: read off the IR, never
      # `Ash.Resource.Info.domain/1`) reaches the resource map below.
      domain
      |> RpcInfo.typescript_rpc()
      |> Enum.map(&{domain, &1})
    end)
    |> Enum.map(fn {domain, %{resource: resource, rpc_actions: rpc_actions}} ->
      type_name =
        resource
        |> ResourceInfo.typescript_type_name!()
        |> assert_swift_identifier!("type_name", resource)

      mres = Map.fetch!(manifest.resources, resource)
      {fields, enums} = collect_fields(mres, type_name, manifest.types, manifest.resources)
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
          # Swift sees the lower-camelled `func` name and the pascal-cased
          # `{Rpc}Input`/`{Rpc}Result` struct names, both rooted in the same first
          # non-empty segment, so validating the lower-camel form covers all three.
          rpc_action.name
          |> Naming.lower_camel()
          |> assert_swift_identifier!("rpc_action name", resource)

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
              manifest.resources,
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
        domain,
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
    ash_facts = ash_action_facts(resource, maction)

    get =
      if maction.type == :read do
        build_get_info(maction, rpc_action, resource, formatter, ash_facts.get_by)
      end

    list_read? = maction.type == :read and is_nil(get)

    # A get returns a single record, so it is never paginated: `:none` for gets
    # (the Emitter's get clause asserts this rather than re-deciding it, and
    # `Contract.optional_pagination/2` relies on it too).
    pagination_type =
      if list_read? do
        action_pagination_type(maction)
      else
        :none
      end

    # Optional pagination (required?: false but offset?/keyset? supported) on a
    # list read. These don't change the bare `[T]` function; they gain a second,
    # *overloaded* paginated function (see method_specs/2). Get actions and
    # required-pagination actions are excluded — :none means "no overload".
    optional_pagination_type =
      if list_read? do
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
    sortable? = list_read? and sort_enabled?(rpc_action) and has_sortable_fields?

    # Filtering is offered on the same surface as sorting — list (non-get)
    # read actions whose RPC action leaves `enable_filter?` at its default
    # of true. A false flag drops the filter: parameter so a forbidden
    # filter is a compile error, not a silently-ignored argument.
    filterable? = list_read? and filter_enabled?(rpc_action)

    # A create addresses no existing record, so it has no identity params. A
    # primary key the caller supplies arrives through the accepted input fields
    # like any other attribute.
    primary_key_params =
      if maction.type in [:update, :destroy],
        do: build_get_by_params(mres.primary_key, resource, formatter),
        else: []

    # The one source of an action's input struct. A read's declared arguments
    # (issue #87) exclude any native get_by fields — those are already the
    # get's lookup params, sent in the same `input` dict. A destroy's inputs
    # (issue #102) travel under `input` beside the `identity` naming the
    # record; they are its arguments, plus accepted attributes for a soft
    # destroy. Create and update always get a struct. Anything else has none.
    action_inputs =
      case maction.type do
        :read ->
          Enum.reject(maction.inputs, &(&1.name in ash_facts.get_by))

        type when type in [:create, :update, :destroy] ->
          maction.inputs

        _ ->
          []
      end

    {arg_inputs, arg_nested_structs} =
      if action_inputs == [] and maction.type not in [:create, :update] do
        {[], []}
      else
        collect_action_inputs(
          %{maction | inputs: action_inputs},
          rpc_action,
          mres,
          type_name,
          formatter,
          types,
          ash_facts
        )
      end

    has_input_struct? = maction.type in [:create, :update] or arg_inputs != []
    input_struct_name = if has_input_struct?, do: pascal_case(rpc_action.name) <> "Input"

    input_required? =
      maction.type in [:read, :destroy] and Enum.any?(arg_inputs, & &1.required?)

    action = %{
      rpc_name: rpc_action.name,
      action: rpc_action.action,
      action_type: maction.type,
      get: get,
      not_found_error?: not_found_error?,
      input_struct_name: input_struct_name,
      # Read and destroy actions: whether the `input:` parameter is required (some
      # input must be supplied: an argument, or an accepted attribute a soft
      # destroy lists in `require_attributes`) or an optional `= nil` (issues #87, #102).
      input_required?: input_required?,
      primary_key_params: primary_key_params,
      pagination_type: pagination_type,
      optional_pagination_type: optional_pagination_type,
      sortable?: sortable?,
      filterable?: filterable?
    }

    new_struct =
      if has_input_struct? do
        [%{struct_name: input_struct_name, fields: arg_inputs} | arg_nested_structs]
      else
        []
      end

    {[action | actions_acc], new_struct ++ structs_acc}
  end

  # Per-action collector for generic (`:action`-type) actions (#54). Inputs are
  # action *arguments* mapped straight from their manifest type (not resource
  # attributes); the return is classified by generic_action_return/6. An action
  # whose return is an unmapped shape is skipped with a
  # warning rather than emitted with a wrong decode — the accumulator passes
  # through unchanged.
  defp collect_generic_action(
         maction,
         rpc_action,
         resource,
         formatter,
         manifest_resources,
         {actions_acc, structs_acc} = acc
       ) do
    with {gen_return, result_structs, return_resource} <-
           generic_action_return(
             maction.returns,
             rpc_action.name,
             resource,
             formatter,
             manifest_resources,
             ash_action_facts(resource, maction).allow_nil?
           ),
         {:ok, inputs, nested_structs} <-
           collect_generic_action_inputs(maction, rpc_action, resource, formatter) do
      input_struct_name = if inputs == [], do: nil, else: pascal_case(rpc_action.name) <> "Input"

      action = %{
        rpc_name: rpc_action.name,
        action: rpc_action.action,
        action_type: :action,
        get: nil,
        not_found_error?: false,
        input_struct_name: input_struct_name,
        primary_key_params: [],
        pagination_type: :none,
        optional_pagination_type: :none,
        sortable?: false,
        filterable?: false,
        generic_return: gen_return,
        generic_return_resource: return_resource
      }

      # The action's own input struct plus any nested structs its array-of-record
      # arguments generated (e.g. `UploadStartClipsItem` for a `clips` argument),
      # plus any structs the typed-`:map` return generated (e.g. `UploadStartResult`
      # and a nested `UploadStartResultClipsItem` — see generic_action_return/6).
      input_structs =
        if input_struct_name,
          do: [%{struct_name: input_struct_name, fields: inputs} | nested_structs],
          else: nested_structs

      {[action | actions_acc], input_structs ++ result_structs ++ structs_acc}
    else
      # A return that maps to no supported Swift type, or an argument
      # of an unmappable type (e.g. a list/array arg) — skip the whole action with
      # a warning rather than emit a wrong decode or a String-guessed input field.
      :unsupported ->
        warn_skip_generic(
          maction,
          "returns #{inspect(maction.returns && maction.returns.kind)}, which maps to no " <>
            "supported Swift return type"
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
      "AshSwift: generic action #{inspect(maction.name)} #{reason}; skipping. Unmapped " <>
        "generic-action shapes (array-of-resource returns, " <>
        "unmappable arguments) are out of scope for the generic-action slices (#54, #56)."
    )
  end

  # Maps a generic action's arguments to input-struct fields. Unlike create/update
  # inputs (resolved against resource attributes), a generic action's inputs are
  # action arguments carrying their own manifest type. A scalar or map argument
  # maps directly via TypeMap.generic_swift_type/1; an **array** argument maps its
  # element type — an array of a scalar becomes `[Scalar]`, an array of a
  # constrained map (a typed record, e.g. `clips`) becomes `[ActionArgItem]` plus a
  # generated nested input struct. Optionality comes from `input.required?`. If ANY
  # argument has an unmappable type (an unconstrained array element, struct, …) the
  # whole action is unsupported — returning {:unsupported, name} so the caller skips
  # it, symmetric with the return-type gate. Otherwise returns {:ok, fields,
  # nested_structs} with fields sorted by name.
  defp collect_generic_action_inputs(maction, rpc_action, resource, formatter) do
    maction.inputs
    |> Enum.reduce_while({:ok, [], []}, fn input, {:ok, fields_acc, structs_acc} ->
      case generic_field_swift_type(
             input.type,
             pascal_case(rpc_action.name),
             input.name,
             resource,
             formatter
           ) do
        {:ok, swift_type, nested_structs} ->
          field = %{
            name: format_name!(input.name, resource, formatter),
            swift_type: swift_type,
            required?: input.required?
          }

          # Accumulation order of nested_structs doesn't matter: collect_query_surface
          # sorts all input_structs by struct name, so output stays deterministic.
          {:cont, {:ok, [field | fields_acc], nested_structs ++ structs_acc}}

        :unsupported ->
          {:halt, {:unsupported, input.name}}
      end
    end)
    |> case do
      {:ok, fields, structs} -> {:ok, Enum.sort_by(fields, & &1.name), structs}
      unsupported -> unsupported
    end
  end

  # The Swift type for one generic-action field — an argument (input side) or a
  # typed-`:map` return's field (output side) — plus any nested structs it
  # generates. `name_prefix` is the already-pascal-cased struct-name root
  # (`UploadStart` for an argument, `UploadStartResult` for a return field), which
  # keeps an argument's and a return's nested struct names distinct even when both
  # carry a `clips` array (no `UploadStartClipsItem` collision). Arrays map their
  # element type; everything else defers to TypeMap.generic_swift_type/1 (scalar →
  # its Swift type, map → `[String: AshJSON]`).
  defp generic_field_swift_type(
         %{kind: :array, item_type: item},
         name_prefix,
         field_name,
         resource,
         formatter
       )
       when not is_nil(item) do
    case item do
      # An array of a constrained map = a typed record list. Generate a named nested
      # struct (e.g. `UploadStartClipsItem` / `UploadStartResultClipsItem`) so the
      # element is compiler-checked rather than an untyped `[[String: AshJSON]]`.
      %{kind: :map, fields: item_fields} when is_list(item_fields) and item_fields != [] ->
        case collect_record_struct_fields(item_fields, resource, formatter) do
          {:ok, struct_fields} ->
            # Built from the raw field atom (not the formatted client name), which
            # `field_names` can map to a clean name while the raw one stays hostile,
            # so the derived struct name is checked on its own (#142).
            struct_name =
              assert_swift_identifier!(
                name_prefix <> pascal_case(field_name) <> "Item",
                "struct name",
                resource
              )

            {:ok, "[#{struct_name}]", [%{struct_name: struct_name, fields: struct_fields}]}

          :unsupported ->
            :unsupported
        end

      # An array of a scalar (or an unconstrained map) maps element-wise.
      element ->
        case TypeMap.generic_swift_type(element) do
          {:ok, swift} -> {:ok, "[#{swift}]", []}
          :unsupported -> :unsupported
        end
    end
  end

  defp generic_field_swift_type(type, _name_prefix, _field_name, _resource, _formatter) do
    case TypeMap.generic_swift_type(type) do
      {:ok, swift} -> {:ok, swift, []}
      :unsupported -> :unsupported
    end
  end

  # The fields of a generated nested record struct (an array-of-map argument's
  # element). Each field maps via TypeMap.generic_swift_type/1; a field is required
  # only when `allow_nil?` is explicitly `false` — map-constraint fields are
  # nullable by default, so an unset (`nil`) `allow_nil?` is an optional Swift
  # property, not a required one. Any unmappable field type makes the whole element
  # — and so the action — unsupported.
  defp collect_record_struct_fields(fields, resource, formatter) do
    fields
    |> Enum.reduce_while({:ok, []}, fn field, {:ok, acc} ->
      case TypeMap.generic_swift_type(field.type) do
        {:ok, swift} ->
          struct_field = %{
            name: format_name!(field.name, resource, formatter),
            swift_type: swift,
            required?: field.allow_nil? == false
          }

          {:cont, {:ok, [struct_field | acc]}}

        :unsupported ->
          {:halt, :unsupported}
      end
    end)
    |> case do
      {:ok, struct_fields} -> {:ok, Enum.sort_by(struct_fields, & &1.name)}
      :unsupported -> :unsupported
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
         domain,
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
      domain: domain,
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
      format_name!(attr.name, mres.module, formatter)
    end)
    |> Enum.sort()
  end

  # Whether the backend can order a read by this attribute. Enum attributes and
  # comparable scalars (the types that map to String/Bool/Int/Double/Date) are
  # sortable; composite types like `Ash.Type.Map` (a JSON object → `[String:
  # AshJSON]`) are not — Ash returns an error when asked to sort by them, so
  # emitting them as typed sort fields would be a runtime footgun with no valid
  # use. Relationship/aggregate/calculation sorting stays out of scope for M2.
  #
  # An array is likewise not orderable, and is excluded on its own clause rather
  # than left to the Swift-type check below: an array of a sortable scalar maps to
  # `[String]`, which is absent from @sortable_swift_types today but would silently
  # become sortable if that set ever grew a collection type (issue #78).
  defp sortable_attribute?(%{array?: true}), do: false

  defp sortable_attribute?(attr) do
    case TypeMap.extract_enum_cases(attr) do
      {:ok, _} ->
        true

      :not_enum ->
        case attr.ash_type do
          nil -> false
          module -> MapSet.member?(@sortable_swift_types, TypeMap.ash_type_to_swift(module))
        end
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
  #
  # Array attributes are excluded outright, alongside the composite types: the
  # operator generics describe scalar predicates (`eq`/`in` over a single value),
  # not the array predicates (`contains`, `has_any`) an array field would need, so
  # an emitted `EnumOperators<String>` over an `{:array, :string}` would be a
  # request the backend rejects (issue #78).
  defp filter_field(attr, resource, type_name, formatter) do
    name = format_name!(attr.name, resource, formatter)

    {group, value_type} =
      if attr.array? do
        {:exclude, nil}
      else
        case attribute_swift_type(attr, name, type_name, resource) do
          {:ok, swift_type, nil} -> {TypeMap.scalar_filter_group(attr.ash_type), swift_type}
          {:ok, enum_name, _enum} -> {:enum, enum_name}
          :unsupported -> {:exclude, nil}
        end
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
  # fields: sorted list of %{name, swift_type, destination} for public scalar
  # attributes and public relationships whose destination passes
  # model_struct_target/2 (`destination` is the destination module for a
  # relationship field, nil otherwise; see the moduledoc's Field section). Field
  # names go through the same formatter AshTypescript uses for output. Enum
  # attributes produce a generated Swift enum type name instead of the default
  # "String" fallback.
  #
  # enums: sorted list of %{enum_name, cases} for each attribute whose Ash type
  # is an enum (Ash.Type.Atom with one_of constraint, or Ash.Type.Enum subtype).
  defp collect_fields(mres, type_name, types, manifest_resources) do
    formatter = AshTypescript.output_field_formatter() || :camel_case
    resource = mres.module

    {attr_fields, enums} =
      mres
      |> manifest_attributes(types)
      |> Enum.reduce({[], []}, fn attr, {fields_acc, enums_acc} ->
        formatted_name = format_name!(attr.name, resource, formatter)

        case attribute_swift_type(attr, formatted_name, type_name, resource) do
          {:ok, swift_type, nil} ->
            {[%{name: formatted_name, swift_type: swift_type, destination: nil} | fields_acc],
             enums_acc}

          {:ok, swift_type, enum} ->
            {[%{name: formatted_name, swift_type: swift_type, destination: nil} | fields_acc],
             [enum | enums_acc]}

          :unsupported ->
            # The one place an unmappable attribute is reported: the other consumers
            # (filter, sort, action inputs) drop it through the same gate and would
            # only repeat this warning per action.
            warn_unsupported_attribute(attr, resource)
            {fields_acc, enums_acc}
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
        # `:none` is defensive and, as far as the manifest is concerned,
        # unreachable in practice (the manifest lists a relationship's
        # destination as a resource). It exists so every caller shares one
        # predicate, and it drops (rather than emits) a field whose struct would
        # never be generated.
        case model_struct_target(rel.destination, manifest_resources) do
          {:ok, dest_type, _dest_mres} ->
            swift_type =
              case rel.cardinality do
                :one -> dest_type
                :many -> "[#{dest_type}]"
              end

            name = format_name!(rel.name, resource, formatter)
            [%{name: name, swift_type: swift_type, destination: rel.destination}]

          :none ->
            []
        end
      end)

    fields =
      (attr_fields ++ agg_fields ++ calc_fields ++ rel_fields) |> Enum.sort_by(& &1.name)

    sorted_enums = (enums ++ agg_enums ++ calc_enums) |> Enum.sort_by(& &1.enum_name)
    {fields, sorted_enums}
  end

  # Classifies a generic action's return, returning `{gen_return, structs}` on
  # success (or bare `:unsupported` on failure, so the caller's `with` skips the
  # whole action):
  #
  #   * `nil`                       -> {:void, []}        (a side-effecting action)
  #   * a **constrained** `:map`    -> {{:typed_record, "<Rpc>Result"}, [result struct | nested]}
  #     (a `:map` carrying `fields:` constraints, e.g. SwingClips' upload_start
  #     manifest) — generate a typed Decodable struct so the caller gets
  #     `UploadStartResult { videoId, clips: [UploadStartResultClipsItem] }` instead
  #     of an untyped `[String: AshJSON]`. An `{:array, :map}` field rides the same
  #     nested-struct machinery as an array-of-record argument (issue #70). Tagged
  #     `:typed_record` (not `:typed`) because the RPC pipeline requires a `fields:`
  #     selection for it, so the emitter threads a `fields:` argument (issue #73).
  #   * an **unconstrained** `:map` -> {{:typed, "[String: AshJSON]"}, []}
  #     (no `fields:` — the action opted out of typing, keys are the caller's)
  #   * a scalar                    -> {{:typed, t}, []}
  #   * a **resource** / `:struct` with `instance_of` a resource -> {{:typed_record, "T"}, [], module}
  #     (issue #56). Decoded into the resource's generated model type through the
  #     same field-selected path as the typed map. The manifest drops the action's
  #     `allow_nil?` (Ash default false: a nil return is rejected unless the action
  #     sets `allow_nil? true`), so ash_action_facts/2 supplies it: the type is
  #     `"T?"` only when the action allows nil, else a non-optional `"T"`. The
  #     target must have a type name and be present in the manifest (see
  #     model_struct_target/2), else the model struct would never be emitted —
  #     then :unsupported. The third element is the target module, so
  #     expand_with_related/2 can emit its model struct.
  #   * anything else               -> :unsupported (array-of-resource returns
  #     included)
  #
  # Every supported clause returns {gen_return, result_structs, target_module | nil}.
  defp generic_action_return(nil, _rpc_name, _resource, _formatter, _manifest_resources, _nil?),
    do: {:void, [], nil}

  defp generic_action_return(
         %{kind: :resource, resource_module: module},
         _rpc_name,
         _resource,
         _formatter,
         manifest_resources,
         allow_nil?
       )
       when not is_nil(module) do
    case model_struct_target(module, manifest_resources) do
      {:ok, type_name, _mres} ->
        swift_type = if allow_nil?, do: type_name <> "?", else: type_name
        {{:typed_record, swift_type}, [], module}

      :none ->
        :unsupported
    end
  end

  defp generic_action_return(
         %{kind: :map, fields: fields},
         rpc_name,
         resource,
         formatter,
         _manifest_resources,
         _allow_nil?
       )
       when is_list(fields) and fields != [] do
    result_struct_name = pascal_case(rpc_name) <> "Result"

    case collect_result_struct_fields(fields, result_struct_name, resource, formatter) do
      {:ok, struct_fields, nested_structs} ->
        result_struct = %{
          struct_name: result_struct_name,
          fields: struct_fields,
          decodable?: true
        }

        # `:typed_record` (not `:typed`) so the emitter knows this return is a
        # field-selectable typed struct: the RPC pipeline requires a `fields:`
        # selection for it (issue #73), unlike a scalar or untyped-map return.
        {{:typed_record, result_struct_name}, [result_struct | nested_structs], nil}

      :unsupported ->
        :unsupported
    end
  end

  defp generic_action_return(type, _rpc_name, _resource, _formatter, _manifest_resources, _nil?) do
    case TypeMap.generic_swift_type(type) do
      {:ok, swift_type} -> {{:typed, swift_type}, [], nil}
      :unsupported -> :unsupported
    end
  end

  # Names that flow into Swift identifier / type positions unquoted (resource
  # `type_name`, rpc action names) must be plain identifiers, or a hostile value
  # (`}`, a newline, a quote) could inject Swift declarations into the generated
  # client (#142). Checked here, at Reader time, so the Emitter can trust them.
  @swift_identifier ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  defp assert_swift_identifier!(name, what, resource) do
    if Regex.match?(@swift_identifier, name) do
      name
    else
      Mix.raise(
        "AshSwift codegen: #{what} #{inspect(name)} on #{inspect(resource)} is not a valid " <>
          "Swift identifier (must match #{inspect(@swift_identifier.source)}). " <>
          "Rename it so the generated client compiles."
      )
    end
  end

  # The Emitter's fixed top-level client struct; it owns this name like any resource.
  @client_struct_name "AshRpc"

  @doc false
  def client_struct_name, do: @client_struct_name

  # The single "one generated Swift name, one owner" rule (#156, #164). Collects
  # every top-level Swift name the IR will make the Emitter declare — resource
  # structs, enums, `{Type}Filter` structs, `{Type}SortField` enums and input /
  # result structs — each paired with what owns it (a resource module and the
  # kind of declaration), and raises on any name with more than one owner. Two
  # declarations of one name would otherwise not compile (or, for two resource
  # modules sharing a type name, silently share one struct). Entries are the
  # primary resources plus the related ones, which only carry a model struct and
  # enums; each module appears once (`expand_with_related/2` keys related
  # entries by module), so a name that occurs twice is a real collision, even
  # when both occurrences come from the same resource (two actions or fields
  # deriving the same struct name). The Emitter's fixed `client_struct_name/0`
  # (`AshRpc`) is seeded as one more owner, so no resource may declare it.
  defp assert_unique_swift_names!(resources) do
    collisions =
      [
        {@client_struct_name, "AshSwift generated client"}
        | Enum.flat_map(resources, &swift_name_owners/1)
      ]
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.filter(fn {_name, owners} -> length(owners) > 1 end)
      |> Enum.sort()

    unless collisions == [] do
      detail =
        Enum.map_join(collisions, "; ", fn {name, owners} ->
          "\"#{name}\" (#{Enum.join(Enum.sort(owners), ", ")})"
        end)

      Mix.raise(
        "AshSwift codegen: generated Swift type names are not unique: #{detail} — " <>
          "give each resource a distinct `type_name` in its `typescript do ... end` block, " <>
          "or rename the field or action that generates the clashing name."
      )
    end
  end

  # `{name, owner}` for every top-level Swift name one resource entry declares.
  defp swift_name_owners(%{resource_module: module, type_name: type_name} = resource) do
    owner = fn kind -> "#{inspect(module)} #{kind}" end

    [{type_name, owner.("struct")}] ++
      Enum.map(Map.get(resource, :enums, []), &{&1.enum_name, owner.("enum")}) ++
      Enum.map(Map.get(resource, :input_structs, []), fn struct ->
        {struct.struct_name,
         owner.(if Map.get(struct, :decodable?, false), do: "result struct", else: "input struct")}
      end) ++
      for(%{type_name: name} <- [resource[:sort_field]], do: {name, owner.("sort field")}) ++
      for(%{type_name: name} <- [resource[:filter_struct]], do: {name, owner.("filter")})
  end

  # `FieldFormatter.format_field_for_client/3` with the identifier check applied.
  # Every client-facing field/argument name the Reader emits goes through here, so
  # the derived names built from it (enum, struct, filter, sort types) are
  # identifiers by construction (#142).
  defp format_name!(name, resource, formatter) do
    name
    |> FieldFormatter.format_field_for_client(resource, formatter)
    |> to_string()
    |> assert_swift_identifier!("field name", resource)
  end

  # Enum cases are emitted as `case <lowerCamel(value)>`, so the lower-camelled
  # value must itself be an identifier (the raw value is emitted via
  # `Emitter.swift_string/1`, which escapes it).
  # Returns the IR shape `%{name, raw}`: `name` is the validated Swift case name,
  # `raw` the wire string, or nil when it equals `name` (no explicit raw value
  # needed). The Emitter only renders this.
  defp check_enum_cases!(cases, resource) do
    Enum.map(cases, fn c ->
      raw = to_string(c)

      name =
        raw
        |> Naming.lower_camel()
        |> assert_swift_identifier!("enum value", resource)

      %{name: name, raw: if(name == raw, do: nil, else: raw)}
    end)
  end

  # `ResourceInfo.typescript_type_name/1` with the identifier check applied.
  defp checked_type_name(module) do
    case ResourceInfo.typescript_type_name(module) do
      {:ok, name} -> {:ok, assert_swift_identifier!(name, "type_name", module)}
      other -> other
    end
  end

  # The single predicate for "this resource's model struct can be referenced":
  # it has a Swift type name and is present in the manifest. Returns
  # `{:ok, type_name, manifest_resource}` or `:none`. Shared by the
  # generic-return gate, expand_with_related/2 and collect_fields/4's
  # relationship fields so they can't drift; any new feature that references a
  # resource type should go through it too. (The 2-hop guard does not re-run it:
  # relationship fields were already filtered through it in collect_fields/4.)
  defp model_struct_target(module, manifest_resources) do
    with {:ok, type_name} <- checked_type_name(module),
         {:ok, mres} <- Map.fetch(manifest_resources, module) do
      {:ok, type_name, mres}
    else
      _ -> :none
    end
  end

  # The fields of a typed-`:map` return struct, plus any nested structs an
  # `{:array, :map}` field generated. Symmetric with collect_generic_action_inputs/4
  # but for the return side: each field maps via generic_field_swift_type/5 (so an
  # array-of-constrained-map field becomes `[<Result><Field>Item]` + a nested
  # struct, an array-of-scalar `[Scalar]`, a plain map `[String: AshJSON]`), and a
  # field's optionality is its `allow_nil?` — required only when explicitly `false`,
  # matching the map-constraint nullable-by-default rule (collect_record_struct_fields).
  # The generated structs are tagged `decodable?: true` so the emitter renders them
  # as Decodable result structs, not Encodable input structs. Any unmappable field
  # makes the whole return — and so the action — unsupported.
  defp collect_result_struct_fields(fields, name_prefix, resource, formatter) do
    fields
    |> Enum.reduce_while({:ok, [], []}, fn field, {:ok, fields_acc, structs_acc} ->
      case generic_field_swift_type(field.type, name_prefix, field.name, resource, formatter) do
        {:ok, swift_type, nested_structs} ->
          struct_field = %{
            name: format_name!(field.name, resource, formatter),
            swift_type: swift_type,
            required?: field.allow_nil? == false
          }

          decodable = Enum.map(nested_structs, &Map.put(&1, :decodable?, true))
          {:cont, {:ok, [struct_field | fields_acc], decodable ++ structs_acc}}

        :unsupported ->
          {:halt, :unsupported}
      end
    end)
    |> case do
      {:ok, struct_fields, structs} -> {:ok, Enum.sort_by(struct_fields, & &1.name), structs}
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
  # {fields, enums} in the shape collect_fields/4 expects, mirroring its attribute
  # reduce: an enum-typed field produces a generated Swift enum plus a typed field;
  # a scalar field maps through TypeMap.ash_type_to_swift; anything else is skipped
  # (see TypeMap.derived_scalar_kinds/0).
  defp emit_derived_fields(fields, type_name, resource, formatter, types) do
    Enum.reduce(fields, {[], []}, fn field, {fields_acc, enums_acc} ->
      formatted_name = format_name!(field.name, resource, formatter)

      case manifest_enum_values(field.type, types) do
        values when is_list(values) ->
          en_name = enum_type_name(type_name, formatted_name)
          enum = %{enum_name: en_name, cases: check_enum_cases!(values, resource)}

          {[%{name: formatted_name, swift_type: en_name, destination: nil} | fields_acc],
           [enum | enums_acc]}

        nil ->
          # Guard on a concrete module too: the gate's intent is skip-when-uncertain,
          # and TypeMap.ash_type_to_swift/1 String-fallbacks an unknown/nil module — exactly
          # the silent mis-decode this gate exists to prevent. Ash populates module
          # for standard scalars, so this only excludes genuinely unresolvable types.
          if field.type.kind in TypeMap.derived_scalar_kinds() and not is_nil(field.type.module) do
            field_map = %{
              name: formatted_name,
              swift_type: TypeMap.ash_type_to_swift(field.type.module),
              destination: nil
            }

            {[field_map | fields_acc], enums_acc}
          else
            {fields_acc, enums_acc}
          end
      end
    end)
  end

  # Augments the primary resource list with any related resources referenced by
  # their relationships, or by a generic action's resource return (#56), that
  # aren't already in the primary set. The related resource's struct must be in
  # the types file so the nested field decodes correctly. Only one hop of
  # relationship expansion is performed for M1.
  #
  # Related entries share the same map shape as primary entries (resource_module:
  # nil, actions: []) so render_types and render_functions always see uniform
  # maps regardless of which list they iterate.
  #
  # 2-hop guard: a related resource's own relationship fields may point to
  # resources whose model struct is never emitted (2 hops away). Those fields
  # are dropped so the generated Swift compiles without undefined-type
  # references. The decision checks the `destination:` recorded on each
  # relationship field against the set of emitted modules, not the rendered Swift
  # type; every other field (scalar, enum) is always safe.
  defp expand_with_related(primary_resources, manifest) do
    primary_modules = MapSet.new(primary_resources, & &1.resource_module)

    related_candidates =
      primary_resources
      |> Enum.flat_map(fn %{resource_module: resource, actions: actions} ->
        # One hop out: relationship destinations, plus the target of any generic
        # action's resource/struct return (#56) — its model struct must exist for
        # the function's return type to compile.
        relationship_destinations =
          manifest.resources
          |> Map.fetch!(resource)
          |> ManifestResource.all_relationships()
          |> Enum.map(& &1.destination)

        return_targets =
          actions |> Enum.map(& &1[:generic_return_resource]) |> Enum.reject(&is_nil/1)

        Enum.flat_map(relationship_destinations ++ return_targets, fn destination ->
          # Skip when the destination has no Swift type name (or isn't in the
          # manifest; model_struct_target/2 checks both). This pass is cheap and
          # side-effect free: fields are collected (and unsupported attributes
          # warned about) only for the survivors below, once per module.
          case model_struct_target(destination, manifest.resources) do
            {:ok, type_name, dest_mres} ->
              [%{resource_module: destination, type_name: type_name, mres: dest_mres}]

            _ ->
              []
          end
        end)
      end)
      |> Enum.uniq_by(& &1.resource_module)

    related_raw =
      related_candidates
      |> Enum.reject(&MapSet.member?(primary_modules, &1.resource_module))
      |> Enum.map(fn %{resource_module: module, type_name: type_name, mres: mres} ->
        {fields, enums} = collect_fields(mres, type_name, manifest.types, manifest.resources)
        %{resource_module: module, type_name: type_name, fields: fields, enums: enums}
      end)

    emitted_modules =
      MapSet.union(primary_modules, MapSet.new(related_raw, & &1.resource_module))

    assert_unique_swift_names!(primary_resources ++ related_raw)

    related =
      Enum.map(related_raw, fn %{type_name: type_name, fields: fields, enums: enums} ->
        safe_fields =
          Enum.filter(fields, &referenceable_field?(&1, emitted_modules))

        %{
          resource_module: nil,
          domain: nil,
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

  # The 2-hop guard's per-field test. A relationship field (it carries
  # `destination:`, already vetted by model_struct_target/2 in collect_fields/4)
  # is kept only when that resource's module is among the emitted ones. Every
  # other field (`destination: nil`) is built-in or an enum defined in this file,
  # so it is kept. No catch-all: a field built without the key crashes here rather
  # than slipping an unemitted type reference past the guard.
  defp referenceable_field?(%{destination: nil}, _emitted_modules), do: true

  defp referenceable_field?(%{destination: module}, emitted_modules),
    do: MapSet.member?(emitted_modules, module)

  # Determines whether a read action is a get action and, if so, collects the
  # lookup field params and where to place them in the request body.
  #
  # Returns the action's `get` IR value:
  #   - `{:input, params}` — native get_by on the action; params is a list of
  #     %{name, swift_type} for the lookup fields
  #   - `{:get_by, params}` — RPC-level get_by
  #   - `:pure` — pure get? (no lookup channel; the action narrows itself
  #     through its own arguments)
  #   - `nil` — not a get
  defp build_get_info(maction, rpc_action, resource, formatter, native_get_by) do
    # The native get_by fields come from the Ash action facts (see
    # ash_action_facts/2). A pure `get?` action has no get_by and takes no lookup
    # params.
    rpc_get_by = Map.get(rpc_action, :get_by) || []
    rpc_get? = Map.get(rpc_action, :get?, false)

    cond do
      native_get_by != [] ->
        # get_by on the Ash action itself: fields travel in the `input` body key.
        {:input, build_get_by_params(native_get_by, resource, formatter)}

      rpc_get_by != [] ->
        # get_by on the RPC action entity: fields travel in the `getBy` body key.
        {:get_by, build_get_by_params(rpc_get_by, resource, formatter)}

      rpc_get? || maction.get? ->
        # Pure get? (no get_by anywhere): the RPC pipeline never reads a
        # top-level `identity` for a read (only update/destroy consume it), so
        # sending a pk would be silently dropped. The action narrows itself
        # through its own arguments (declared as `input:`), so there is no
        # lookup parameter. See issue #91.
        :pure

      true ->
        nil
    end
  end

  # Maps a list of field atoms to the %{name, swift_type} shapes method_spec uses.
  defp build_get_by_params(fields, resource, formatter) do
    Enum.map(fields, fn field ->
      name = format_name!(field, resource, formatter)
      %{name: name, swift_type: "String"}
    end)
  end

  # Collects the input fields for a create or update action, mapping each to its
  # Swift type and whether it is required. Returns {fields, nested_structs}.
  #
  # The manifest normalizes an action's inputs into one list holding both its
  # accepted attributes and its action *arguments* (issue #83), so each input is
  # routed by what it is:
  #
  #   * an action argument maps from its own manifest type through the same
  #     generic_field_swift_type/5 path generic actions use (scalar, map, array,
  #     array-of-record → nested `<Action><Arg>Item` struct), with optionality from
  #     the argument's `required?` presence flag — on update too, since a required
  #     argument must be supplied even though the update itself is partial. An
  #     argument of an unmappable type is omitted with a warning rather than
  #     String-guessed. Arguments are checked first: an argument named like a
  #     public attribute is still an argument on the wire, with the argument's type.
  #   * an accepted public attribute maps via attribute_swift_type/3.
  #     Optionality comes from the manifest's `input.required?` (it folds the
  #     action's `require_attributes` and `allow_nil_input`); update and destroy
  #     fields are otherwise optional (a partial operation). A create field is
  #     additionally optional when the attribute is nullable or has a default,
  #     matching ash_typescript even if `require_attributes` lists it.
  #   * anything else (an accepted non-public attribute) is omitted with a warning.
  defp collect_action_inputs(maction, rpc_action, mres, type_name, formatter, types, ash_facts) do
    resource = mres.module

    attrs_map =
      mres
      |> manifest_attributes(types)
      |> Map.new(fn attr -> {attr.name, attr} end)

    argument_names = ash_facts.argument_names

    {fields, structs} =
      Enum.reduce(maction.inputs, {[], []}, fn input, {fields_acc, structs_acc} ->
        formatted_name = format_name!(input.name, resource, formatter)

        cond do
          MapSet.member?(argument_names, input.name) ->
            case generic_field_swift_type(
                   input.type,
                   pascal_case(rpc_action.name),
                   input.name,
                   resource,
                   formatter
                 ) do
              {:ok, swift_type, nested_structs} ->
                field = %{
                  name: formatted_name,
                  swift_type: swift_type,
                  required?: input.required? == true
                }

                {[field | fields_acc], nested_structs ++ structs_acc}

              :unsupported ->
                Logger.warning(
                  "AshSwift: argument #{inspect(input.name)} of action #{inspect(maction.name)} " <>
                    "has a type that maps to no Swift type and will be omitted from the " <>
                    "generated input struct."
                )

                {fields_acc, structs_acc}
            end

          attr = Map.get(attrs_map, input.name) ->
            # Same gate as the model field: an attribute that maps to no Swift type is
            # omitted rather than String-guessed. collect_fields/4 has already warned
            # about it once for this resource, so this drop stays quiet.
            #
            # Unlike the model field, dropping here is only safe for an OPTIONAL
            # attribute: a required one (create: `input.required?`, which excludes
            # `allow_nil_input`, plus `allow_nil?: false` with no default; update / soft
            # destroy: `input.required?`, i.e. listed in `require_attributes`; see the
            # `required?` case below) still yields an input struct that compiles, and
            # the action then fails server-side at run time rather than at build time.
            # Tracked in issue #79.
            case attribute_swift_type(attr, formatted_name, type_name, resource) do
              {:ok, swift_type, _enum} ->
                required? =
                  case maction.type do
                    # The manifest folds `allow_nil_input` and `require_attributes`
                    # into `input.required?`. Parity with ash_typescript (#124): a
                    # nullable or defaulted attribute stays optional on create even
                    # when `require_attributes` lists it.
                    :create ->
                      input.required? == true and not attr.allow_nil? and not attr.has_default?

                    _update_or_destroy ->
                      input.required? == true
                  end

                field = %{name: formatted_name, swift_type: swift_type, required?: required?}
                {[field | fields_acc], structs_acc}

              :unsupported ->
                {fields_acc, structs_acc}
            end

          true ->
            Logger.warning(
              "AshSwift: input #{inspect(input.name)} of action #{inspect(maction.name)} " <>
                "is not a public attribute and will be omitted from the generated input struct."
            )

            {fields_acc, structs_acc}
        end
      end)

    # Nested-struct order doesn't matter: collect_query_surface sorts all
    # input_structs by struct name, so output stays deterministic.
    {Enum.sort_by(fields, & &1.name), structs}
  end

  # The one place the Reader reads a live Ash action (`Ash.Resource.Info.action/2`)
  # instead of the manifest. Looked up once per rpc action and passed to the
  # helpers that need it, so there is one lookup, one failure policy (raise) and one
  # comment to delete when the manifest grows the missing fields.
  #
  # Deliberate ADR-0009 deviation. `Ash.Info.Manifest.Action.inputs` merges
  # accepted attributes and arguments into one list of `Argument` structs with no
  # discriminator, and carries no `get_by` of its own, so the manifest alone can't
  # tell:
  #
  #   * `argument_names` — the action's PUBLIC argument names (exactly the argument
  #     entries the manifest puts in `inputs`; it drops private ones unless
  #     `include_private_arguments?`). An argument may share an attribute's name.
  #     Remove once the manifest carries a per-input source flag (e.g.
  #     `kind: :argument | :attribute`).
  #   * `get_by` — a read's native `get_by` field names (`get_by :id` surfaces as an
  #     ordinary `id` input mixed in with real arguments, issue #87); `[]` for a
  #     non-get read or a pure `get?`. Remove once the manifest carries `get_by`.
  #
  #   * `allow_nil?` — a generic action's `allow_nil?` (Ash default false: a nil
  #     return is rejected unless set). Decides `T` vs `T?` for a resource return
  #     (#56). Remove once the manifest carries action-level nullability.
  #
  # Fails loudly if the action can't be found rather than silently treating every
  # argument as an attribute.
  defp ash_action_facts(resource, maction) do
    case Ash.Resource.Info.action(resource, maction.name) do
      %{arguments: arguments} = action ->
        get_by =
          if maction.get?, do: action |> Map.get(:get_by) |> List.wrap(), else: []

        %{
          argument_names: arguments |> Enum.filter(& &1.public?) |> MapSet.new(& &1.name),
          get_by: get_by,
          allow_nil?: Map.get(action, :allow_nil?, false)
        }

      other ->
        raise "AshSwift: expected Ash.Resource.Info.action(#{inspect(resource)}, " <>
                "#{inspect(maction.name)}) to return an action with arguments, got: " <>
                inspect(other)
    end
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
