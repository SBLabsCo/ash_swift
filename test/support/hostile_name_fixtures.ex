# Fixtures for the #142 injection hardening: each resource carries exactly one
# hostile name. Not part of AshSwift.Test.Domain, so the main output is unaffected.

defmodule AshSwift.Test.BadActionName do
  @moduledoc "Fixture resource with a hostile name (#142)."

  use Ash.Resource,
    domain: AshSwift.Test.BadActionNameDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("BadActionName")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshSwift.Test.BadActionNameDomain do
  @moduledoc "Fixture domain exposing `AshSwift.Test.BadActionName` (#142)."

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.BadActionName do
      rpc_action(:"list bad", :read)
    end
  end

  resources do
    resource AshSwift.Test.BadActionName
  end
end

defmodule AshSwift.Test.BadFieldName do
  @moduledoc "Fixture resource with a hostile name (#142)."

  use Ash.Resource,
    domain: AshSwift.Test.BadFieldNameDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("BadFieldName")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :"bad}name", :string, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshSwift.Test.BadFieldNameDomain do
  @moduledoc "Fixture domain exposing `AshSwift.Test.BadFieldName` (#142)."

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.BadFieldName do
      rpc_action(:list_bad_field, :read)
    end
  end

  resources do
    resource AshSwift.Test.BadFieldName
  end
end

defmodule AshSwift.Test.BadEnumValue do
  @moduledoc "Fixture resource with a hostile name (#142)."

  use Ash.Resource,
    domain: AshSwift.Test.BadEnumValueDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("BadEnumValue")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :status, :atom, public?: true, constraints: [one_of: [:"x\"y"]]
  end

  actions do
    defaults [:read]
  end
end

defmodule AshSwift.Test.BadEnumValueDomain do
  @moduledoc "Fixture domain exposing `AshSwift.Test.BadEnumValue` (#142)."

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.BadEnumValue do
      rpc_action(:list_bad_enum, :read)
    end
  end

  resources do
    resource AshSwift.Test.BadEnumValue
  end
end

defmodule AshSwift.Test.BadStructNameReturn do
  @moduledoc """
  Fixture resource (#142): a hostile raw field name that `field_names` maps to a
  clean client name, reused as an array-of-map return field. The nested struct name
  is derived from the raw atom, so it must be validated on its own.
  """

  use Ash.Resource,
    domain: AshSwift.Test.BadStructNameReturnDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("BadStructNameReturn")
    field_names [{:"x {}\nstruct Evil { static let pwned = 1 }\nstruct Z?", "clips"}]
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :"x {}\nstruct Evil { static let pwned = 1 }\nstruct Z?", :string, public?: true
  end

  actions do
    defaults [:read]

    action :up_it, :map do
      constraints fields: [
                    "x {}\nstruct Evil { static let pwned = 1 }\nstruct Z?": [
                      type: {:array, :map},
                      constraints: [items: [fields: [a: [type: :string, allow_nil?: false]]]]
                    ]
                  ]

      run fn _input, _ctx -> {:ok, %{}} end
    end
  end
end

defmodule AshSwift.Test.BadStructNameReturnDomain do
  @moduledoc "Fixture domain exposing `AshSwift.Test.BadStructNameReturn` (#142)."

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.BadStructNameReturn do
      rpc_action(:up_it, :up_it)
    end
  end

  resources do
    resource AshSwift.Test.BadStructNameReturn
  end
end
