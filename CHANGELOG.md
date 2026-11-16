# Changelog

## Unreleased

### Changed

- Filter fields for `:ci_string` attributes are now typed
  `NullableCiStringOperators<String>` / `CiStringOperators<String>`, documented
  aliases of `NullableEnumOperators` / `EnumOperators` (same operators, same
  wire format; the backend compares case-insensitively). Existing call sites
  keep compiling. (#58)

### Breaking

- Create input structs now make attributes listed in the action's
  `allow_nil_input` optional (`T?`, `= nil` in the init), where a non-null
  attribute without a default used to be required. Those params also move after
  the required ones in the memberwise init, so call sites must reorder:
  `CreateWidgetInput(name: "x", size: 3)` becomes
  `CreateWidgetInput(size: 3, name: "x")` when `name` is in `allow_nil_input`
  (and `size` is required), and reading `.name` now yields `String?`. (#124)

- Update and soft-destroy input structs now make the attributes listed in the
  action's `require_attributes` non-optional, with no default in the init,
  matching ash_typescript. Callers must pass those fields when building the
  input: `RenameTodoInput(priority: .high)` becomes
  `RenameTodoInput(title: "x", priority: .high)`. (#113)

- Generated functions for a pure `get?` read (a `get?` action with no native or
  RPC-level `get_by`) no longer take a primary-key lookup parameter and no longer
  send `identity`: the RPC pipeline never reads `identity` for a read, so the
  value was silently dropped. `fetchTodo(id: String, fields:)` becomes
  `fetchTodo(fields:)`, or `fetchTodo(input: FetchTodoInput, fields:)` when the
  read declares arguments. `GetRequest` / `GetOptionalRequest` lose their
  `identity:` initializer parameter. `get_by` reads, update and destroy are
  unchanged. (#91)
