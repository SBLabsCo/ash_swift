# Lessons for agents

Non-obvious, recurring patterns this project's automation has learned about its
own work. Implement and `/address-review` runs read this as context.

**Bar for adding a new entry:** the pattern is **non-obvious** (a fresh reader
would miss it), will **recur** across tickets (not a one-off), and isn't
**already** covered here. If unsure, don't add it. Two paragraphs max per
entry; link to a real PR or issue when you can.

---

## Codegen patterns

### When the review names a "known finite set," use the authoritative source

When a review finding asks you to extend a list (Swift keywords, Ash types,
reserved identifiers, …), don't grow the list with whatever the review's
example mentioned — pull the **complete authoritative set** (e.g. Swift's
Language Reference §Lexical Structure for keywords, `Ash.Type.*` modules for
the type map) and add a regression test that exercises a previously-missing
member. Otherwise the next domain that uses an unlisted value re-opens the
same bug. See PR #23 (Swift keyword escaping landed twice: the first pass
copied just the review's examples; the steered pass used the complete list).

### Keyword escaping must be applied to every emitter that writes identifier names

When a review flags missing keyword escaping in one emitter (e.g. `render_input_struct`), audit every other function that emits Swift identifier names — `render_fields`, `render_enum`, relationship field emitters, etc. The fix for PR #28 initially only escaped `render_input_struct`; `render_fields` (the model-struct emitter) silently emitted `public var default: String?`, causing Swift compiler errors in the e2e test. The fix: grep for every place that interpolates a field name (`#{n}` or `#{name}`) and confirm each one calls `escape_swift_keyword/1`.

### Lookup-key parameter types are always `String`

`get_by` / identity lookup values travel through the runtime as JSON in a
`[String: String]` body (see `AshRpcClient.makeGetBody`). Generated parameter
types for those keys must therefore be `String?` / `String` regardless of the
Ash attribute's actual type (`:integer` primary keys, atom keys, …). If you
let `ash_type_to_swift` flow into a get-action parameter, you get uncompilable
Swift the moment a non-String key shows up. See PR #26.

### Codegen output is sorted; keep new emitters in the same shape

`build_files/1` and `collect_resources/1` sort by stable keys (type name,
attribute name, rpc name) so regenerating with no schema change produces no
diff. Any new emitter (relationships, calculations, …) must sort the same
way before joining strings, or the deterministic-output test will start
flapping. The cheapest check: run codegen twice in the test, assert byte
equality.

### Update/destroy use `identity`, not `input`, to identify the record

The AshTypescript RPC wire protocol sends the primary-key value for update and
destroy actions under a top-level `identity` key (a plain string), **not** in
the `input` dict. Sending `{"action": "update_todo", "input": {"id": "...", "title": "..."}}` returns `missing_identity`; the correct shape is `{"action": "update_todo", "identity": "<uuid>", "input": {"title": "..."}}`. The same applies to destroy: `{"action": "destroy_todo", "identity": "<uuid>"}`. Probe with `AshTypescript.Rpc.run_action` and inspect the response before wiring up the Swift runtime or generating call sites. See PR #28.

### Pagination detection must check `required?: true`, not just presence of a pagination struct

Every Ash read action carries an `Ash.Resource.Actions.Read.Pagination` struct — including the
default `:read` action on ETS-backed resources, which ships with `offset?: true, keyset?: true`
by default (the ETS data layer supports both). Checking only `ash_action.pagination` (non-nil)
or `pagination.offset?` (true) will incorrectly classify all list actions as paginated. The
correct signal is `pagination.required? == true`: that flag is only set when the Ash developer
explicitly opts the action into mandatory pagination. See PR #29 (issue #16).

### Per-resource query types must handle the empty (no-eligible-attributes) case

