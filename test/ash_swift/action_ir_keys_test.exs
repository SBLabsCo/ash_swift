defmodule AshSwift.Test.ActionIRKeysTest do
  @moduledoc """
  Guards the shared hand-built action IR builders (used by the Emitter and
  Contract tests) against drifting from the Reader's documented key sets
  (#154, #162).
  """
  use ExUnit.Case, async: true

  alias AshSwift.Test.ActionIRKeys

  test "hand-built action IR carries exactly the Reader's key sets" do
    assert MapSet.new(Map.keys(ActionIRKeys.crud_action())) == ActionIRKeys.crud()
    assert MapSet.new(Map.keys(ActionIRKeys.generic_action())) == ActionIRKeys.generic()
  end
end
