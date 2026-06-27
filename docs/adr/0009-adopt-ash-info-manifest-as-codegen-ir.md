# ADR-0009: Adopt Ash.Info.Manifest as the codegen input IR

## Status

Proposed (issue #47)

## Context

Swift codegen ([lib/ash_swift/codegen.ex](../../lib/ash_swift/codegen.ex)) extracts resource
metadata by walking Ash's per-resource reflection directly: `Ash.Resource.Info.public_attributes/1`,
`public_relationships/1`, `action/2`, `primary_key/1`, plus bespoke logic to detect enums
(`Ash.Type.Atom` with `one_of`, and `Ash.Type.Enum` subtypes) and, for the in-flight M2 reads work,
hand-rolled introspection of which fields are sortable/filterable and what pagination an action
supports. This mirrors how the upstream `ash_typescript` (our pinned 0.17.3) does it.

Ash 3.29 added `Ash.Info.Manifest` ([ash#2703](https://github.com/ash-project/ash/pull/2703)),
described by its author as a "code generation basis": a **language-agnostic, JSON-serializable IR**
that traverses the type graph from a set of action entrypoints (or an OTP app) and emits structured
Elixir structs — resources, types, action entrypoints, relationships, and filter/sort capabilities —
with a `JsonSerializer` and a `mix ash.manifest.dump` task. `AshLua` already consumes it as its sole
metadata source, with an explicit "no `Ash.Resource.Info.*` traversal" boundary in its field layer,
and layers its own exposure DSL on top by annotating the manifest's entrypoints
(`AshLua.Surface`).

A spike (`mix ash.manifest.dump` against our test domain) confirmed the manifest covers **100%** of
the metadata codegen reads today and is **strictly richer** for M2 reads:

- Per-field `filterable` plus each field's own valid `filter_operators` / `filter_functions`
  (e.g. `title` gets `contains`/`string_starts_with`; an enum field does not) — a precise basis for a
  typed filter API.
- Per-field `sortable` — directly fixes the class of bug in #41 (SortField enum derivation).
- `entrypoints[].action.pagination` with `keyset` / `offset` / `countable` / `default_limit` /
  `max_page_size` / `required` — exactly the data ADR-0007 and #37 need.
- Enums in both forms: inline (`Ash.Type.Atom` `one_of` → type `kind: "enum"` with `values`) and
  named (`Ash.Type.Enum` → field type `kind: "type_ref"`, resolved in the top-level `types` list).

## Decision

Re-platform codegen to consume `Ash.Info.Manifest.generate/1` as its **sole** resource-metadata
source, removing direct `Ash.Resource.Info.*` traversal.

- **Exposure gating is preserved.** The manifest's `entrypoints` are every public action, not the
  `typescript_rpc`-exposed subset. We continue to drive *which* actions are emitted from the
  `typescript_rpc` DSL, intersecting it with manifest entrypoints — the same shape as
  `AshLua.Surface` annotating manifest entrypoints with its visibility layer. ADR-0003's reuse of the
  ash_typescript RPC runtime is unaffected; only the codegen *input* changes.
- **Re-platform before continuing #37.** The filter/sort/pagination support that issue #37 is
  currently hand-rolling becomes a near-trivial read off `filter_capabilities`, `sort_capabilities`,
  and `entrypoints[].action.pagination`. #37 is paused and will be rebuilt on the manifest rather
  than shipped on soon-to-be-replaced introspection.
- **Stage behind golden-file tests.** The swap must leave generated Swift byte-identical (or every
  diff intentional and reviewed). Determinism (generate-twice byte equality) and `swift build` over
  the output remain gates.

## Consequences

**Positive**

- Less bespoke introspection to own; one well-typed IR instead of scattered `Ash.Resource.Info`
  calls plus enum/pagination heuristics.
- #37 and #41 shrink dramatically — the data they need is handed over directly, and per-field
  operator lists enable a *more* precise filter surface than we could justify hand-rolling.
- Aligns ash_swift with the direction Ash itself is steering codegen, and advances the
  shared-`ash_rpc`-core north star: the manifest is the language-agnostic seam that core would sit on.

**Negative / risks**

- `Ash.Info.Manifest` is young (`schema_version` `1.0.0`); its JSON shape may churn. AshLua's
  production use is the main mitigant, and the version field lets us detect breaks.
- Our codegen *input* diverges from pinned ash_typescript 0.17.3, which still uses
  `Ash.Resource.Info`. Worth coordinating with the ash_typescript author (Torkan) — he may move
  ash_typescript onto the manifest too, which would re-converge the two.
- Sizable rewrite of a ~1450-line module; golden-file coverage is the safety net.

**Implementation notes (from the spike)**

- `fields` and `relationships` are name-keyed maps, not lists.
- The manifest only surfaces configured domains and what is reachable from them; each domain under
  test must be present in `ash_domains` config to appear.
