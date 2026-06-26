defmodule AshSwift.Test.CollisionItemPriority do
  @moduledoc "Fixture resource: its type name 'CollisionItemPriority' collides with the enum generated from CollisionItem.priority (issue #24)."

  use Ash.Resource,
    domain: AshSwift.Test.CollisionDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("CollisionItemPriority")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end
