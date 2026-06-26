# PRD: AshSwift M2 — Powerful Reads (Filters, Sorting, Pagination Arguments)

> Scope: Milestone 2 (the query surface for read actions). M1 is fully shipped
> (issues #1–#7, plus discovered #16/#17/#24, all closed). Architecture is fixed
> by ADR-0001 through ADR-0007; this PRD specifies the actionable M2 build and
> does **not** revisit those decisions.
>
> Milestone theme (confirmed with the project owner): **Powerful Reads** — make
> read/list **RPC actions** actually drivable from the app by adding typed
> **filter**, **sort**, and **pagination** arguments. Result types stay
> all-Optional, exactly as M1 left them; typed/narrowed result structs are a
> later milestone, not this one.

## Problem Statement

After M1, an iOS developer can call a read **RPC action** through the
**generated client** and get typed results back — but only the action's default
result set. There is no type-safe way to *narrow* that set from Swift: no way to
filter ("only todos where `completed == false`"), no way to sort ("newest
first"), and no way to drive pagination beyond the page params M1 wired for
actions that *require* pagination. The backend's reused AshTypescript RPC
pipeline already accepts `filter`, `sort`, and `page` on the wire, so the
capability exists server-side — the **generated client** just doesn't expose it.

Today the iOS developer's only escape hatches are bad ones: fetch everything and
filter/sort in Swift (wasteful, and impossible across pages), or hand-write a raw
request body and lose the type safety AshSwift exists to provide. The moment a
list screen needs "active items, newest first, 20 at a time," the developer is
back to the hand-rolled, drift-prone layer M1 set out to eliminate.

## Solution

AshSwift's **codegen** learns to emit a typed query surface for read **RPC
actions**, mirroring — idiomatically, per ADR-0002 — what AshTypescript already
generates for filters and sorting:

- **Filters.** For each filterable **Ash resource**, codegen emits a typed
  filter input: one optional field per filterable attribute, each carrying the
  operators that attribute's type supports (`eq`, `notEq`, `in`, the numeric/date
  comparisons, `isNil`), plus `and`/`or`/`not` combinators. Generated read
  functions gain an optional `filter:` parameter. The filter value serializes to
  the map the server's `Ash.Query.filter_input` already consumes.
- **Sorting.** For each sortable **Ash resource**, codegen emits a typed
  sort-field surface (the sortable attributes) paired with a direction
  (ascending / descending, with nils-first / nils-last variants). Generated read
  functions gain an optional `sort:` parameter that serializes to the Ash sort
  string the server already parses.
- **Pagination arguments.** M1 (ADR-0007) already returns typed `OffsetPage<T>` /
  `KeysetPage<T>` for actions whose pagination is *required* and accepts page
  params for them. M2 closes ADR-0007's explicit gap: read actions that *support*
  pagination without requiring it can now be driven with page arguments too, and
  filter/sort compose with pagination on the same call.

Whether an action exposes filtering or sorting is gated by the **RPC action**'s
existing `enable_filter?` / `enable_sort?` flags (both default true): when an
action turns one off, the corresponding parameter simply isn't generated, so the
compiler — not a runtime error — stops you from filtering an action that forbids
it. This is the slice the dogfood iOS app needs to build real list screens, and
it stays wire-identical to any TypeScript client by construction (ADR-0003).

## User Stories

**iOS developer (Swift) — filtering**

1. As an iOS developer, I want to pass a typed filter to a read **RPC action**, so that the backend returns only the records a screen needs instead of everything.
2. As an iOS developer, I want each filterable attribute exposed as a typed field with only the operators its type supports, so that the compiler stops me from writing a nonsensical predicate (e.g. `greaterThan` on a Bool).
3. As an iOS developer, I want string attributes to offer equality and membership operators (`eq`, `notEq`, `in`), so that I can match exact values or a set of values.
4. As an iOS developer, I want numeric and date attributes to offer comparison operators (`greaterThan`, `greaterThanOrEqual`, `lessThan`, `lessThanOrEqual`) plus equality and membership, so that range queries are type-safe.
5. As an iOS developer, I want boolean attributes to offer just equality operators (`eq`, `notEq`), so that the generated surface matches what the type can meaningfully express.
6. As an iOS developer, I want enum-backed attributes to filter by the generated Swift enum (`eq`, `notEq`, `in`), so that filtering by status is autocompleted and exhaustive rather than stringly-typed.
7. As an iOS developer, I want nullable attributes to offer an `isNil` operator, so that I can ask for records where a value is present or absent.
8. As an iOS developer, I want to combine predicates with `and`, `or`, and `not`, so that I can express compound conditions without dropping to a raw map.
9. As an iOS developer, I want an unset filter field to be omitted from the request entirely, so that leaving operators nil means "no constraint" rather than "match null".
10. As an iOS developer, I want filtering only offered on actions whose **RPC action** allows it (`enable_filter?`), so that I get a compile error — not a silently dropped filter — when an action forbids filtering.

**iOS developer (Swift) — sorting**

11. As an iOS developer, I want to pass a typed sort to a read **RPC action**, so that results arrive in the order a screen needs.
12. As an iOS developer, I want to choose the sort field from a typed set of the resource's sortable attributes, so that I can't sort by a field that doesn't exist or isn't sortable.
13. As an iOS developer, I want to choose ascending or descending direction per field, so that "newest first" is one typed value, not a magic string.
14. As an iOS developer, I want to control nils-first / nils-last ordering for nullable fields, so that I can match the backend's full sort semantics when it matters.
15. As an iOS developer, I want to specify multiple sort fields in priority order, so that I can express tie-breaking (e.g. by status, then by date).
16. As an iOS developer, I want sorting only offered on actions whose **RPC action** allows it (`enable_sort?`), so that the compiler reflects what the backend will honor.

**iOS developer (Swift) — pagination arguments**

17. As an iOS developer, I want to pass page arguments to read actions that *support but don't require* pagination, so that I can page through large lists without the backend forcing pagination on every action.
18. As an iOS developer, I want filter, sort, and pagination to compose on a single call, so that "active todos, newest first, page 2" is one type-safe request.
19. As an iOS developer, I want the pagination metadata I already get from M1's `OffsetPage` / `KeysetPage` to keep working when I also filter and sort, so that "has more pages" stays correct under a narrowed query.
20. As an iOS developer, I want an omitted page argument to behave exactly as it did in M1, so that adding filter/sort support introduces no regression for existing call sites.

**iOS developer (Swift) — ergonomics & safety**

21. As an iOS developer, I want filter and sort parameters to default to nil, so that the simplest "fetch the default set" call I wrote in M1 still compiles unchanged.
22. As an iOS developer, I want filter field names and operators presented in idiomatic Swift camelCase, so that the query surface reads like native Swift even though the backend uses snake_case.
23. As an iOS developer, I want the typed filter and sort values to be the only inputs that touch the wire, so that I never hand-assemble the filter map or sort string myself.
24. As an iOS developer, I want a backend rejection of a malformed query to surface as the same thrown, typed `AshRpcError` M1 established, so that query failures are handled with the error-handling I already have.

**Backend developer (Elixir) — configuring & generating**

25. As a backend developer, I want AshSwift to read my **RPC action**'s `enable_filter?` / `enable_sort?` flags, so that I control which actions expose a query surface from one place I already configure.
26. As a backend developer, I want the filterable and sortable field sets derived from my resource's public attributes, so that I don't maintain a parallel list for Swift.
27. As a backend developer, I want the generated filter and sort types to be deterministic, so that regenerating with no schema change still produces no diff.
28. As a backend developer, I want codegen to keep emitting a small number of navigable files, so that adding filter/sort types doesn't sprawl the output.
29. As a backend developer, I want adding a new filterable attribute to a resource to surface as a reviewable diff in the generated filter type, so that the query surface tracks the schema.

## Implementation Decisions

- **Reuse the server query surface unchanged (ADR-0003).** The backend already
  accepts `filter` (a map fed to `Ash.Query.filter_input`), `sort` (a string with
  modifiers), and `page` on the reused AshTypescript RPC endpoint, gated by the
  **RPC action**'s `enable_filter?` / `enable_sort?` flags (default true). M2 adds
  no server endpoint and no new DSL — only **codegen** and **AshSwiftRuntime**
  Swift work. No new test seam is introduced (see Testing Decisions).
- **Idiomatic mirror of AshTypescript's filter model (ADR-0002).** AshTypescript
  emits a `{Resource}FilterInput` object: per-attribute operator fields plus
  `and?` / `or?` / `not?` logical operators. AshSwift emits the Swift-idiomatic
  analog — a `Codable` filter input value per **Ash resource** with one optional
  property per filterable attribute and `and` / `or` / `not` arrays of the same
  filter type — rather than a literal port of the TypeScript shape.
- **Operator sets are type-driven, taken from the authoritative classification.**
  Mirror AshTypescript's `FilterTypes` classification rather than the examples in
  any one review (per `docs/agents/lessons.md`, "use the authoritative source"):
  - string / ci-string → `eq`, `notEq`, `in`
  - numeric (integer, float, decimal) → `eq`, `notEq`, `greaterThan`,
    `greaterThanOrEqual`, `lessThan`, `lessThanOrEqual`, `in`
  - date / datetime → same comparison set as numeric
  - boolean → `eq`, `notEq`
  - enum (constrained atom) → `eq`, `notEq`, `in`
  - default (anything else) → `eq`, `notEq`, `in`
  - any nullable attribute additionally gets `isNil` (boolean).
- **Reusable operator types live in AshSwiftRuntime; per-resource filters compose
  them.** Following the `OffsetPage` / `KeysetPage` precedent (ADR-0007), the
  generic per-operator filter shapes (e.g. an equatable-only operator group, a
  comparable operator group) are hand-written generics in **AshSwiftRuntime**. The
  generated `{Resource}Filter` is thin: typed properties that instantiate those
  generics over the attribute's Swift type (including generated enums). This keeps
  per-resource generated code small and keeps the serialization logic in one
  hand-tested place.
- **Filter values serialize to the Ash `filter_input` map; operator key spelling
  is a probe-the-wire decision.** The generated filter encodes to the map shape
  `Ash.Query.filter_input` consumes (`{field: {operator: value}}`, with
  `and`/`or`/`not` arrays). Field names are emitted camelCase — the server's input
  formatter converts them back, exactly as M1 field selection relies on. The exact
  on-the-wire spelling of operator keys (camelCase vs snake_case, e.g. `notEq` vs
  `not_eq`, `greaterThan` vs `greater_than`) and the `isNil`/`is_nil` spelling MUST
  be probed against the live RPC pipeline before wiring, per the lessons-doc
  "probe with `AshTypescript.Rpc.run_action` and inspect the response" pattern; the
  generated types' `CodingKeys` then map Swift camelCase to whatever the wire
  requires. Do not assume the spelling.
- **Sort is a typed field set plus a direction, serialized to the Ash sort
  string.** Codegen emits, per sortable **Ash resource**, a typed set of its
  sortable attributes; the generated read function takes an ordered `sort:`
  argument of (field, direction) pairs. Direction covers ascending, descending,
  and the nils-first / nils-last variants, mapping to the Ash sort-string
  modifiers (`-` descending, `++` ascending-nils-first, `--` descending-nils-last,
  bare ascending). Field names are emitted camelCase; the server's
  `format_sort_string` converts them back. The string-assembly helper lives in
  **AshSwiftRuntime** so the modifier encoding is hand-tested once.
- **Filter/sort gating is compile-time, driven by `enable_filter?` /
  `enable_sort?`.** When an **RPC action** sets `enable_filter?: false`, codegen
  emits the read function *without* a `filter:` parameter (same for `enable_sort?`
  and `sort:`). A forbidden query is therefore a compile error at the call site,
  not a silently dropped param — the Swift-idiomatic outcome (ADR-0002).
- **Filterable/sortable field scope for M2: public attributes (including enums).**
  AshTypescript also exposes relationship, aggregate, and `field?: true`
  calculation filters. To keep M2 a thin slice, AshSwift M2 scopes both filtering
  and sorting to a resource's **public attributes** (enum attributes included).
  Relationship/aggregate/calculation filtering and sorting are explicitly deferred
  (see Out of Scope) and become their own later tickets once the dogfood app needs
  them.
- **Read functions gain `filter:` / `sort:` / page parameters, all defaulting to
  nil/empty.** Every generated read/list variant (the `[T]` form, the
  `OffsetPage<T>` form, and the `KeysetPage<T>` form) threads the new optional
  arguments through to the corresponding **AshSwiftRuntime** `runList*` method. A
  nil filter/sort is omitted from the request body (Swift `encodeIfPresent`),
  preserving M1 call-site behavior byte-for-byte when the new args are unused.
- **Close the ADR-0007 optional-pagination gap.** ADR-0007 deferred passing page
  params to actions whose pagination is *supported but not required*. M2 lets these
  actions accept page arguments alongside filter/sort. The response-shape behavior
  for optional pagination (bare array when no `page` is sent vs paginated envelope
  when one is) MUST be probed against the live pipeline before choosing the
  generated return type; pick the shape that keeps the call-site return type
  static (no `[T] | Page<T>` union leaking to the caller — that would be un-Swifty).
  Record the resolved behavior as an addendum to ADR-0007 rather than a new ADR.
- **Runtime request bodies extend, not fork.** `AshRpcClient`'s list request
  bodies (`RequestBody`, `PagedOffsetRequestBody`, `PagedKeysetRequestBody`) gain
  optional `filter` and `sort` members, omitted when nil. The single shared
  `JSONEncoder` and the success/error envelope handling are unchanged; this is the
  seam M1 deliberately left for "a later slice."
- **Determinism, keyword escaping, and imports carry the M1 invariants.** New
  emitters (filter types, sort field sets) sort by stable keys so regeneration
  produces no diff (`build_files`/`collect_resources` precedent). Every emitted
  identifier — filter field names, sort-field cases, operator properties — runs
  through `escape_swift_keyword/1` (lessons: keyword escaping must reach every
  emitter). If generated filter/sort types reference runtime generics, the
  generated types file must `import AshSwiftRuntime` (lessons: PR #30).

### Prototype-encoded shape (illustrative, trim before building)

The decision-bearing skeleton of the generated filter, to pin the operator/logical
structure precisely (names subject to the wire-spelling probe above):

```
// Per-resource, generated:
struct TodoFilter: Encodable {
  var status: EnumOperators<TodoStatus>?       // eq, notEq, in
  var priority: ComparableOperators<Int>?      // eq, notEq, <, <=, >, >=, in
  var completed: EquatableOperators<Bool>?     // eq, notEq
  var dueAt: ComparableOperators<Date>?        // comparisons + isNil (nullable)
  var and: [TodoFilter]?
  var or:  [TodoFilter]?
  var not: [TodoFilter]?
}
// Operator groups (EquatableOperators / ComparableOperators / EnumOperators)
// are hand-written generics in AshSwiftRuntime; isNil belongs to nullable fields.
```

## Testing Decisions

A good test here asserts **external, observable behavior of codegen** — the
emitted Swift source, whether it compiles, and whether a filtered/sorted/paged
query round-trips through the real RPC pipeline — never the internal structure of
the codegen functions. This milestone introduces **no new test seam**; it reuses
the three M1 seams:

- **Primary seam — codegen output (`codegen_test.exs`).** Drive
  `mix ash_swift.codegen` against the fixture domain and assert structurally on the
  emitted filter types, sort field sets, and the new read-function signatures.
  Assert the type-driven operator sets (a Bool attribute exposes only `eq`/`notEq`;
  a numeric exposes the comparisons; a nullable adds `isNil`; an enum filters over
  the generated Swift enum) and that `enable_filter?: false` / `enable_sort?: false`
  actions omit the corresponding parameter. Assert determinism by generating twice
  and comparing bytes.
- **Compile check of generated Swift (`swift_build_test.exs`).** Run `swift build`
  over the generated output plus **AshSwiftRuntime** and assert it type-checks —
  type safety is the product, so structural string assertions alone are
  insufficient. This is the AshTypescript-`tsc` strategy AshSwift already follows.
- **Thin end-to-end wire-compat test (`e2e_test.exs`).** Run a read **RPC action**
  in-process through the reused pipeline *with* a filter, a sort, and a page
  argument, and decode the real JSON with the generated models — proving the
  serialized filter map / sort string / page params are exactly what the server
  accepts. Keep these few: one filter round-trip, one sort round-trip, one
  filter+sort+page composition. This is where the operator-key and sort-modifier
  wire spellings are actually validated; probe with `AshTypescript.Rpc.run_action`
  first (lessons pattern) so the test encodes the confirmed shape.

**Fixture work.** Extend `test/support/` so the operator matrix is reproducible:
the `Todo` resource (or a sibling) needs at least one numeric, one date/datetime,
one boolean, one nullable, and one enum attribute that are public and
filterable/sortable, plus a read **RPC action** that leaves `enable_filter?` /
`enable_sort?` at default and a second action that disables them — so the gating
behavior has a fixture that exercises it (lessons: extend the fixture for the bug
class rather than hoping a later ticket covers it).

Modules tested: the **codegen** Mix task (via its output), the **generated
client** (via compilation), and the runtime + generated models together (via the
E2E filter/sort/page decode). Internal codegen helpers and the runtime's
operator-serialization generics are exercised through these seams, not asserted
directly.

## Out of Scope

Everything outside the read-query surface, specifically:

- **Typed / narrowed result structs** (a selected-fields call returning a struct
  whose chosen fields are non-Optional). Result types stay all-Optional as in M1.
  This was the alternative M2 framing and is deferred to a later milestone.
- **Relationship, aggregate, and `field?: true` calculation filtering and
  sorting.** M2 covers public attributes (including enums) only.
- **Embedded resources and deep relationship type support** (M2-bucket in the M1
  PRD; deferred).
- **Field/argument name mapping for invalid Swift identifiers; configurable
  separate input/output formatters** (deferred).
- **Unions, calculations with arguments** (later milestone).
- **Lifecycle hooks, multitenancy, action metadata, form validation** (later
  milestones; unchanged from the M1 PRD).
- **Phoenix Channel / real-time support** (latest milestone).
- **Runtime validation / Zod-equivalent schema generation** (non-goal, ADR-0006).
- **A direct Alamofire transport target** (only the pluggable **Transport**
  protocol exists; unchanged from M1).
- **Extracting the shared `ash_rpc` core** (north star, post-dogfood; ADR-0003).

## Further Notes

- **Driving input is the dogfood app.** Per the project's roadmap note, M2's
  content and the ordering of the slices below should follow what the dogfood iOS
  app's list screens actually need first (e.g. status filter + date sort may land
  before compound `and`/`or`/`not`). If the app needs relationship filtering sooner
  than expected, that item moves up out of "Out of Scope."
- **Two wire spellings must be probed before implementation, not assumed:** (1) the
  operator key spelling the RPC pipeline expects in the `filter_input` map, and (2)
  the optional-pagination response shape (bare array vs envelope) when a `page`
  arg is sent to a `required?: false` action. Both are exactly the kind of wire
  assumption `docs/agents/lessons.md` warns to probe with `AshTypescript.Rpc.run_action`
  before generating call sites. Resolving (2) should be captured as an addendum to
  ADR-0007.
- **Proposed slice breakdown (not yet filed — issues are a separate step).** A
  plausible ticket sequence, each independently shippable behind the existing
  seams:
  1. Runtime operator generics + sort-string helper in **AshSwiftRuntime** (no
     codegen yet; unit-covered via the Swift compile/test seam).
  2. Sort: typed sort-field set + `sort:` parameter on read functions, gated by
     `enable_sort?`; E2E sort round-trip.
  3. Filter: per-resource filter type (attributes + enums, type-driven operators,
     `isNil`), `filter:` parameter gated by `enable_filter?`; E2E filter round-trip.
  4. Logical combinators (`and`/`or`/`not`) on the filter type.
  5. Close the ADR-0007 optional-pagination page-argument gap; E2E
     filter+sort+page composition.
- **No ADR conflicts.** M2 operates entirely within ADR-0001..0007; it extends
  ADR-0007 (optional-pagination page args) via an addendum rather than a new
  decision, and adds no new architectural choice that would warrant its own ADR.
