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

**AshSwiftRuntime**:
The small hand-written Swift support package the generated client depends on at runtime — base RPC client, request/response handling, error decoding, hook dispatch, config. Distinct from the generated client (which is emitted per-resource). _Avoid_: "SDK", "core".

**Transport**:
The injectable Swift protocol the runtime uses to actually send a request. Default implementation is URLSession-based; callers may supply their own (e.g. Alamofire). _Avoid_: "HTTP client", "fetcher".

**RpcRequest**:
A typed request value describing one RPC call — its request body and how to decode its result. The generated client constructs an `RpcRequest` and hands it to the runtime's single `execute` entry point. The common case (unwrap the response's `data` key) is covered by the `DataEnvelopeRequest` refinement; only destroy (void) and raw (data) supply a custom decode. _Avoid_: "command", "operation".

**execute**:
The runtime's one entry point that runs any `RpcRequest`: encode the body, POST it, validate the `{success, errors}` envelope, decode the result. Replaces the per-shape `run*` family — new request shapes become new `RpcRequest` values, not new methods on the client. _Avoid_: "call", "dispatch".
