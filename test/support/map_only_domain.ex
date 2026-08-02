defmodule AshSwift.Test.MapOnlyDomain do
  @moduledoc """
  Fixture domain exposing reads over `MapOnly`, whose only public attribute is a
  Map (excluded from both filtering and sorting). `list_map_onlys` disables sort
  to exercise the empty-filter-struct branch; `list_map_onlys_sortable` leaves
  sort enabled over a resource with no sortable attributes — the #41 regression:
  codegen must emit no `SortField` enum and no `sort:` parameter rather than an
  empty, non-compiling raw-value enum.
  """

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.MapOnly do
      rpc_action(:list_map_onlys, :read, enable_sort?: false)
      # Sort enabled (default) over a resource with zero sortable attributes —
      # the #41 repro. With the fix, codegen emits no SortField enum / sort: param.
      rpc_action(:list_map_onlys_sortable, :read)
    end
  end

  resources do
    resource AshSwift.Test.MapOnly
  end
end
