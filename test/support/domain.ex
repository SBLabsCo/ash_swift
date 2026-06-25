defmodule AshSwift.Test.Domain do
  @moduledoc "Fixture domain exposing the core CRUD action types via the reused typescript_rpc DSL."

  use Ash.Domain, otp_app: :ash_swift, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    resource AshSwift.Test.Todo do
      rpc_action(:list_todos, :read)
      rpc_action(:get_todo, :get_by_id)
      rpc_action(:find_todo, :get_by_id, not_found_error?: false)
      rpc_action(:create_todo, :create)
      rpc_action(:update_todo, :update)
      rpc_action(:destroy_todo, :destroy)
    end

    resource AshSwift.Test.User do
      rpc_action(:list_users, :read)
      rpc_action(:create_user, :create)
    end
  end

  resources do
    resource AshSwift.Test.Todo
    resource AshSwift.Test.User
  end
end
