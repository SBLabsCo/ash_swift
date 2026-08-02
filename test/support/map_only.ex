defmodule AshSwift.Test.MapOnly do
  @moduledoc """
  Fixture resource whose only public attribute is an `Ash.Type.Map` (excluded
  from filtering) and whose primary key is non-public. A filterable read action
  over it therefore produces a `{Resource}Filter` with no properties — exercising
  the empty-struct branch of `render_filter_struct/1`.
  """

  use Ash.Resource,
    domain: AshSwift.Test.MapOnlyDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name("MapOnly")
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: false
    attribute :metadata, :map, public?: true
  end

  actions do
    defaults [:read]
  end
end
