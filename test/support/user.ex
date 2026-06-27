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

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
