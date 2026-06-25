defmodule AshSwift.Test.StatusType do
  @moduledoc "Fixture Ash.Type.Enum used to test the Enum-subtype branch of extract_enum_cases/1.
  :case and :default are Swift reserved keywords — the generator must backtick-escape them."
  use Ash.Type.Enum, values: [:pending, :active, :archived, :default, :case]
end
