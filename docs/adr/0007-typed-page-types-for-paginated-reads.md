# ADR-0007: Typed Page types for paginated read actions

## Status

Accepted (issue #16)

## Context

AshTypescript's RPC pipeline returns a different envelope shape for paginated vs unpaginated read
actions. Unpaginated: `{"success":true,"data":[...]}`. Offset-paginated:
`{"success":true,"data":{"results":[...],"hasMore":bool,"limit":int,"offset":int,"count":int|null}}`.
Keyset-paginated adds cursor fields (`after`, `before`, `nextPage`, `previousPage`). The M1
`runList` decoder assumed the bare-array shape; paginated actions threw `decodingFailed`.

The ADR-0002 idiomatic-Swift principle applies: transparent unwrapping of `results` would silently
drop pagination metadata (hasMore, limit, offset) the consumer may need, which is un-Swifty — Swift
prefers explicit, typed values over implicit dropping.

## Decision

Introduce two generic types in `AshSwiftRuntime`:

- `OffsetPage<T: Decodable & Sendable>` — wraps offset-paginated results with `results`, `hasMore`,
  `limit`, `offset`, `count`.
- `KeysetPage<T: Decodable & Sendable>` — wraps keyset-paginated results with `results`, `hasMore`,
  `limit`, `after`, `before`, `nextPage`, `previousPage`, `count`.

The runtime gains `runListOffset` and `runListKeyset` matching these types. The codegen detects
`ash_action.pagination.required? == true` at generation time and emits the correct return type and
method call; actions without required pagination keep their `[T]` return. Callers never need to
know the pagination shape — it is determined by the generated function signature.

## Consequences

- The generated function signature expresses pagination semantics statically (compile-time).
- Generated offset functions accept an `OffsetPageParams?` argument (limit, offset); generated
  keyset functions accept a `KeysetPageParams?` argument (limit, after, before). Both default to
  nil, which sends no `page` key in the request body and lets the backend use its default page.
- Optional pagination (required?: false) still returns `[T]`; no page param is sent, so the
  backend returns a bare array. Callers that want to pass a page param to optional-pagination
  actions are not yet supported — that is a future ticket.
- Unpaginated actions are unaffected (no regression to `[T]` callers).

## Addendum (issue #37): page arguments for optional-pagination reads

The "future ticket" above. This closes the gap for read actions that **support** offset/keyset
pagination but do not **require** it (`pagination offset?: true`/`keyset?: true`, `required?: false`)
— including the default ETS `:read`, whose data layer turns both flags on by default.

**Probed wire behavior** (live, via `AshTypescript.Rpc.run_action`): the response shape of an
optional-pagination action depends on the request. With **no** `page` key, the pipeline returns a
bare array (`{"data": [...]}`); with a `page` key, it returns the offset/keyset envelope
(`{"data": {"results": [...], "hasMore": ..., ...}}`). So the shape genuinely diverges per call —
the same un-Swifty `[T] | Page<T>` union AshTypescript surfaces in TypeScript (via a
`ConditionalPaginatedResult<Page, [T], Page<T>>` type whose result is conditional on the `page`
type argument).

**Decision:** mirror that conditional return in idiomatic Swift via **function overloading** rather
than a runtime union. An optional-pagination read emits two functions with the same name:

- `list(filter:sort:fields:) -> [T]` — the unchanged M1 bare-list function.
- `list(page:filter:sort:fields:) -> OffsetPage<T>` (or `KeysetPage<T>`) — the paginated overload,
  whose `page` argument is **required** (no default).

The required `page` is load-bearing: it's what makes Swift overload resolution pick the paginated
overload only when a caller passes `page:`, and the `[T]` overload otherwise. Each call site
resolves to exactly one static return type — no union ever surfaces to the caller. Omitting `page`
is byte-identical to M1, so existing `[T]` callers do not regress. When an action supports both
offset and keyset, the overload prefers offset (matching the required-pagination rule above); a
keyset-only action gets a `KeysetPage<T>` overload.

No runtime changes: the paginated overload reuses the existing `OffsetPageRequest`/`KeysetPageRequest`,
which already decode the envelope (the extra `type` discriminator key the pipeline adds is ignored
by `Codable`). `filter:` and `sort:` thread through both overloads unchanged, so all three compose
on the single paginated call.
