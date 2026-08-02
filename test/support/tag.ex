defmodule AshSwift.Test.Tag do
  @moduledoc "Fixture resource: a tag that belongs to a Category (1-hop non-primary resource)."

  use Ash.Resource,
    domain: AshSwift.Test.TagDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("Tag")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :label, :string, public?: true
  end

  relationships do
    belongs_to :category, AshSwift.Test.Category, public?: true
  end

  actions do
    defaults [:read]
  end
end
