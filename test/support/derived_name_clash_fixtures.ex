# Fixtures for Swift name collisions between a resource's *derived* top-level
# names and another declaration (#164). Five domains, each raising in the Reader:
#
#   * FilterNameClashDomain: filterable `Widget` derives `WidgetFilter`, which the
#     resource with type_name "WidgetFilter" also declares.
#   * SortFieldEnumClashDomain: sortable `Gadget` derives `GadgetSortField`, which
#     its own `sort_field` enum attribute also generates.
#   * InputStructClashDomain: `Gizmo`'s create action derives `CreateGizmoInput`,
#     which the resource with type_name "CreateGizmoInput" also declares.
#   * SameResourceInputClashDomain: one resource's generic actions `upload`
#     (argument `start_clips`) and `upload_start` (argument `clips`) both derive the
#     nested input struct `UploadStartClipsItem`.
#   * ResultStructClashDomain: `ReportBuilder`'s generic action `build_report` returns a
#     constrained `:map`, deriving the result struct `BuildReportResult`, which the
#     resource with type_name "BuildReportResult" also declares.

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

defmodule AshSwift.Test.Uploader do
  @moduledoc false

  use Ash.Resource,
    domain: AshSwift.Test.SameResourceInputClashDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("Uploader")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read]

    action :upload, :string do
      argument :start_clips, {:array, :map},
        constraints: [items: [fields: [label: [type: :string, allow_nil?: false]]]]

      run fn _input, _ctx -> {:ok, "ok"} end
    end

    action :upload_start, :string do
      argument :clips, {:array, :map},
        constraints: [items: [fields: [url: [type: :string, allow_nil?: false]]]]

      run fn _input, _ctx -> {:ok, "ok"} end
    end
  end
end

defmodule AshSwift.Test.SameResourceInputClashDomain do
  @moduledoc false

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.Uploader do
      rpc_action(:upload, :upload)
      rpc_action(:upload_start, :upload_start)
    end
  end

  resources do
    resource AshSwift.Test.Uploader
  end
end

defmodule AshSwift.Test.ReportBuilder do
  @moduledoc false

  use Ash.Resource,
    domain: AshSwift.Test.ResultStructClashDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("ReportBuilder")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read]

    action :build_report, :map do
      constraints fields: [title: [type: :string, allow_nil?: false]]

      run fn _input, _ctx -> {:ok, %{title: "t"}} end
    end
  end
end

defmodule AshSwift.Test.BuildReportResultResource do
  @moduledoc false

  use Ash.Resource,
    domain: AshSwift.Test.ResultStructClashDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("BuildReportResult")
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

defmodule AshSwift.Test.ResultStructClashDomain do
  @moduledoc false

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.ReportBuilder do
      rpc_action(:build_report, :build_report)
    end

    resource AshSwift.Test.BuildReportResultResource do
      rpc_action(:get_build_report_results, :read)
    end
  end

  resources do
    resource AshSwift.Test.ReportBuilder
    resource AshSwift.Test.BuildReportResultResource
  end
end
