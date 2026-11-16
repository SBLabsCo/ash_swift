defmodule AshSwift.Test.BadTypeNameDomain do
  @moduledoc "Fixture domain exposing `AshSwift.Test.BadTypeName` (#142)."

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.BadTypeName do
      rpc_action(:list_bad, :read)
    end
  end

  resources do
    resource AshSwift.Test.BadTypeName
  end
end
