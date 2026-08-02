defmodule AshSwift.Test.CollisionItem do
  @moduledoc "Fixture resource: exercises enum/struct type name collision detection (issue #24)."

  use Ash.Resource,
    domain: AshSwift.Test.CollisionDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("CollisionItem")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    # priority enum → generates enum type name "CollisionItemPriority",
    # which collides with the CollisionItemPriority resource's struct name.
    attribute :priority, :atom, constraints: [one_of: [:low, :high]], public?: true
  end

  actions do
    defaults [:read]
  end
end
