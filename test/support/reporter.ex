defmodule AshSwift.Test.Reporter do
  @moduledoc "Fixture resource: a generic action returning an unrelated, unexposed resource (#56)."

  use Ash.Resource,
    domain: AshSwift.Test.ReturnOnlyDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("Reporter")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read]

    action :latest_publisher, :struct do
      constraints instance_of: AshSwift.Test.Publisher
      allow_nil? true
      run fn _input, _ctx -> {:ok, nil} end
    end
  end
end
