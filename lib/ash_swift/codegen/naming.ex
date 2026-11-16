defmodule AshSwift.Codegen.Naming do
  @moduledoc false
  # Name transforms shared by the Reader (which validates the result is a Swift
  # identifier) and the Emitter (which renders it), so the two can't drift (#142).

  # snake_case to lowerCamelCase (e.g. in_progress -> inProgress). Raises
  # `Mix.Error` for a value with no name part (empty, or only underscores).
  def lower_camel(name) do
    case name |> to_string() |> String.split("_", trim: true) do
      [first | rest] ->
        Enum.join([String.downcase(first) | Enum.map(rest, &String.capitalize/1)])

      [] ->
        Mix.raise(
          "AshSwift codegen: #{inspect(name)} has no name part to use as a Swift identifier"
        )
    end
  end
end
