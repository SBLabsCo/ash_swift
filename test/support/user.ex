defmodule AshSwift.Test.User do
  @moduledoc "Fixture resource: a user that owns todos."

  use Ash.Resource,
    domain: AshSwift.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("User")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :email, :string, allow_nil?: false, public?: true
    timestamps()
  end

  relationships do
    has_many :todos, AshSwift.Test.Todo, public?: true
  end

  # Aggregates exercise codegen's derived-field surface (issue #51):
  #   todo_count    → count   → Int?   (scalar, emitted)
  #   has_todos     → exists  → Bool?  (scalar, emitted)
  #   highest_score → max     → Int?   (field-typed from :score, emitted)
  #   top_priority  → first   → resolves to the :priority enum type → emits a
  #                            per-resource Swift enum (UserTopPriority)
  #   todo_titles   → list    → [String] (array result — must be SKIPPED, not
  #                            String-fallbacked; an aggregate type is derived,
  #                            so a wrong guess is worse than omission)
  #   secret_count  → count, private → must NOT appear (public-only scope)
  aggregates do
    count :todo_count, :todos, public?: true
    exists :has_todos, :todos, public?: true
    # The full set of field-typed numeric aggregates — all share the scalar gate +
    # ash_type_to_swift(field.type.module) path, but Ash resolves their result type
    # differently: max/min/sum preserve the field's type (:integer → Int), while
    # avg promotes (locking in that :float/:decimal stay in @derived_scalar_kinds).
    max :highest_score, :todos, :score, public?: true
    min :lowest_score, :todos, :score, public?: true
    sum :total_score, :todos, :score, public?: true
    avg :average_score, :todos, :score, public?: true
    first :top_priority, :todos, :priority, public?: true
    list :todo_titles, :todos, :title, public?: true
    count :secret_count, :todos
  end

  # Calculations exercise codegen's calculation surface (issue #52). They ride the
  # same derived-field path as aggregates (#51): scalar/enum results are emitted as
  # Optional fields, non-scalar results are skipped, and the manifest's public-only
  # scope drops private ones. The calculation-specific gate is arguments: only a
  # zero-argument calculation is selectable via the plain `.scalar` path — the
  # reused RPC pipeline rejects ANY argument-bearing calc (even all-optional)
  # without an args-bearing selection shape, which is deferred to M3.
  #   display_name → zero-argument scalar :string → emitted (String?)
  #   name_size    → zero-argument :atom with one_of → emitted as a per-resource
  #                  Swift enum (UserNameSize), exercising emit_derived_fields'
  #                  enum branch from the *calculation* path (not just aggregates)
  #   greeting     → one *optional* arg (has a default) → SKIPPED. The PRD assumed
  #                  optional args were zero-arg-selectable; the live pipeline
  #                  rejects them with "Calculation requires arguments", so this is
  #                  the regression guard that arg-bearing calcs defer to M3.
  #   name_matches → one *required* arg (no default, allow_nil?: false) → SKIPPED
  #   name_summary → :map result → SKIPPED (non-scalar; unlike a :map *attribute*,
  #                  which emits AshJSON, a derived field's computed type is dropped
  #                  rather than guessed)
  #   secret_label → private → must NOT appear (public-only scope)
  calculations do
    calculate :display_name, :string, expr(name <> " <" <> email <> ">"), public?: true

    calculate :name_size, :atom, AshSwift.Test.User.NameSize,
      constraints: [one_of: [:short, :long]],
      public?: true

    calculate :greeting, :string, expr(^arg(:salutation) <> ", " <> name) do
      # Optional argument (has a default). Even so, the RPC pipeline demands the
      # args-bearing shape { greeting: { args: {...} } }, so codegen must skip it.
      argument :salutation, :string, default: "Hello"
      public? true
    end

    calculate :name_matches, :boolean, expr(contains(name, ^arg(:substring))) do
      # Required argument (no default, non-nullable) → also skipped, deferred to M3.
      argument :substring, :string, allow_nil?: false
      public? true
    end

    calculate :name_summary, :map, AshSwift.Test.User.NameSummary, public?: true

    calculate :secret_label, :string, expr(name), public?: false
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshSwift.Test.User.NameSize do
  @moduledoc """
  A zero-argument enum-returning calculation (issue #52): its `:atom` type with a
  `one_of` constraint resolves to an enum, so codegen emits a per-resource Swift
  enum (`UserNameSize`) — proving emit_derived_fields/5's enum branch is reached
  from the calculation path, not only from the aggregate path.
  """
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:name]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record ->
      if String.length(record.name) > 10, do: :long, else: :short
    end)
  end
end

defmodule AshSwift.Test.User.NameSummary do
  @moduledoc """
  A trivial map-returning calculation used to prove codegen skips non-scalar
  calculations (issue #52): a `:map` result has no faithful Swift scalar/enum
  type, so the generated model omits it rather than guessing.
  """
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:name]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record -> %{"name" => record.name} end)
  end
end
