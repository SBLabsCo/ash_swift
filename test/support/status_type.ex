defmodule AshSwift.Test.StatusType do
  @moduledoc "Fixture Ash.Type.Enum used to test the Enum-subtype branch of extract_enum_cases/1.
  The :default value is a Swift reserved keyword — the generator must backtick-escape it."
  use Ash.Type.Enum, values: [:pending, :active, :archived, :default]
end
