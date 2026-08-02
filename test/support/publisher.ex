defmodule AshSwift.Test.Publisher do
  @moduledoc "Fixture resource: a publisher — 2 hops from Tag, used to test the 2-hop relationship guard."

  use Ash.Resource,
    domain: AshSwift.Test.TagDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("Publisher")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end
