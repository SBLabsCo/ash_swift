# ADR-0011: Extract a shared `ash_rpc` core from ash_typescript

## Status

Accepted

Supersedes [ADR-0003](0003-reuse-ashtypescript-rpc-runtime.md) (which named this
extraction — "Option C" — as the north star and deferred it).

## Context

For v1, ash_swift depends on the whole `ash_typescript` package and reuses its RPC
runtime, its `typescript_rpc` DSL, and its HTTP endpoint unchanged (ADR-0003).
That was the fastest path to a working dogfood, and it bought wire compatibility
for free: one RPC configuration on the server feeds both a TypeScript web client
and the generated Swift client hitting the same endpoint. ADR-0003 accepted two
costs as temporary:

1. A hard dependency on all of `ash_typescript` — esbuild/npm/vite installers,
   zod/valibot generators, React scaffolding — none of which ash_swift uses.
2. A DSL named `typescript_rpc`, surfaced in every Swift-only app's domain.

ADR-0003 also recorded *why* the extraction is realistic rather than aspirational:
the ash_typescript author is a coworker of the project owner, so upstream
coordination is direct (see the `[[ashtypescript-author-is-coworker]]` context).

Two things have now made the extraction concrete. First, ADR-0009 moved ash_swift's
codegen *input* onto `Ash.Info.Manifest` — the language-agnostic seam a shared core
would sit on — so the two libraries already agree on the metadata IR. Second, a
boundary audit of the vendored `ash_typescript` (pinned 0.17) confirmed the split
is clean:

- **ash_swift's actual coupling is narrow.** ash_swift is codegen-only; it never
  invokes the RPC runtime pipeline. At compile time it touches only the
  `typescript_rpc` DSL + `AshTypescript.Rpc.Info.typescript_rpc/1`
  ([reader.ex](../../lib/ash_swift/codegen/reader.ex):52,110,184),
  `AshTypescript.Resource.Info`, `AshTypescript.FieldFormatter`,
  `AshTypescript.output_field_formatter/0`, and `AshTypescript.Rpc.not_found_error?/0`.
- **The runtime under `lib/ash_typescript/rpc/` is separable.** The request
  pipeline, field-selection processing, input/output/value formatters, and the
  error stack are pure JSON-in/JSON-out with no TypeScript. The only tangles from
  runtime *into* the codegen namespace are two misplaced pure-introspection helpers
  (`Rpc.Codegen.Helpers.ActionIntrospection` and two functions of
  `Rpc.Codegen.TypeGenerators.MetadataTypes`, both reached from `pipeline.ex`) and
  the `TypedQuery` entity's TypeScript-specific naming fields
  (`ts_result_type_name`, `ts_fields_const_name`).

## Decision

Execute the extraction: create a shared `ash_rpc` library holding the
language-agnostic RPC runtime + DSL, and make both `ash_typescript` and `ash_swift`
depend on it. Rename the DSL section `typescript_rpc` → `rpc`.

**Ownership & home.** `ash_rpc` incubates as a new repo under **SBLabsCo** (for
velocity, alongside ash_swift), with the intent to propose upstreaming to
`ash-project` once stable. Until it is Hex-published, ash_swift consumes it via a
git/path dependency.

**Clean break on the rename.** `typescript_rpc` becomes `rpc` outright, with no
deprecation alias or compatibility shim. For ash_typescript this is a **breaking
DSL change shipped as a major version** with an upgrade guide; the ash_typescript
author owns that release's timing. ash_swift is pre-1.0 with a small blast radius,
so it simply adopts `rpc`.

**What moves into `ash_rpc` (`AshRpc.*`):** the `rpc` DSL extension and its
verifiers, `Rpc.Info`, the runtime pipeline (`pipeline`, `request`,
`requested_fields_processor`, `result_processor`, `field_extractor`,
`field_processing/*`, the input/output/value formatters, the `error*` stack and
`default_error_handler`), plus the shared introspection surface `FieldFormatter`,
`TypeSystem.*`, `Resource.Info`, and the runtime-relevant config accessors
(`output`/`input_field_formatter`, `not_found_error?`, tenant parameters).

