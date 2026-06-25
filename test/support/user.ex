defmodule AshSwift.Test.User do
  @moduledoc "Fixture resource: a user that owns todos."

  use Ash.Resource,
    domain: AshSwift.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name "User"
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

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
