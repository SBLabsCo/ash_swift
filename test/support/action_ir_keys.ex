defmodule AshSwift.Test.ActionIRKeys do
  @moduledoc """
  The Reader's documented action IR key sets (#95) and hand-built action IR
  builders shaped exactly to them, shared so the Reader test that pins the sets
  against real output and the Emitter and Contract tests' hand-built IR cannot
  drift apart (#154, #162).
  """

  @crud ~w(rpc_name action action_type get
           not_found_error? input_struct_name input_required? primary_key_params
           pagination_type optional_pagination_type sortable? filterable?)a
        |> MapSet.new()

  @generic ~w(rpc_name action action_type get
              not_found_error? input_struct_name primary_key_params pagination_type
              optional_pagination_type sortable? filterable? generic_return
              generic_return_resource)a
           |> MapSet.new()

  @doc "Keys every CRUD action IR map carries."
  def crud, do: @crud

  @doc "Keys every generic action IR map carries."
  def generic, do: @generic

  @doc """
  A CRUD action IR map with every key the Reader emits. `overrides` use
  `Map.replace!/3`, so a typo'd key or one the Reader never emits for this
  action kind raises instead of silently building an impossible shape.
  """
  def crud_action(overrides \\ []) do
    override!(
      %{
        rpc_name: :list_todos,
        action: :read,
        action_type: :read,
        get: nil,
        not_found_error?: false,
        input_struct_name: nil,
        input_required?: false,
        primary_key_params: [],
        pagination_type: :none,
        optional_pagination_type: :none,
        sortable?: false,
        filterable?: false
      },
      overrides
    )
  end

  @doc """
  A generic action IR map with every key the Reader emits: no `input_required?`
  (CRUD only), plus `generic_return` and `generic_return_resource`. Overrides
  behave as in `crud_action/1`.
  """
  def generic_action(overrides \\ []) do
    override!(
      %{
        rpc_name: :ping,
        action: :ping,
        action_type: :action,
        get: nil,
        not_found_error?: false,
        input_struct_name: nil,
        primary_key_params: [],
        pagination_type: :none,
        optional_pagination_type: :none,
        sortable?: false,
        filterable?: false,
        generic_return: :void,
        generic_return_resource: nil
      },
      overrides
    )
  end

  defp override!(base, overrides) do
    Enum.reduce(overrides, base, fn {k, v}, acc -> Map.replace!(acc, k, v) end)
  end
end
