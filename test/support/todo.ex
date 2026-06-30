defmodule AshSwift.Test.Todo do
  @moduledoc "Fixture resource: a todo exercising the core CRUD action types."

  use Ash.Resource,
    domain: AshSwift.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("Todo")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :completed, :boolean, default: false, allow_nil?: false, public?: true
    attribute :priority, :atom, constraints: [one_of: [:low, :medium, :high]], public?: true
    attribute :status, AshSwift.Test.StatusType, public?: true
    attribute :score, :integer, public?: true
    attribute :default, :string, public?: true
    attribute :username, :ci_string, public?: true
    # Issue #17: extended type mappings
    attribute :deadline, :date, public?: true
    attribute :scheduled_at, :utc_datetime, public?: true
    attribute :due_at, :utc_datetime_usec, public?: true
    attribute :started_at, :naive_datetime, public?: true
    attribute :amount, :decimal, public?: true
    attribute :metadata, :map, public?: true
    # Private members: regression guard for codegen's public-only scope. The
    # manifest is built without include_private_*, so these must NOT appear in the
    # generated Swift. The golden snapshot (unchanged by their presence) proves it.
    attribute :internal_note, :string, public?: false
    timestamps()
  end

  relationships do
    belongs_to :user, AshSwift.Test.User, public?: true
    # Private relationship — must be excluded from the generated struct (see above).
    belongs_to :secret_owner, AshSwift.Test.User, public?: false
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    read :get_by_id do
      get_by :id
    end

    # A *pure* get? read: no get_by, so the manifest surfaces no lookup inputs
    # and the record is fetched by primary key. ash_typescript routes a pure
    # get? through the top-level `identity` param, not `input` (issue #66).
    read :fetch do
      get? true
    end

    read :get_by_score do
      get_by [:score]
    end

    read :list_offset_paginated do
      pagination offset?: true, required?: true, default_limit: 5, countable: true
    end

    read :list_keyset_paginated do
      pagination keyset?: true, required?: true, default_limit: 5
    end

    # Optional keyset pagination (issue #37): supports keyset but does not require
    # it. Exercises the keyset branch of the optional-pagination overload. The
    # explicit `offset?: false` is load-bearing: the default ETS `:read` enables
    # offset, and optional_action_pagination_type/1 matches `%{offset?: true}`
    # before `%{keyset?: true}`, so without it codegen would emit an OffsetPage
    # overload instead of the intended KeysetPage one.
    read :list_keyset_optional do
      pagination keyset?: true, offset?: false, required?: false
    end

    # Generic actions (issue #54): command-style `:action`-type actions whose
    # inputs are action *arguments* (not attributes) and whose return is either
    # nil (void) or a custom type. These exercise the generic-action codegen path.

    # Void return + a required argument — the canonical auth-bootstrap shape
    # (mirrors SwingClips' requestMagicLink(email)).
    action :request_magic_link do
      argument :email, :string, allow_nil?: false
      run fn _input, _ctx -> :ok end
    end

    # Scalar return + a required argument and an optional one — exercises both the
    # required (non-optional, plain encode) and optional (encodeIfPresent) branches
    # of the generated input struct.
    action :echo, :string do
      argument :message, :string, allow_nil?: false
      argument :loud, :boolean, allow_nil?: true

      run fn input, _ctx ->
        msg = input.arguments.message
        {:ok, if(input.arguments[:loud], do: String.upcase(msg), else: msg)}
      end
    end

    # Scalar return, no arguments — exercises the no-input generated function.
    action :ping, :string do
      run fn _input, _ctx -> {:ok, "pong"} end
    end

    # Map return, no arguments — exercises the [String: AshJSON] return mapping.
    action :stats, :map do
      run fn _input, _ctx -> {:ok, %{"count" => 0}} end
    end

    # Struct return — a typed record return needs field selection (Tier C), which
    # this slice defers. Codegen must warn-and-skip it rather than emit a broken
    # function. Regression guard for the skip path.
    action :summarize, :struct do
      constraints instance_of: __MODULE__
      run fn _input, _ctx -> {:ok, nil} end
    end

    # Void return, no arguments — exercises the void no-input codegen path
    # (VoidActionRequest<EmptyActionInput>, no input parameter). Issue #54 review P2.
    action :ping_void do
      run fn _input, _ctx -> :ok end
    end

    # Scalar return with a Swift-keyword-named argument (`default`) and a map-typed
    # argument (`options`) — proves keyword escaping reaches generic-action inputs
    # and the map argument maps to [String: AshJSON]. Issue #54 review (keyword +
    # map-arg findings).
    action :echo_config, :string do
      argument :default, :string, allow_nil?: false
      argument :options, :map, allow_nil?: true
      run fn input, _ctx -> {:ok, input.arguments.default} end
    end

    # An array-of-scalar argument maps element-wise to `[String]` — a supported
    # generic-action input. (Before array support it was skipped; it now exercises
    # the `[Scalar]` input path.)
    action :broadcast do
      argument :tags, {:array, :string}, allow_nil?: true
      run fn _input, _ctx -> :ok end
    end

    # An array-of-record argument (a constrained-map item type): the manifest
    # carries it as `kind: :array` with a `kind: :map, fields: [...]` item, and
    # ash_swift generates a nested input struct (`BulkCreateRowsItem`) so the
    # element is compiler-checked rather than `[[String: AshJSON]]`. Mirrors
    # SwingClips' `upload_start` clips manifest. Mixed required/optional fields and a
    # non-String scalar (`priority`) exercise the nested-struct field mapping.
    action :bulk_create, :map do
      argument :rows, {:array, :map},
        allow_nil?: false,
        constraints: [
          items: [
            fields: [
              label: [type: :string, allow_nil?: false],
              priority: [type: :integer, allow_nil?: true]
            ]
          ]
        ]

      run fn _input, _ctx -> {:ok, %{}} end
    end

    # A nested-array argument (`{:array, {:array, :string}}`): the element type is
    # itself an array, which maps to no Swift type — so the whole action is still
    # skipped. Regression guard that the input-skip path survives array support.
    action :deep_broadcast do
      argument :matrix, {:array, {:array, :string}}, allow_nil?: true
      run fn _input, _ctx -> :ok end
    end

    # An **unconstrained** `{:array, :map}` argument (no `items: [fields: ...]`): the
    # element is a plain map, so it maps element-wise to `[[String: AshJSON]]` rather
    # than a generated struct. Regression guard for that fall-through branch.
    action :bulk_raw, :map do
      argument :rows, {:array, :map}, allow_nil?: false
      run fn _input, _ctx -> {:ok, %{}} end
    end
  end
end
