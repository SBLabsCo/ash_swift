# ADR-0010: Split codegen into Reader, Emitter, and TypeMap around a named IR

## Status

Accepted

## Context

With the `Ash.Info.Manifest` re-platform complete (ADR-0009), Swift codegen lived
in a single ~1900-line module, `AshSwift.Codegen`. Internally it was already a
compiler-shaped pipeline — read the manifest into an intermediate value, then
render that value to Swift — but the pipeline was implicit:

- The intermediate value (per-resource maps of fields, enums, actions, input
  structs, and sort/filter surface) flowed from the `collect_*` functions to the
  `render_*` functions with no name and no documented shape.
- The only test surface was `build_files/1 → %{path => source}`. Every test —
  including ones that only cared about *classification* (is this attribute an
  enum? which filter operator group?) — asserted on rendered-Swift substrings
  (~196 `=~` assertions in `codegen_test.exs`).
- The Ash-type → Swift mapping was spread across several private functions that
  could drift.

The monolith was externally deep (a tiny `build_files/1` interface over a large
implementation), so the friction was internal: navigability and testability, not
the public API.

The upstream `ash_typescript` (which ash_swift ports) already organises its
codegen as a `codegen/` directory of focused modules around an orchestrator,
threading plain maps (no structs) — precedent for both the split and the
representation choice.

## Decision

Split `AshSwift.Codegen` along its existing internal seam into three modules,
leaving the public API (`build_files/1`, `generate/2`, `stale_files/2`)
unchanged:

- **`AshSwift.Codegen`** — orchestrator. `build_files/1` calls `Reader.read/1`
  then `Emitter.render_types/1` + `Emitter.render_functions/1`.
- **`AshSwift.Codegen.Reader`** — `Ash.Info.Manifest` → **Codegen IR**. Sole
  entry point `read/1`. Knows Ash, AshTypescript, and `TypeMap`; knows nothing
  about Swift string formatting.
- **`AshSwift.Codegen.Emitter`** — Codegen IR → Swift source. Pure string work
  over the IR. Reads no manifest and never calls back into the Reader.
- **`AshSwift.Codegen.TypeMap`** — the single place an Ash type becomes a Swift
  type (scalar mapping, filter operator group, enum-case classification). A
  reader-side collaborator.

Representation decisions:

- **The IR stays plain maps**, named and documented (Reader's moduledoc), not
  typed structs. This matches upstream (which has zero `defstruct` in codegen)
  and keeps the split a near-pure code-movement. Promoting the IR to structs is
  a deliberately deferred follow-on, cheap to do later if a key-typo class of bug
  ever justifies it.
- **The seam is one-directional and pure**: Reader → IR → Emitter, with no
  cross-module private calls. `TypeMap` is consumed only by the Reader.

## Consequences

**Positive**

- Two real test surfaces instead of one. Classification logic is tested against
  the IR as data (`reader_test`) and the type table is tested directly
  (`type_map_test`, `ash_type_to_swift(Ash.Type.UUID) == "String"`), rather than
  only through rendered Swift.
- Locality: reader (classification) bugs and emitter (formatting) bugs now
  concentrate in separate modules.
- AI- and human-navigability: a 1900-line file becomes an orchestrator (~90
  lines) plus three focused modules.
- The named IR is the seam future property-based tests can target without driving
  the Swift compiler.

**Negative / risks**

- Three modules where there was one — slightly more file-hopping for a change
  that genuinely spans reading and emission (rare; the seam is narrow).
- One pragmatic wrinkle: `Emitter` needs `require Logger` because `pk_identity!`
  (correctly emitter-side — it is called from `method_spec`) warns on a missing
  primary key.

**Safety net**

- Each slice was proven output-preserving by the golden snapshot (byte-identical
  generated Swift) plus the full suite, including the `swift build` and wire
  round-trip tests. The golden snapshot, having served the ADR-0009 migration and
  this split, is then retired in favour of a determinism property test — its
  byte-for-byte job is done once the seam is stable.

**Do not re-litigate**

- This split is intentional. Future architecture reviews should not propose
  re-merging Reader/Emitter/TypeMap back into one module, nor "promoting" the
  plain-map IR to structs without a concrete bug motivating it.
