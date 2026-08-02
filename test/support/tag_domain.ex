defmodule AshSwift.Test.TagDomain do
  @moduledoc "Fixture domain for testing the 2-hop relationship guard. Only Tag is exposed via RPC; Category and Publisher are related resources."

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.Tag do
      rpc_action(:list_tags, :read)
    end
  end

  resources do
    resource AshSwift.Test.Tag
    resource AshSwift.Test.Category
    resource AshSwift.Test.Publisher
  end
end
