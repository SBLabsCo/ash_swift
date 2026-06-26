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

> **Status: early, actively progressing.** Milestone 1 (the thin end-to-end happy
> path) is complete — core CRUD action types with typed inputs, ad-hoc field
> selection (incl. nested relationships), enums, typed get actions, custom headers,
> typed error handling, and a zero-dependency URLSession runtime. Milestone 2
> ("Powerful Reads") is in progress: typed **sorting**, typed **filtering** (attribute
> and enum predicates plus `and`/`or`/`not` combinators), and typed **pagination**
> (`OffsetPage`/`KeysetPage`) have landed; filter/sort/pagination composition is
> next. Typed (narrowed) queries, embedded resources, hooks, and
> real-time support are later milestones. See [`docs/prd/`](https://github.com/SBLabsCo/ash_swift/tree/main/docs/prd) for the
> roadmap and [GitHub Issues](https://github.com/SBLabsCo/ash_swift/issues) for
> what's in flight.

## Features

- **End-to-end type safety** — generated `Codable` models and `async`/`await`
  functions mean a backend schema change surfaces as a Swift compile error or a
  reviewable diff, not a runtime decode failure.
- **Reuses your existing RPC config** — reads the domain's `typescript_rpc`
  configuration, so you don't maintain a second list of exposed actions for Swift.
- **Core action types** — generates a callable function for each exposed
  read/list, get, create, update, and destroy action. List/read actions are
  fully typed (`async throws -> [T]` with field selection); get actions reflect
  `get?` / `get_by` / `not_found_error?` and return `T` or `T?` accordingly;
  create/update/destroy take compiler-enforced typed input structs.
- **Ad-hoc field selection** — request only the fields a screen needs, including
  fields on nested relationships. Every model field is `Optional`, so unselected
  fields safely decode as `nil`.
- **Typed filtering** — read actions take an optional, type-safe `{Resource}Filter`
  where each attribute exposes only the operators its type supports (equality for
  booleans, comparisons for numbers and dates, membership for strings and enums),
  and nullable attributes add `isNil`. Compound predicates compose through typed
  `and`/`or`/`not` combinators. Filtering an action off (`enable_filter?: false`)
  drops the parameter, so a forbidden filter is a compile error.
- **Typed sorting** — read actions take a typed sort over a generated
  sortable-field enum, with ascending/descending and nils-first/last ordering,
  gated per action by `enable_sort?`.
- **Typed pagination** — read actions with required pagination return
  `OffsetPage<T>` / `KeysetPage<T>` with typed page params and metadata.
- **Faithful type mappings** — extended Ash types map to real Swift types
  (`Decimal`/`Date` → `String` for precision and format fidelity,
  `UtcDatetime` → `Date`, `Map` → typed JSON) rather than a blanket `String` fallback.
- **Backend enums become Swift enums** — exhaustive `switch` handling and
  autocomplete; reserved-keyword values are backtick-escaped.
- **Custom headers & typed errors** — per-client headers (e.g. auth tokens);
  backend failures surface as a thrown, typed `AshRpcError`.
- **Idiomatic Swift** — backend field and action names become Swift `camelCase`.
- **Zero-dependency runtime** — `AshSwiftRuntime` is hand-written over URLSession
  with no third-party dependencies, adding no supply-chain surface.
- **Pluggable transport** — swap the default URLSession transport for your own
  networking stack (e.g. Alamofire) via a protocol.
- **Deterministic, committable output** — regenerating with no schema change
  produces no diff.

Filter/sort/pagination composition, typed (narrowed) queries, embedded resources,
lifecycle hooks, and Phoenix Channel support are planned for upcoming milestones —
see [`docs/prd/`](https://github.com/SBLabsCo/ash_swift/tree/main/docs/prd).

## Why

A developer building a native Apple app against an Ash backend has, until now, had
to hand-write Swift request/response models and networking that mirror the
backend's resources and actions. That hand-written layer drifts out of sync the
moment the backend changes — a renamed attribute, a new required argument, a
changed enum — and the mismatch surfaces as a runtime decode failure, not a
compile error. AshSwift removes that layer: regenerate, and a schema change shows
up as a reviewable diff and (where it matters) a compile error.

## How it works

The repo is two packages in one (a monorepo):

1. **AshSwift** — the Elixir/Mix Ash extension that performs codegen. A Mix task,
   `mix ash_swift.codegen`, walks your resources and the domain's existing RPC
   configuration and writes Swift source to a directory you choose.
2. **AshSwiftRuntime** — a small, hand-written Swift package
   (`Sources/AshSwiftRuntime/`) that the generated client depends on at runtime:
   the base RPC client, request/response handling, error decoding, and config.
   **Zero third-party dependencies.**

AshSwift reuses AshTypescript's language-agnostic RPC runtime, its
`typescript_rpc` DSL, and its HTTP endpoint unchanged — it adds only the Swift
codegen layer and the Swift runtime.
No new server endpoint is built.

## Requirements

**Backend (codegen):**

- Elixir 1.17+
- Ash 3.0+
- AshTypescript ~> 0.17 (M1 reuses its RPC runtime and `typescript_rpc` DSL)
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
as reviewable diffs.
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

Filtering and sorting are typed too. Each attribute on the generated
`{Resource}Filter` exposes only the operators its type supports, and sort fields
come from a generated enum — both are optional, so existing call sites are
unaffected:

```swift
var filter = TodoFilter()
filter.completed = EquatableOperators(eq: false)        // Bool: equality only
filter.priority = NullableEnumOperators(in: [.high, .medium])

let urgent: [Todo] = try await rpc.listTodos(
    filter: filter,
    sort: [SortField(.priority, .descending)],
    fields: ["id", "title", "priority"]
)
```

Compound predicates compose through the `and`/`or`/`not` combinators — each an
array of the same filter type, so they nest arbitrarily:

```swift
// completed == false AND (priority in [.high, .medium] OR score > 8)
var done = TodoFilter()
done.completed = EquatableOperators(eq: false)

var byPriority = TodoFilter()
byPriority.priority = NullableEnumOperators(in: [.high, .medium])

var byScore = TodoFilter()
byScore.score = NullableComparableOperators(greaterThan: 8)

var anyUrgent = TodoFilter()
anyUrgent.or = [byPriority, byScore]

var filter = TodoFilter()
filter.and = [done, anyUrgent]

let actionable: [Todo] = try await rpc.listTodos(filter: filter, fields: ["id", "title"])
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

The architecture rests on a few fixed decisions:

- AshSwift is an Elixir/Mix Ash extension that emits Swift — not a standalone Swift tool.
- Where TypeScript and Swift diverge, idiomatic Swift wins over literal API fidelity.
- Reuses AshTypescript's RPC runtime, DSL, and endpoint unchanged.
- The generated client and its runtime have zero third-party dependencies.
- One repo is both the Mix package and the Swift package; generated output is committed.
- No Zod-equivalent runtime schema validation; `Codable` is the decode boundary.

Domain terminology lives in [`CONTEXT.md`](https://github.com/SBLabsCo/ash_swift/blob/main/CONTEXT.md).

## Contributing

1. Fork the repo and create a feature branch.
2. Make your change with tests on both sides as appropriate — `mix test` for
   codegen, `swift test` for the runtime.
3. Run `mix format`.
4. Open a pull request.

Issues and triage happen in [GitHub Issues](https://github.com/SBLabsCo/ash_swift/issues);
see [`docs/agents/`](https://github.com/SBLabsCo/ash_swift/tree/main/docs/agents) for how the issue tracker, triage labels, and
CI/AI automation are organized.

## Support

- **Bugs and feature requests:** [GitHub Issues](https://github.com/SBLabsCo/ash_swift/issues)
- **Roadmap and design rationale:** [`docs/prd/`](https://github.com/SBLabsCo/ash_swift/tree/main/docs/prd)

## License

Released under the MIT License. See [`LICENSE`](https://github.com/SBLabsCo/ash_swift/blob/main/LICENSE) for details.
