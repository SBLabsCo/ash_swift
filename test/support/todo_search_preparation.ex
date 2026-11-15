defmodule AshSwift.Test.Todo.SearchPreparation do
  @moduledoc """
  Narrows a Todo read by its optional `user_id` / `completed_only` arguments
  (issue #87 fixtures). Each argument is applied only when the action declares it
  and the caller supplied a non-default value, so the same preparation serves
  every argument-bearing read fixture.
  """
  use Ash.Resource.Preparation
  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    query
    |> maybe_filter_user(Ash.Query.get_argument(query, :user_id))
    |> maybe_filter_completed(Ash.Query.get_argument(query, :completed_only))
  end

  defp maybe_filter_user(query, nil), do: query
  defp maybe_filter_user(query, user_id), do: Ash.Query.filter(query, user_id == ^user_id)

  defp maybe_filter_completed(query, true), do: Ash.Query.filter(query, completed == true)
  defp maybe_filter_completed(query, _), do: query
end
