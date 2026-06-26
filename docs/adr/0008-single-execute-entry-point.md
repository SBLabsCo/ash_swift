# ADR-0008: A single `execute` entry point over a per-shape `run*` family

## Status

Accepted

## Context

The M1 runtime grew one method per action shape on `AshRpcClient`: `runRaw`,
`runList`, `runListOffset`, `runListKeyset`, `runGet`, `runGetOptional`,
`runCreate`, `runUpdate`, `runDestroy`. Each was a five-line pass-through over
the same wire round-trip (encode body → POST → validate the `{success, errors}`
envelope → decode `data`), paired with its own private body struct and `data`
envelope struct. The interface was wide and shallow: every new wire shape (bulk
actions, generic actions, future AshTypescript features) meant another public
method plus another body/envelope pair, and the generated codegen carried a
matching `render_method` clause that hand-rolled the Swift function from scratch.

## Decision

The runtime exposes one method:

```swift
func execute<R: RpcRequest>(_ request: R) async throws -> R.Output
```

Each action shape is an `RpcRequest` value that owns its request `Body` and how
to `decode` its result. The common case — unwrap the response's single `data`
key — lives once in the `DataEnvelopeRequest` refinement; only destroy (void)
and raw (data) supply a custom `decode`. `execute` owns the shared wire
round-trip and envelope validation, then delegates the `data` decode back to the
request. The nine request types (`ListRequest`, `OffsetPageRequest`,
`KeysetPageRequest`, `GetRequest`, `GetOptionalRequest`, `CreateRequest`,
`UpdateRequest`, `DestroyRequest`, `RawRequest`) and their bodies live together
in `RpcRequest.swift`.

The codegen emits each generated wrapper through a structured `MethodSpec` (pure
per-shape data) rendered by a single `render_spec`, so the Swift function
template — header, return clause, and the `execute(SomeRequest(...))` body — has
exactly one emission site.

## Consequences

- The client interface is one method wide. New action shapes become new
  `RpcRequest` conformances, not new methods — leverage for callers, locality
  for the maintainer.
- Body construction (e.g. omitting empty `input`/`getBy` dicts, omitting a nil
  `page`) is now a pure `makeBody()` function at a public seam, unit-testable
  without a transport. The `{data}`-unwrap and decode-error wrapping each live in
  one place.
- Return-type inference flows through `execute` for every generated wrapper
  (`Output` is a phantom generic pinned by the wrapper's declared return type),
  verified by the e2e cross-language compile gate.
- Trade-off: nine public request types plus their body structs are a secondary
  public surface. App authors still call the generated `rpc.listTodos(...)`
  wrappers; only generated code and the runtime's own tests construct request
  values, so this surface is optimised for codegen-emission clarity, not
  hand-authoring.
- The executor seam is shape-agnostic, which fits the shared `ash_rpc` north
  star (ADR-0003): the runtime no longer enumerates action shapes in its
  interface.
