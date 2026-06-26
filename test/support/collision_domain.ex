defmodule AshSwift.Test.CollisionDomain do
  @moduledoc "Fixture domain: CollisionItem's priority enum collides with the CollisionItemPriority resource struct name (issue #24)."

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.CollisionItem do
      rpc_action(:list_collision_items, :read)
    end

    resource AshSwift.Test.CollisionItemPriority do
      rpc_action(:list_collision_item_priorities, :read)
    end
  end

  resources do
    resource AshSwift.Test.CollisionItem
    resource AshSwift.Test.CollisionItemPriority
  end
end
