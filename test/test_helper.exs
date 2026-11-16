# The Swift compile harness needs the `swift` toolchain. When it's absent
# (e.g. a contributor on a machine without Swift), exclude those tests so the
# Elixir suite still runs, rather than hard-failing. Mirrors AshTypescript's
# `ExUnit.configure(exclude: ...)` approach for toolchain-dependent tests.
swift_exclude = if System.find_executable("swift"), do: [], else: [:swift_build]

# Capture log output per test so passing runs print no stray logger noise
# (e.g. AshSwift unmapped-type warnings from Codegen calls). Tests that assert
# on log text use ExUnit.CaptureLog explicitly and are unaffected.
ExUnit.configure(exclude: swift_exclude, capture_log: true)
ExUnit.start()

# The :swift_build suites share one SwiftPM consumer package per run
# (AshSwift.Test.SwiftConsumer); delete it once the suite finishes.
ExUnit.after_suite(fn _ -> AshSwift.Test.SwiftConsumer.cleanup() end)
