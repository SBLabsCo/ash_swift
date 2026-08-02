defmodule AshSwift.Test.Category do
  @moduledoc "Fixture resource: a category — 1 hop from Tag, has a 2-hop relationship to Publisher."

  use Ash.Resource,
    domain: AshSwift.Test.TagDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("Category")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  relationships do
    belongs_to :publisher, AshSwift.Test.Publisher, public?: true
  end

  actions do
    defaults [:read]
  end
end
