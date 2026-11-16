defmodule AshSwift.Codegen.ReaderWarningTest do
  @moduledoc """
  Pins how often the Reader logs a warning. Not async: `capture_log/1` sees every
  process's log output, so concurrent tests that also run the Reader would add
  their own copies of the warning to the count.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshSwift.Codegen.Reader

  test "an unsupported attribute is warned about once, however often its resource is reached" do
    log = capture_log(fn -> Reader.read([AshSwift.Test.Domain]) end)

    # Todo is a primary resource and also a relationship/return destination of
    # other primaries; the warning must not repeat per visit.
    assert length(String.split(log, "attribute AshSwift.Test.Todo.matrix")) == 2
  end
end
