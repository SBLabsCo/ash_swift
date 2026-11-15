# Changelog

## Unreleased

### Breaking

- Generated functions for a pure `get?` read (a `get?` action with no native or
  RPC-level `get_by`) no longer take a primary-key lookup parameter and no longer
  send `identity`: the RPC pipeline never reads `identity` for a read, so the
  value was silently dropped. `fetchTodo(id: String, fields:)` becomes
  `fetchTodo(fields:)`, or `fetchTodo(input: FetchTodoInput, fields:)` when the
  read declares arguments. `GetRequest` / `GetOptionalRequest` lose their
  `identity:` initializer parameter. `get_by` reads, update and destroy are
  unchanged. (#91)
