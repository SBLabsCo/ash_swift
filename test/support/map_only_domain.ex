defmodule AshSwift.Test.MapOnlyDomain do
  @moduledoc """
  Fixture domain exposing a single filterable read over `MapOnly`, whose only
  public attribute is excluded from filtering. Sorting is disabled so the only
  generated query surface is the (empty) filter struct. Used to exercise the
  empty-filter-struct branch of codegen.
  """

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.MapOnly do
      rpc_action(:list_map_onlys, :read, enable_sort?: false)
    end
  end

  resources do
    resource AshSwift.Test.MapOnly
  end
end
