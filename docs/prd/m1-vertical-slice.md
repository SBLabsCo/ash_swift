# PRD: AshSwift M1 — Vertical Slice

> Scope: Milestone 1 (the thin end-to-end happy path). M2–M4 are out of scope and become their own PRDs later. Architecture is fixed by ADR-0001 through ADR-0006; this PRD specifies the actionable M1 build.

## Problem Statement

A developer building a native Apple (iOS/macOS) app against an Elixir/Ash backend has no plug-n-play, type-safe way to talk to it. Today they hand-write Swift request/response models and networking code that mirror the backend's resources and actions. That hand-written layer drifts out of sync the moment the backend changes — a renamed attribute, a new required argument, a changed enum — and the mismatch surfaces as a runtime decode failure or a silently wrong request, not a compile error. AshTypescript solves exactly this for TypeScript web clients; Swift clients have no equivalent.

## Solution

AshSwift is an Elixir/Mix Ash extension that reads Ash resources and the domain's existing RPC configuration and generates a type-safe Swift client — Codable models plus async functions — that a Swift app calls directly, with no hand-written API layer. The generated client talks JSON over HTTP to the same RPC endpoint AshTypescript already serves, so the Swift client and any TypeScript client stay wire-identical by construction.

M1 delivers the core happy path: a developer adds Swift type names to their resources, runs `mix ash_swift.codegen`, and gets generated Swift that performs the standard CRUD action types (read/list, get, create, update, destroy) with ad-hoc field selection, enums, and basic configuration — over a zero-dependency URLSession runtime. This is the slice the project owner's own iOS app will consume first; real usage from that app drives later milestones.

## User Stories

**Backend developer (Elixir) — configuring and generating**

1. As a backend developer, I want to mark which Swift type name a resource maps to, so that the generated Swift models have stable, intentional names.
2. As a backend developer, I want AshSwift to read my existing `typescript_rpc` configuration, so that I don't maintain a second list of exposed actions for Swift.
3. As a backend developer, I want to run a single Mix task (`mix ash_swift.codegen`) to generate the Swift client, so that codegen fits the same workflow as the rest of my Ash tooling.
4. As a backend developer, I want to configure the output directory for the generated Swift files, so that they land inside my iOS app's source tree where Xcode expects them.
5. As a backend developer, I want the generated output split into a small number of files (e.g. types vs RPC functions), so that the output is navigable and diffs are readable.
6. As a backend developer, I want codegen to fail loudly with a clear message if a referenced action is not public, so that I catch misconfiguration at generation time, not at runtime.
7. As a backend developer, I want the generated output to be deterministic, so that regenerating with no schema change produces no diff.
8. As a backend developer, I want to commit the generated Swift to my app repo, so that schema changes show up as reviewable diffs.

**iOS developer (Swift) — consuming the client**

9. As an iOS developer, I want to add AshSwiftRuntime to my app via Swift Package Manager, so that the generated client has its supporting runtime with nothing else to install.
10. As an iOS developer, I want generated `async`/`await` functions for each exposed action, so that calling the backend reads like ordinary modern Swift.
11. As an iOS developer, I want each generated model to be a `Codable` struct, so that responses decode with no hand-written parsing.
12. As an iOS developer, I want to call a list/read action and receive typed results, so that I can render data without casting from dictionaries.
13. As an iOS developer, I want to call a get action that retrieves a single record by id or by a configured identity, so that single-record screens are type-safe.
14. As an iOS developer, I want get actions to reflect `get?`, `get_by`, and `not_found_error?` semantics, so that a missing record surfaces the way the backend intends.
15. As an iOS developer, I want to call a create action with a typed input, so that required arguments are enforced by the compiler before I send the request.
16. As an iOS developer, I want to call an update action with a typed input and a record identifier, so that I can mutate records safely.
17. As an iOS developer, I want to call a destroy action, so that I can delete records through the same generated surface.
18. As an iOS developer, I want to select which fields a call returns, so that I fetch only what a screen needs.
19. As an iOS developer, I want to select fields on nested relationships, so that I can fetch related data in one call.
20. As an iOS developer, I want unselected fields to come back as `nil` on the model rather than failing to decode, so that partial selection is safe.
21. As an iOS developer, I want backend enums represented as Swift enums, so that I get exhaustive `switch` handling and autocomplete.
22. As an iOS developer, I want field names presented in idiomatic Swift camelCase regardless of the backend's naming, so that the generated code reads like native Swift.
23. As an iOS developer, I want to configure the backend base URL once, so that all generated calls target the right host.
24. As an iOS developer, I want to attach custom headers (e.g. an auth bearer token), so that authenticated requests work without per-call boilerplate.
25. As an iOS developer, I want errors returned by the backend to surface as a thrown, typed Swift error, so that I can handle failures with `do`/`catch`.
26. As an iOS developer, I want to supply my own transport implementation conforming to a protocol, so that I can integrate a custom networking stack later without AshSwift forcing one on me.
27. As an iOS developer, I want the default transport to use URLSession with no third-party dependency, so that adopting AshSwift adds no supply-chain surface.

## Implementation Decisions

