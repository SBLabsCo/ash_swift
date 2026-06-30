defmodule AshSwift.Test.Domain do
  @moduledoc "Fixture domain exposing the core CRUD action types via the reused typescript_rpc DSL."

  use Ash.Domain, otp_app: :ash_swift, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    resource AshSwift.Test.Todo do
      rpc_action(:list_todos, :read)
      rpc_action(:init, :read)
      # Sorting is on by default; this action turns it off so codegen must emit
      # the read function WITHOUT a sort: parameter (compile-time gating).
      rpc_action(:list_todos_no_sort, :read, enable_sort?: false)
      # Filtering is on by default; this action turns it off so codegen must emit
      # the read function WITHOUT a filter: parameter (compile-time gating).
      rpc_action(:list_todos_no_filter, :read, enable_filter?: false)
      rpc_action(:list_todos_offset, :list_offset_paginated)
      rpc_action(:list_todos_keyset, :list_keyset_paginated)
      rpc_action(:list_todos_keyset_optional, :list_keyset_optional)
      rpc_action(:get_todo, :get_by_id)
      rpc_action(:fetch_todo, :fetch)
      rpc_action(:find_todo, :get_by_id, not_found_error?: false)
      rpc_action(:get_todo_by_score, :get_by_score)
      rpc_action(:find_todo_by_title, :read, get_by: [:title])
      rpc_action(:create_todo, :create)
      rpc_action(:update_todo, :update)
      rpc_action(:destroy_todo, :destroy)
      # Generic actions (issue #54).
      rpc_action(:request_magic_link, :request_magic_link)
      rpc_action(:echo, :echo)
      rpc_action(:ping, :ping)
      rpc_action(:stats, :stats)
      rpc_action(:summarize, :summarize)
      rpc_action(:ping_void, :ping_void)
      rpc_action(:echo_config, :echo_config)
      rpc_action(:broadcast, :broadcast)
      rpc_action(:bulk_create, :bulk_create)
      rpc_action(:deep_broadcast, :deep_broadcast)
      rpc_action(:bulk_raw, :bulk_raw)
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
