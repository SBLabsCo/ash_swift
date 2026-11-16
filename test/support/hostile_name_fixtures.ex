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

defmodule AshSwift.Test.LeadingUnderscoreActionName do
  @moduledoc "Fixture resource with a hostile name (#142)."

  use Ash.Resource,
    domain: AshSwift.Test.LeadingUnderscoreActionNameDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("LeadingUnderscoreActionName")
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

defmodule AshSwift.Test.LeadingUnderscoreActionNameDomain do
  @moduledoc "Fixture domain exposing `AshSwift.Test.LeadingUnderscoreActionName` (#142)."

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.LeadingUnderscoreActionName do
      rpc_action(:_1, :read)
    end
  end

  resources do
    resource AshSwift.Test.LeadingUnderscoreActionName
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
  Fixture resource (#142): a hostile raw argument name that `argument_names` maps
  to a clean client name, used as an array-of-map argument. The nested input struct
  name is derived from the raw atom, so it must be validated on its own.
  """

  use Ash.Resource,
    domain: AshSwift.Test.BadStructNameReturnDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("BadStructNameReturn")
    argument_names up_it: [{:"x {}\nstruct Evil { static let pwned = 1 }\nstruct Z?", :clips}]
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
  end

  actions do
    defaults [:read]

    action :up_it, :boolean do
      argument :"x {}\nstruct Evil { static let pwned = 1 }\nstruct Z?", {:array, :map} do
        allow_nil? false
        public? true
        constraints items: [fields: [a: [type: :string, allow_nil?: false]]]
      end

      run fn _input, _ctx -> {:ok, true} end
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

defmodule AshSwift.Test.BadTypeName do
  @moduledoc """
  Fixture resource whose `type_name` is not a Swift identifier (#142). Codegen
  must reject it at Reader time rather than splice it into a Swift type position.
  Not part of `AshSwift.Test.Domain`.
  """

  use Ash.Resource,
    domain: AshSwift.Test.BadTypeNameDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("Bad {\n}\nstruct Injected")
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

defmodule AshSwift.Test.KeywordGetBy do
  @moduledoc """
  Fixture resource (#142): a get_by lookup field whose name is a Swift keyword. The
  generated `input:` dictionary value must be backtick-escaped to compile.
  """

  use Ash.Resource,
    domain: AshSwift.Test.KeywordGetByDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("KeywordGetBy")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :default, :string, public?: true, allow_nil?: false
  end

  actions do
    defaults [:read]

    read :get_by_default do
      get_by :default
    end
  end
end

defmodule AshSwift.Test.KeywordGetByDomain do
  @moduledoc "Fixture domain exposing `AshSwift.Test.KeywordGetBy` (#142)."

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.KeywordGetBy do
      rpc_action(:get_keyword, :get_by_default)
    end
  end

  resources do
    resource AshSwift.Test.KeywordGetBy
  end
end

defmodule AshSwift.Test.BadCalcEnumValue.Calc do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _opts, _ctx), do: Enum.map(records, fn _ -> :ok end)
end

defmodule AshSwift.Test.BadCalcEnumValue do
  @moduledoc """
  Fixture resource (#142): an enum-typed calculation with a hostile value, covering
  the derived-field (calculation/aggregate) enum path in the Reader.
  """

  use Ash.Resource,
    domain: AshSwift.Test.BadCalcEnumValueDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("BadCalcEnumValue")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
  end

  calculations do
    calculate :kind, :atom, AshSwift.Test.BadCalcEnumValue.Calc,
      constraints: [one_of: [:"x\"y"]],
      public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshSwift.Test.BadCalcEnumValueDomain do
  @moduledoc "Fixture domain exposing `AshSwift.Test.BadCalcEnumValue` (#142)."

  use Ash.Domain,
    otp_app: :ash_swift,
    extensions: [AshTypescript.Rpc],
    validate_config_inclusion?: false

  typescript_rpc do
    resource AshSwift.Test.BadCalcEnumValue do
      rpc_action(:list_bad_calc, :read)
    end
  end

  resources do
    resource AshSwift.Test.BadCalcEnumValue
  end
end
