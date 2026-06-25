# AshSwift

[![CI](https://github.com/SBLabsCo/ash_swift/actions/workflows/ci.yml/badge.svg)](https://github.com/SBLabsCo/ash_swift/actions/workflows/ci.yml)

**Type-safe Swift clients for [Ash](https://ash-hq.org) backends.**

AshSwift is an Elixir/Mix [Ash](https://ash-hq.org) extension that reads your Ash
resources and their RPC configuration and generates a type-safe **Swift** client —
`Codable` models plus `async`/`await` functions — so a native Apple (iOS/macOS)
app can talk to an Elixir/Ash backend with end-to-end type safety.

It is the Swift analog of
[ash_typescript](https://github.com/ash-project/ash_typescript): same
architecture, output language swapped. The generated Swift client talks JSON over
HTTP to the *same* RPC endpoint AshTypescript already serves, so a Swift client
and a TypeScript client stay wire-identical by construction.

> **Status: early.** Milestone 1 (the thin end-to-end happy path) is the current
> scope — core CRUD action types, ad-hoc field selection, and a zero-dependency
> URLSession runtime. Filters/sorting/pagination, typed queries, enums, hooks,
> and real-time support are later milestones. See
> [`docs/prd/m1-vertical-slice.md`](docs/prd/m1-vertical-slice.md) for the full
> roadmap and out-of-scope list.

## Features

- **End-to-end type safety** — generated `Codable` models and `async`/`await`
  functions mean a backend schema change surfaces as a Swift compile error or a
  reviewable diff, not a runtime decode failure.
- **Reuses your existing RPC config** — reads the domain's `typescript_rpc`
  configuration, so you don't maintain a second list of exposed actions for Swift.
- **Core action types** — generates a callable function for each exposed
  read/list, get, create, update, and destroy action. In M1, list/read actions
  are fully typed (`async throws -> [T]` with field selection); get, create,
  update, and destroy emit callable stubs — typed inputs and return values land
  in a later milestone.
- **Ad-hoc field selection** — request only the fields a screen needs; every model
  field is `Optional`, so unselected fields safely decode as `nil`.
- **Idiomatic Swift** — backend field and action names become Swift `camelCase`.
- **Zero-dependency runtime** — `AshSwiftRuntime` is hand-written over URLSession
  with no third-party dependencies, adding no supply-chain surface.
- **Pluggable transport** — swap the default URLSession transport for your own
  networking stack (e.g. Alamofire) via a protocol.
- **Deterministic, committable output** — regenerating with no schema change
  produces no diff.

Filters/sorting/pagination, typed (narrowed) queries, enums, embedded resources,
lifecycle hooks, and Phoenix Channel support are planned for later milestones —
see [`docs/prd/m1-vertical-slice.md`](docs/prd/m1-vertical-slice.md).

## Why

A developer building a native Apple app against an Ash backend has, until now, had
to hand-write Swift request/response models and networking that mirror the
backend's resources and actions. That hand-written layer drifts out of sync the
moment the backend changes — a renamed attribute, a new required argument, a
changed enum — and the mismatch surfaces as a runtime decode failure, not a
compile error. AshSwift removes that layer: regenerate, and a schema change shows
up as a reviewable diff and (where it matters) a compile error.

## How it works

The repo is two packages in one (a monorepo, [ADR-0005](docs/adr/0005-monorepo-dual-package-and-output-model.md)):

1. **AshSwift** — the Elixir/Mix Ash extension that performs codegen. A Mix task,
   `mix ash_swift.codegen`, walks your resources and the domain's existing RPC
   configuration and writes Swift source to a directory you choose.
2. **AshSwiftRuntime** — a small, hand-written Swift package
   (`Sources/AshSwiftRuntime/`) that the generated client depends on at runtime:
   the base RPC client, request/response handling, error decoding, and config.
   **Zero third-party dependencies** ([ADR-0004](docs/adr/0004-zero-dependency-generated-client.md)).

For M1, AshSwift reuses AshTypescript's language-agnostic RPC runtime, its
`typescript_rpc` DSL, and its HTTP endpoint unchanged — it adds only the Swift
codegen layer and the Swift runtime ([ADR-0003](docs/adr/0003-reuse-ashtypescript-rpc-runtime.md)).
No new server endpoint is built.

## Requirements

**Backend (codegen):**

- Elixir 1.17+
- Ash 3.0+
- AshTypescript ~> 0.17 (M1 reuses its RPC runtime and `typescript_rpc` DSL — [ADR-0003](docs/adr/0003-reuse-ashtypescript-rpc-runtime.md))
- A Phoenix app serving the AshTypescript RPC endpoint for the client to call at runtime

**Client (generated Swift + runtime):**

- Swift 5.9+
- iOS 16+ / macOS 13+

The platform baseline reflects `async`/`await` and modern `Codable`; confirm it
against your app's deployment target.

## Usage

### 1. Add the extension to your Ash project

In your backend's `mix.exs`:

```elixir
defp deps do
  [
    {:ash_swift, "~> 0.1"}
  ]
end
```

AshSwift reads your existing `typescript_rpc` configuration, so you don't maintain
a second list of exposed actions for Swift:

```elixir
defmodule MyApp.Domain do
  use Ash.Domain, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    resource MyApp.Todo do
      rpc_action :list_todos, :read
      rpc_action :get_todo, :get_by_id
      rpc_action :create_todo, :create
      rpc_action :update_todo, :update
      rpc_action :destroy_todo, :destroy
    end
  end

  # ...
end
```

### 2. Generate the Swift client

```sh
# Write to the configured output dir (default: swift/Generated)
mix ash_swift.codegen

# Or point it at your iOS app's source tree
mix ash_swift.codegen --output ../MyiOSApp/Sources/Generated

# Verify the committed Swift is up to date (for CI)
mix ash_swift.codegen --check
```

Configure the default output directory in `config/config.exs`:

```elixir
config :ash_swift, output_dir: "swift/Generated"
```

Output is **deterministic and written change-only** — regenerating with no schema
change produces no diff, so committing the generated Swift surfaces schema changes
as reviewable diffs ([ADR-0005](docs/adr/0005-monorepo-dual-package-and-output-model.md)).
Two files are emitted: `AshRpcTypes.swift` (the `Codable` models) and
`AshRpcFunctions.swift` (the RPC functions).

### 3. Add the runtime to your iOS app

Add `AshSwiftRuntime` via Swift Package Manager, and add the generated files to a
target that depends on it. Platform baseline is **iOS 16+ / macOS 13+,
Swift 5.9+** (`async`/`await` and modern `Codable`).

### 4. Call your backend

```swift
import AshSwiftRuntime

let config = AshRpcConfig(
    baseURL: URL(string: "https://api.example.com")!,
    headers: ["Authorization": "Bearer \(token)"]
)
let rpc = AshRpc(client: AshRpcClient(config: config))

// A list/read action returns typed results; select only the fields a screen needs.
let todos: [Todo] = try await rpc.listTodos(fields: ["id", "title", "completed"])

for todo in todos {
    print(todo.title ?? "")
}
```

Every selectable field on a generated model is `Optional` so that ad-hoc field
selection is safe — unselected fields decode as `nil` rather than failing to
decode. Backend errors surface as a thrown, typed `AshRpcError` you handle with
`do`/`catch`.

#### Custom transport

The runtime's HTTP layer is a pluggable `Transport` protocol; the default is
URLSession-based. Supply your own to integrate a different networking stack (e.g.
Alamofire) without AshSwift forcing a dependency on you:

```swift
struct MyTransport: Transport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // your networking stack here
    }
}

let client = AshRpcClient(config: config, transport: MyTransport())
```

## Development

This repo builds as both an Elixir/Mix package and a Swift SPM package.

```sh
# Elixir: codegen + unit tests
mix deps.get
mix test

# Swift: build and test the runtime
swift build
swift test
```

The test strategy asserts **external, observable behavior of codegen**: what
source is emitted (golden/structural assertions), whether the generated Swift
*compiles* against `AshSwiftRuntime` (a `swift build` over generated output —
type safety is the product), and whether it decodes real backend JSON
(a thin end-to-end wire-compat test). Codegen internals are not tested directly.

## Design decisions

The architecture is fixed by a set of ADRs in [`docs/adr/`](docs/adr/):

| ADR | Decision |
| --- | --- |
| [0001](docs/adr/0001-elixir-extension-emitting-swift.md) | AshSwift is an Elixir/Mix Ash extension that emits Swift — not a standalone Swift tool |
| [0002](docs/adr/0002-idiomatic-swift-over-literal-fidelity.md) | Where TypeScript and Swift diverge, idiomatic Swift wins over literal API fidelity |
| [0003](docs/adr/0003-reuse-ashtypescript-rpc-runtime.md) | M1 reuses AshTypescript's RPC runtime, DSL, and endpoint unchanged |
| [0004](docs/adr/0004-zero-dependency-generated-client.md) | The generated client and its runtime have zero third-party dependencies |
| [0005](docs/adr/0005-monorepo-dual-package-and-output-model.md) | One repo is both the Mix package and the Swift package; generated output is committed |
| [0006](docs/adr/0006-runtime-validation-is-a-non-goal.md) | No Zod-equivalent runtime schema validation; `Codable` is the decode boundary |

Domain terminology lives in [`CONTEXT.md`](CONTEXT.md).

## Contributing

1. Fork the repo and create a feature branch.
2. Make your change with tests on both sides as appropriate — `mix test` for
   codegen, `swift test` for the runtime.
3. Run `mix format`.
4. Open a pull request.

Issues and triage happen in [GitHub Issues](https://github.com/SBLabsCo/ash_swift/issues);
see [`docs/agents/`](docs/agents/) for how the issue tracker, triage labels, and
CI/AI automation are organized.

## Support

- **Bugs and feature requests:** [GitHub Issues](https://github.com/SBLabsCo/ash_swift/issues)
- **Roadmap and design rationale:** [`docs/prd/`](docs/prd/) and [`docs/adr/`](docs/adr/)

## License

Released under the MIT License. See [`LICENSE`](LICENSE) for details.
