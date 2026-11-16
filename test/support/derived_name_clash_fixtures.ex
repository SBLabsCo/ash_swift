# Fixtures for Swift name collisions between a resource's *derived* top-level
# names and another declaration (#164). Three domains, each raising in the Reader:
#
#   * FilterNameClashDomain: filterable `Widget` derives `WidgetFilter`, which the
#     resource with type_name "WidgetFilter" also declares.
#   * SortFieldEnumClashDomain: sortable `Gadget` derives `GadgetSortField`, which
#     its own `sort_field` enum attribute also generates.
#   * InputStructClashDomain: `Gizmo`'s create action derives `CreateGizmoInput`,
#     which the resource with type_name "CreateGizmoInput" also declares.

defmodule AshSwift.Test.Widget do
  @moduledoc false

  use Ash.Resource,
    domain: AshSwift.Test.FilterNameClashDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("Widget")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshSwift.Test.WidgetFilterResource do
  @moduledoc false

  use Ash.Resource,
    domain: AshSwift.Test.FilterNameClashDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("WidgetFilter")
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

defmodule AshSwift.Test.FilterNameClashDomain do
  @moduledoc false

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.Widget do
      rpc_action(:list_widgets, :read)
    end

    resource AshSwift.Test.WidgetFilterResource do
      rpc_action(:get_widget_filters, :read)
    end
  end

  resources do
    resource AshSwift.Test.Widget
    resource AshSwift.Test.WidgetFilterResource
  end
end

defmodule AshSwift.Test.Gadget do
  @moduledoc false

  use Ash.Resource,
    domain: AshSwift.Test.SortFieldEnumClashDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("Gadget")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    # Enum named "GadgetSortField", colliding with the derived sort-field enum.
    attribute :sort_field, :atom, constraints: [one_of: [:asc, :desc]], public?: true
    attribute :title, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshSwift.Test.SortFieldEnumClashDomain do
  @moduledoc false

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.Gadget do
      rpc_action(:list_gadgets, :read)
    end
  end

  resources do
    resource AshSwift.Test.Gadget
  end
end

defmodule AshSwift.Test.Gizmo do
  @moduledoc false

  use Ash.Resource,
    domain: AshSwift.Test.InputStructClashDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("Gizmo")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
  end

  actions do
    defaults [:read, create: [:title]]
  end
end

defmodule AshSwift.Test.CreateGizmoInputResource do
  @moduledoc false

  use Ash.Resource,
    domain: AshSwift.Test.InputStructClashDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("CreateGizmoInput")
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

defmodule AshSwift.Test.InputStructClashDomain do
  @moduledoc false

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.Gizmo do
      rpc_action(:create_gizmo, :create)
    end

    resource AshSwift.Test.CreateGizmoInputResource do
      rpc_action(:get_create_gizmo_inputs, :read)
    end
  end

  resources do
    resource AshSwift.Test.Gizmo
    resource AshSwift.Test.CreateGizmoInputResource
  end
end
