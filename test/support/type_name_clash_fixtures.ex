# Fixtures for Swift type-name collisions between different resource modules
# (#156). Three domains:
#
#   * TypeNameClashPrimaryDomain: primary `ClashPrimary` (type_name "Clash") has a
#     relationship to the unexposed `ClashRelated`, whose type_name is also "Clash".
#   * TypeNameClashRelatedDomain: primary `ClashHolder` relates to two unexposed
#     modules (`ClashRelatedA`, `ClashRelatedB`) that share the type_name "ClashDup".
#   * SharedDestinationDomain: primary `SharedHolder` reaches one unexposed module
#     (`SharedTarget`) through two relationships; no clash, emitted once.

defmodule AshSwift.Test.ClashRelated do
  @moduledoc false

  use Ash.Resource,
    domain: AshSwift.Test.TypeNameClashPrimaryDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("Clash")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read]
  end
end

defmodule AshSwift.Test.ClashPrimary do
  @moduledoc false

  use Ash.Resource,
    domain: AshSwift.Test.TypeNameClashPrimaryDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("Clash")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end

  relationships do
    belongs_to :other, AshSwift.Test.ClashRelated, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshSwift.Test.TypeNameClashPrimaryDomain do
  @moduledoc false

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.ClashPrimary do
      rpc_action(:list_clash_primaries, :read)
    end
  end

  resources do
    resource AshSwift.Test.ClashPrimary
    resource AshSwift.Test.ClashRelated
  end
end

defmodule AshSwift.Test.ClashRelatedA do
  @moduledoc false

  use Ash.Resource,
    domain: AshSwift.Test.TypeNameClashRelatedDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("ClashDup")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read]
  end
end

defmodule AshSwift.Test.ClashRelatedB do
  @moduledoc false

  use Ash.Resource,
    domain: AshSwift.Test.TypeNameClashRelatedDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("ClashDup")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read]
  end
end

defmodule AshSwift.Test.ClashHolder do
  @moduledoc false

  use Ash.Resource,
    domain: AshSwift.Test.TypeNameClashRelatedDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("ClashHolder")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end

  relationships do
    belongs_to :first, AshSwift.Test.ClashRelatedA, public?: true
    belongs_to :second, AshSwift.Test.ClashRelatedB, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshSwift.Test.TypeNameClashRelatedDomain do
  @moduledoc false

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.ClashHolder do
      rpc_action(:list_clash_holders, :read)
    end
  end

  resources do
    resource AshSwift.Test.ClashHolder
    resource AshSwift.Test.ClashRelatedA
    resource AshSwift.Test.ClashRelatedB
  end
end

defmodule AshSwift.Test.SharedTarget do
  @moduledoc false

  use Ash.Resource,
    domain: AshSwift.Test.SharedDestinationDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("SharedTarget")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read]
  end
end

defmodule AshSwift.Test.SharedHolder do
  @moduledoc false

  use Ash.Resource,
    domain: AshSwift.Test.SharedDestinationDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("SharedHolder")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end

  relationships do
    belongs_to :first, AshSwift.Test.SharedTarget, public?: true
    belongs_to :second, AshSwift.Test.SharedTarget, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshSwift.Test.SharedDestinationDomain do
  @moduledoc false

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.SharedHolder do
      rpc_action(:list_shared_holders, :read)
    end
  end

  resources do
    resource AshSwift.Test.SharedHolder
    resource AshSwift.Test.SharedTarget
  end
end
