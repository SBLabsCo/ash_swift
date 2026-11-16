# AshSwift

AshSwift is an Elixir/Mix library — an Ash extension — that reads Ash resources and actions and generates type-safe **Swift** client code, so native Apple (iOS/macOS) apps can talk to an Elixir/Ash backend with end-to-end type safety. It is the Swift analog of [ash_typescript](https://github.com/ash-project/ash_typescript): same architecture, output language swapped.

## Language

**AshSwift**:
The Elixir extension itself — the package that performs codegen. Written in Elixir, distributed via Hex/Mix. _Avoid_: "the Swift library", "the Swift package" (those refer to generated output, not this).

**Generated client**:
The Swift source code AshSwift emits — types and RPC functions consumed by the Apple app. _Avoid_: "the bindings", "the SDK".

**Ash resource**:
The upstream Elixir definition (attributes, relationships, actions) that codegen reads. Owned by the backend app, not by AshSwift. _Avoid_: "model", "entity".

**RPC action**:
An Ash action exposed to clients through the domain's RPC configuration, for which AshSwift generates a callable Swift function. _Avoid_: "endpoint", "route".

**Codegen**:
The compile-time process (a Mix task) that reads the Ash API manifest and writes the generated client. _Avoid_: "build step", "transpile".

**API manifest** (`Ash.Info.Manifest`):
Ash's native, language-agnostic intermediate representation of a domain's resources, types, action entrypoints, and filter/sort/pagination capabilities (added in Ash 3.29). Codegen's sole metadata source (ADR-0009); the `typescript_rpc` config still gates which actions are exposed. _Avoid_: "schema dump", "reflection" — it is a structured IR, not raw `Ash.Resource.Info` introspection.

**Codegen IR**:
The intermediate representation codegen passes from manifest-reading to Swift-emission: plain (untyped) maps describing each resource and its fields, enums, actions, input structs, and sort/filter surface. Named as the seam between the **Reader** and **Emitter** (ADR-0010). _Avoid_: "AST", "schema" — it is codegen's own internal shape, neither Ash's manifest nor Swift syntax.

**Reader** (`AshSwift.Codegen.Reader`):
The manifest-facing half of codegen: reads `Ash.Info.Manifest` (plus the `typescript_rpc` config and `TypeMap`) into the **Codegen IR**. Sole entry point `read/1`. Knows about Ash; knows nothing about Swift string formatting. _Avoid_: "parser", "loader".

**Emitter** (`AshSwift.Codegen.Emitter`):
The Swift-facing half of codegen: pure string work turning the **Codegen IR** into the two generated `.swift` files (`render_types/1`, `render_functions/1`). Reads no manifest and never calls back into the **Reader**. _Avoid_: "printer", "renderer" (the functions are `render_*`, but the module is the Emitter), "serializer".

**TypeMap** (`AshSwift.Codegen.TypeMap`):
The single place an Ash type becomes a Swift type — scalar mapping, filter operator group, and enum-case classification. A reader-side collaborator (the **Emitter** consumes the resulting `swift_type` strings, never `TypeMap` itself). _Avoid_: "type converter", "coercion".

**AshSwiftRuntime**:
The small hand-written Swift support package the generated client depends on at runtime — base RPC client, request/response handling, error decoding, hook dispatch, config. Distinct from the generated client (which is emitted per-resource). _Avoid_: "SDK", "core".

**Transport**:
The injectable Swift protocol the runtime uses to actually send a request. Default implementation is URLSession-based; callers may supply their own (e.g. Alamofire). _Avoid_: "HTTP client", "fetcher".

**RpcRequest**:
A typed request value describing one RPC call — its request body and how to decode its result. The generated client constructs an `RpcRequest` and hands it to the runtime's single `execute` entry point. The common case (unwrap the response's `data` key) is covered by the `DataEnvelopeRequest` refinement; only destroy (void) and raw (data) supply a custom decode. _Avoid_: "command", "operation".

**execute**:
The runtime's one entry point that runs any `RpcRequest`: encode the body, POST it, validate the `{success, errors}` envelope, decode the result. Replaces the per-shape `run*` family — new request shapes become new `RpcRequest` values, not new methods on the client. _Avoid_: "call", "dispatch".

**Get action**:
A read action that returns **at most one** record (Ash `get?: true`, or a `get_by` read), so the generated client returns an optional rather than a list. "At most one" is the whole definition — it does not mean "look up by primary key". How (or whether) the caller narrows the result is the **lookup channel**, of which there are three:
- **Native `get_by`** (`read :get_by_id do get_by :id end`): the lookup fields are ordinary action inputs, so the key travels under `input` (indistinguishable from the read's own arguments in the manifest — the Reader recovers them from the action's `get_by`).
- **RPC-level `get_by`** (set on the `rpc_action` entry, not the Ash action): the key travels under `getBy`.
- **Pure `get?`** (`read :fetch do get? true end`, neither of the above): no lookup channel at all; the result is narrowed only by the action's own arguments (and filter), and the request sends no lookup key.

_Avoid_: "get by primary key" as the definition, and `identity` as a read's lookup key — the RPC pipeline ignores `identity` for reads; it is only used by update and destroy actions to pick the record to act on.

**Generic action**:
An Ash action of type `:action` — a command-style call (an auth bootstrap, an upload start) rather than a CRUD operation. Its arguments travel under the top-level `input` key, and its **return class** decides the generated Swift return type and whether the request carries `fields`:
- **Void** (no `returns`): responds `{"data": {}}`; the generated function returns nothing. No `fields`.
- **Scalar** (`:string`, `:integer`, …): decoded as the mapped Swift scalar. No `fields`.
- **Unconstrained map** (`returns :map`, no `fields:` constraints): decoded as `[String: AshJSON]`; keys are the caller's. No `fields`.
- **Typed-record return** (below): needs a `fields` selection.

The nilability of a resource/struct return comes from the live action's `allow_nil?` (default false), not the manifest. Arrays of resources are unsupported. _Avoid_: "Tier C" (a planning label from the PRD, not a domain term), "custom action" (Ash's "custom" means any non-default action, including reads), "RPC function" for the Swift side (that is the generated function for any **RPC action**).

**Typed-record return**:
A **Generic action** return the RPC pipeline requires a `fields` selection for (it rejects the request with `missing_required_parameter: fields` otherwise), so the generated function takes a required `fields:` argument. Two shapes, differing in the Swift type they decode into:
- **Constrained map** (`returns :map` with `fields:` constraints): a result struct generated for that action (`<Rpc>Result`, with nested structs for `{:array, :map}` fields). Not a resource model.
- **Resource / struct** (`returns :struct, constraints: [instance_of: Resource]`): the resource's own generated model type `T`, or `T?` when the action sets `allow_nil? true`.

_Avoid_: "field-selected return" and "resource/struct return" as names for the whole class (each names only part of it).