A query-surface slice that generates a per-resource type from a (possibly empty)
attribute set — the sortable-field enum (#34), the filter struct (#35), and future
combinator types (#36/#37) — must handle a resource with **zero** eligible
attributes. An empty Encodable struct compiles fine
(`public struct XFilter: Encodable, Sendable { public init() {} }`), but an empty
raw-value enum does **not**: `public enum XSortField: String, Sendable {}` fails with
"an enum with no cases cannot declare a raw type". A resource trips this when its
only public attributes are non-eligible (e.g. all `Ash.Type.Map`, which both sort and
filter exclude) or its primary key is non-public. Test the empty case with a minimal
fixture — see `AshSwift.Test.MapOnly` (test/support/map_only.ex), used by the
empty-filter-struct and (via `list_map_onlys_sortable`) empty-sort-enum regression
tests. (Fixed for sort in #41: an empty sortable set drops the `SortField` enum and
the `sort:` parameter, mirroring `enable_sort?: false`.)

### The manifest's `sortable?`/`filterable?` flags are more permissive than our exclusions

`Ash.Info.Manifest` field structs carry `sortable?` and `filterable?` booleans, which
look like the authoritative source for the sort/filter surface. They are **not** the
right gate for codegen: they answer "is this field addressable in Ash's model," not
"will a sort/filter on it succeed at the data layer." An `Ash.Type.Map` attribute
reports `sortable?: true, filterable?: true` in the manifest, but we deliberately
exclude composite types (`sortable_attribute?/1` and the filter `:exclude` group)
because sorting/filtering a JSON blob is a footgun the backend rejects at query time.
Keep the Swift-type-based classification — don't "simplify" sort/filter gating onto
the manifest flags, or you'll re-emit excluded fields. Confirmed by probing the
manifest for `AshSwift.Test.MapOnly.metadata` (issue #41).

### Filter/sort operator keys are camelCase on the wire — the pipeline formats nested map keys

The reused RPC pipeline runs `AshTypescript.FieldFormatter.parse_input_fields`
**recursively** over the whole params map, so it transforms not just top-level
keys but every nested map key — including filter operator keys. That means the
client sends camelCase operator keys (`notEq`, `greaterThan`, `greaterThanOrEqual`,
`lessThan`, `lessThanOrEqual`, `isNil`, `in`, `eq`) and the pipeline lowers them to
snake_case atoms (`:not_eq`, `:is_nil`, …) before `Ash.Query.filter_input`. So the
generated Swift uses camelCase operator names directly (which double as the wire
keys via Swift's synthesized `CodingKeys`) — no snake_case spelling in the client.
Confirmed live against `AshTypescript.Rpc.run_action` with each operator (issue
#35); re-probe before trusting it for the and/or/not combinators (#36). The Ash
`FilterTypes` classification (`deps/ash_typescript/lib/ash_typescript/codegen/filter_types.ex`)
is the authoritative operator-set-per-type source — use it, not examples.

### AshRpcTypes.swift needs `import AshSwiftRuntime` when model fields use runtime types

`AshRpcFunctions.swift` has always imported `AshSwiftRuntime`, but `AshRpcTypes.swift` originally only imported `Foundation` — all generated model types were built-in Swift types (String, Bool, Int, Double). If you add a new Ash-to-Swift mapping whose Swift type lives in the runtime package (e.g., `AshJSON` for `Ash.Type.Map`), the generated types file must also import `AshSwiftRuntime` or Swift will emit "cannot find type 'X' in scope" errors during `swift build`. The `render_types` function in `codegen.ex` owns this import. See PR #30 (issue #17): the E2E swift test caught the missing import immediately.

### Derived fields (aggregates/calculations) ride existing seams — skip what doesn't map, don't fall back

Aggregates (#51) and calculations (#52) are first-class manifest `Field`s: read them with the
same `ManifestResource.fields_by_kind(:aggregate | :calculation)` accessor used for `:attribute`,
map their resolved `field.type` through the existing `ash_type_to_swift` + `manifest_enum_values`
machinery, emit them as Optional struct members, and select them on the wire via the existing
`.scalar("name")` path (Ash RPC loads them through the same `fields` param — no `FieldSelection`
or request-body change). Two non-obvious gotchas: (1) the manifest is public-only by default, so
private aggregates/calcs are excluded for free — no extra gating. (2) Unlike an attribute (where
`ash_type_to_swift` String-fallbacks an unknown type), a derived field's type is *computed*, not
author-controlled, so gate emission on `field.type.kind` and **skip** anything that isn't a
concrete scalar/enum (a `list` aggregate is `kind: :array, module: nil`) — a wrong String guess
silently mis-decodes, whereas omission is safe. See `@derived_scalar_kinds` /
`collect_aggregate_fields` in `codegen.ex` (issue #51).

## Test patterns

### Extend the fixture domain when the bug class needs it

Each completed ticket grew `test/support/` with a new fixture surface aimed at
its bug class — `StatusType` + `:case` for keyword escaping (#4); `Tag →
Category → Publisher` for the 2-hop relationship guard (#3); a `score:
:integer` attribute for non-String lookup keys (#5). When the review flags a
correctness issue the existing fixture can't reproduce, **add a fixture
slice that does**, then write the regression test against it. Don't rely
on the next ticket "happening to" cover the gap.

### CI green ≠ correct; the review is the second gate

Both `#19` (2-hop relationship bug) and `#23` (incomplete keyword list)
shipped CI-green from the implement workflow and only got caught by the
auto-review. Treat the review as a real gate, not noise — and when its
findings are a class (not a single case), extend the fixture so CI catches
that class going forward.

## Workflow patterns

### Steer `/address-review` when the agent might converge on a partial fix

The implement and address-review agents tend to copy-from-example: when the
review shows one keyword or one type as an illustration, the fix often
includes only that one. For findings that imply a *complete set*, comment
`/address-review` with explicit completeness criteria: "use the COMPLETE set
of X, not just the examples," and require a regression test for a member the
original list missed. Without the steer, expect a second `/address-review`
round. See PRs #23 and #26 for the pattern.

### CI's gates are the agent's gates

The implement and address-review prompts require running every CI gate
locally before pushing (`mix format` → `mix compile --warnings-as-errors` →
`mix test` → `swift test`). This is load-bearing: PR #14 shipped with a
format failure exactly because the agent ran `mix test` but not `mix
format`. If you add a new CI gate, mirror it in the prompts the same day.