**What stays in `ash_typescript`:** all TypeScript codegen (`rpc/codegen/*`,
`codegen/*`, zod/valibot, `validation_error_schemas`), the installers, the
`typed_controller`/`typed_channel` extensions, `verify_rpc_warnings` (codegen-
coupled), and TS-specific config. Its codegen reads `AshRpc.Info` for the DSL.

**Phasing.** The work is ordered to de-risk the split before any repo moves:

- **Phase 0 — Coordinate.** Confirm the plan with the ash_typescript author,
  including that the rename lands as an ash_typescript major.
- **Phase 1 — De-tangle inside ash_typescript (ships alone).** Relocate
  `ActionIntrospection` and the two `MetadataTypes` introspection functions out of
  the `Rpc.Codegen.*` namespace into a runtime-side module. Pure refactor, no
  user-visible change; proves the runtime/codegen seam.
- **Phase 2 — Create `ash_rpc`.** Move the core modules; rename the section
  `typescript_rpc` → `rpc` (and `Rpc.Info.typescript_rpc/1` → `Rpc.Info.rpc/1`);
  port the runtime tests. `TypedQuery`'s core form is generic — the `ts_*` naming
  fields stay in an ash_typescript-side extension of the entity, not core.
- **Phase 3 — ash_typescript depends on `ash_rpc`.** Delete moved code; repoint
  codegen at `AshRpc.Info`; ship the breaking major with an upgrade guide.
- **Phase 4 — ash_swift adopts `ash_rpc`** (this repo): swap the dep in
  [mix.exs](../../mix.exs); rename `AshTypescript.*` → `AshRpc.*` aliases and
  `RpcInfo.typescript_rpc/1` → `RpcInfo.rpc/1` in
  [reader.ex](../../lib/ash_swift/codegen/reader.ex); `config :ash_typescript` →
  `config :ash_rpc` in [config/config.exs](../../config/config.exs); update
  `import_deps` in [.formatter.exs](../../.formatter.exs); and rename
  `typescript_rpc` → `rpc` in docstrings ([ash_swift.ex](../../lib/ash_swift.ex),
  [codegen.ex](../../lib/ash_swift/codegen/codegen.ex), the mix task) and test
  support.
- **Phase 5 — Record.** This ADR; update CONTEXT.md.

Only Phases 4–5 land in the ash_swift repo. Phases 0–3 are in the new `ash_rpc`
repo and in `ash_typescript`.

## Consequences

**Positive**

- ash_swift drops the esbuild/npm/zod/React baggage — a Swift-only app no longer
  pulls the TypeScript toolchain to generate a client.
- The `typescript_rpc` naming wart is gone from Swift-only domains; the DSL reads
  `rpc do … end`.
- One well-tested runtime, not two. The subtle field-selection/formatting/error
  logic lives in a single shared package instead of being forked (the Option B we
  rejected in ADR-0003 for exactly this drift risk).
- Wire compatibility is preserved structurally: the server-side runtime that
  produces the JSON both clients consume is the shared core, so TS and Swift
  clients cannot silently diverge from it.

**Negative / risks**

- Cross-repo coordination and release ordering: ash_swift's Phase 4 is gated on
  `ash_rpc` existing and on the ash_typescript major. A git/path dep unblocks
  ash_swift before the Hex release.
- The rename is breaking for existing ash_typescript users (mitigated by the
  major-version bump + upgrade guide; that cost is owned upstream, not by ash_swift).
- A new package to maintain until/unless it upstreams to `ash-project`; the
  SBLabsCo-incubation choice trades a later migration for near-term velocity.

**Do not re-litigate**

- The decision to depend on a shared `ash_rpc` rather than continue depending on
  all of `ash_typescript` (ADR-0003) or fork the runtime into `AshSwift.Rpc`
  (Option B). Both were considered and set aside.
- The clean-break rename. A deprecation alias for `typescript_rpc` was weighed
  against a major-version bump and rejected in favour of the simpler code path.