- **Project shape (ADR-0001):** AshSwift is an Elixir/Mix Ash extension that emits Swift; the generator runs at codegen time inside the Elixir app. It is not a standalone Swift tool.
- **Idiomatic-Swift principle (ADR-0002):** where TypeScript and Swift diverge, the Swift-idiomatic expression wins over literal API fidelity. This governs tie-breaks across the build.
- **Server runtime reuse (ADR-0003):** M1 depends on `ash_typescript` and reuses its language-agnostic RPC runtime, `typescript_rpc` DSL, and HTTP endpoint unchanged. AshSwift adds only a Swift codegen layer plus the Swift runtime. No new server endpoint is built. The north star (shared `ash_rpc` core) is out of scope for M1.
- **Resource Swift type names:** a resource-level configuration supplies the Swift type name for each resource. For M1, reuse the existing `type_name` where it already produces a valid Swift identifier; the codegen consumes it to name generated models.
- **Codegen entry point:** a Mix task, `mix ash_swift.codegen`, walks the configured resources/actions and writes Swift source to a configurable output directory, split into a small number of files (a types file and an RPC-functions file). Output is deterministic.
- **Generated models (ADR-0002, Q2 decision):** one `Codable` struct per resource, with **every selectable field Optional**. Ad-hoc field selection is a runtime field list; unselected fields decode as `nil`. True narrowed (non-optional) structs are the typed-queries feature, which is M2 — not M1.
- **Action coverage:** generate callable async functions for the core action types — read/list, get, create, update, destroy. Get actions honor `get?`, `get_by`, and `not_found_error?`.
- **Inputs:** create/update actions take a typed input value whose required arguments are compiler-enforced.
- **Enums:** backend enums generate Swift enums.
- **Field formatting:** output field names are camelCased for Swift idiom; this is the M1 formatting behavior (configurable separate input/output formatters are M2).
- **Runtime library (ADR-0004):** a hand-written `AshSwiftRuntime` Swift package holds the base RPC client — request encoding, endpoint POST, response/error decoding, and configuration (base URL, headers). Concurrency is `async`/`await`; failures surface via `throws` and a typed error enum. The HTTP layer is a **pluggable transport protocol** with a default URLSession implementation; **no third-party dependencies**.
- **Packaging (ADR-0005):** monorepo — this repo is both the Elixir Mix package (`lib/`, `mix.exs`) and the Swift SPM package (`Sources/AshSwiftRuntime/`, `Package.swift`). Because Swift resolves symbols by module, generated files added to a target depending on `AshSwiftRuntime` need no import-path resolution.
- **Transport scope:** HTTP only. Phoenix Channels are M4.
- **Validation (ADR-0006):** no Zod-equivalent runtime schema generation. `Codable` is the decode-boundary check. Form validation is M3.

## Testing Decisions

A good test here asserts **external, observable behavior of codegen** — what source is emitted, whether it compiles, and whether it decodes real backend JSON — never the internal structure of the codegen functions. Codegen internals will churn; the contract is the generated client and its wire behavior.

- **Primary seam — codegen output.** Drive `mix ash_swift.codegen` against a fixture Ash domain/resources (configured through the reused `typescript_rpc` DSL) and assert on the emitted Swift source. This is the single highest seam; nearly every M1 feature (models, enums, action functions, field selection, camelCasing, optionality) is observable here. Prefer structural/golden assertions on the generated output.
- **Compile check of generated Swift (essential).** A test must run `swift build` on the generated output against `AshSwiftRuntime` and assert it type-checks. Type-safety is the product, so a string-comparison test alone is insufficient. This directly mirrors AshTypescript's strategy of running `tsc` over its generated output — that is the prior art to follow.
- **Thin end-to-end wire-compat test.** A small number of integration tests run an Ash action in-process through the reused RPC pipeline and decode the real JSON response with the generated `Codable` models, proving server and Swift client agree on the wire. These guard wire compatibility; they are deliberately few — not a per-feature E2E suite.

Modules tested: the codegen Mix task (via its output), the generated Swift (via compilation), and the runtime + generated models together (via the E2E decode). Internal codegen helpers are not tested directly.

## Out of Scope

Everything past M1, specifically:

- Auto-generated filters, sorting, pagination (M2)
- Typed queries / narrowed non-optional result structs (M2)
- Embedded resources and deep relationship type support (M2)
- Field/argument name mapping for invalid Swift identifiers; configurable separate input/output formatters (M2)
- Unions, calculations with arguments (M3)
- Lifecycle hooks framework (M3); only static base-URL/header config is in M1
- Multitenancy (M3) — assumed not needed by the dogfood app for now
- Action metadata (M3)
- Form validation functions (M3)
- Phoenix Channel / real-time support (M4)
- Runtime validation / Zod-equivalent schema generation (non-goal, ADR-0006)
- A direct Alamofire target (only the pluggable transport protocol exists in M1)
- Extracting the shared `ash_rpc` core (north star, post-M1; ADR-0003)

## Further Notes

- **Assumptions to revisit via dogfooding:** the dogfood iOS app is assumed non-multitenant, and its auth is assumed to be a bearer token carried in a header (covered by M1's custom-header config). If either is false, multitenancy and/or a minimal hooks mechanism move earlier.
- **Platform baseline (revisitable):** `async`/`await` and modern Codable suggest targeting roughly iOS 16+ / Swift 5.9+. This is a recommendation, not a hard decision; confirm against the dogfood app's deployment target.
- **North star:** once M1 is proven, coordinate with the AshTypescript author (a coworker of the project owner) to extract the language-agnostic RPC runtime into a shared `ash_rpc` package, dropping AshSwift's `ash_typescript` dependency and the `typescript_rpc` naming (ADR-0003).
- **Driving input:** M2+ ordering should follow what the dogfood app actually needs next, not this document.
