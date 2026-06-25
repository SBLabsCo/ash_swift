# The Swift compile harness needs the `swift` toolchain. When it's absent
# (e.g. a contributor on a machine without Swift), exclude those tests so the
# Elixir suite still runs, rather than hard-failing. Mirrors AshTypescript's
# `ExUnit.configure(exclude: ...)` approach for toolchain-dependent tests.
swift_exclude = if System.find_executable("swift"), do: [], else: [:swift_build]

ExUnit.configure(exclude: swift_exclude)
ExUnit.start()
