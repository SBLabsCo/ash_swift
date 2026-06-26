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
    timestamps()
  end

  relationships do
    belongs_to :user, AshSwift.Test.User, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    read :get_by_id do
      get_by :id
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
  end
end
