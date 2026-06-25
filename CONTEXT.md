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
The compile-time process (a Mix task) that walks Ash resources and writes the generated client. _Avoid_: "build step", "transpile".

**AshSwiftRuntime**:
The small hand-written Swift support package the generated client depends on at runtime — base RPC client, request/response handling, error decoding, hook dispatch, config. Distinct from the generated client (which is emitted per-resource). _Avoid_: "SDK", "core".

**Transport**:
The injectable Swift protocol the runtime uses to actually send a request. Default implementation is URLSession-based; callers may supply their own (e.g. Alamofire). _Avoid_: "HTTP client", "fetcher".
