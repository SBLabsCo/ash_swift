# Monorepo: one repo is both the Elixir Mix package and the Swift SPM runtime package

This repo is simultaneously an Elixir/Mix package (the codegen extension: `mix.exs` + `lib/`) and a Swift SPM package (the runtime: `Package.swift` + `Sources/AshSwiftRuntime/`). `mix.exs` and `Package.swift` coexist at the repo root, so a single repo serves both ecosystems. Versions move together, which suits a solo maintainer. We can split `AshSwiftRuntime` into its own repo later if SPM tooling friction (it occasionally assumes package-at-root) or a desire to keep the Swift package's repo Swift-only justifies it.

## Output model

- **Generated client output:** codegen writes `.swift` files into a **configurable output directory** in the consuming app's source tree (mirrors ash_typescript's configurable `output_file`), split across a few files (e.g. `AshRpc.swift`, `AshTypes.swift`). Unlike TypeScript, Swift resolves symbols by module, not file path — so there is no import-path resolution to do; generated files added to a target that depends on `AshSwiftRuntime` just work.
- **Committed, not gitignored:** consuming apps commit their generated output so schema changes show up as reviewable diffs — matching common ash_typescript practice.
