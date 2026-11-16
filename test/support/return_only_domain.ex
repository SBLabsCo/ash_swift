defmodule AshSwift.Test.ReturnOnlyDomain do
  @moduledoc """
  Fixture domain for generic-action resource returns (#56): `Reporter` is the only
  RPC-exposed resource, and its `latest_publisher` action returns a `Publisher` that
  is neither exposed nor related to `Reporter` — so its model struct exists only
  because the generic return names it.
  """

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.Reporter do
      rpc_action(:latest_publisher, :latest_publisher)
    end
  end

  resources do
    resource AshSwift.Test.Reporter
  end
end
