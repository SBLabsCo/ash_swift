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
    attribute :completed, :boolean, default: false, public?: true
    attribute :priority, :atom, constraints: [one_of: [:low, :medium, :high]], public?: true
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
  end
end
