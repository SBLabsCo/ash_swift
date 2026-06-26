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
