# Changelog

## Unreleased

### Fixed

- An enum (an `:atom` with `one_of`, or a named `Ash.Type.Enum`) in a generic
  action's typed `:map` result, an array-of-map item, or an argument (including
  an array of enums) now generates a typed Swift enum named from its enclosing
  type and the field (e.g. `StudentGuideResultStatus`). Previously the whole
  generic action was skipped. An enum argument on a create/update/read/destroy
  action, previously omitted from its input struct, is generated the same way.
  (#182)
- Two different resources that map to the same Swift type name (for example a
  related, unexposed resource sharing a primary's `type_name`) are now a codegen
  error instead of one being silently decoded as the other's struct. Give one of
  them a distinct `type_name` in its `typescript do ... end` block. (#156)
- String literals in generated Swift are now escaped, and codegen stops with an
  error when a resource `type_name`, rpc action name, field or argument name, or
  enum value is not a plain Swift identifier. Previously such names produced
  Swift that did not compile (or could inject declarations). (#142)

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
