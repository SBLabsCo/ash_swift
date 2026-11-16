defmodule AshSwift.Test.ActionIRKeys do
  @moduledoc """
  The Reader's documented action IR key sets (#95), shared so the Reader test
  that pins them against real output and the Emitter test's hand-built IR
  cannot drift apart (#154).
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
end
