defmodule AshSwift.Test.BadTypeName do
  @moduledoc """
  Fixture resource whose `type_name` is not a Swift identifier (#142). Codegen
  must reject it at Reader time rather than splice it into a Swift type position.
  Not part of `AshSwift.Test.Domain`, so the main fixture output is unaffected.
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
