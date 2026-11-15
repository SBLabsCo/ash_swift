defmodule AshSwift.Test.SwiftConsumer do
  @moduledoc """
  Test harness for the `:swift_build` suites: a throwaway SwiftPM consumer
  package that depends on `AshSwiftRuntime` the way a real app would (ADR-0005).

  `shared_package/0` builds **one** package per `mix test` run. The generated
  client for `AshSwift.Test.Domain` is written into it once, and every test adds
  its own XCTest file and runs `swift test --filter <Class>`. `.build` is reused,
  so `AshSwiftRuntime`, the generated client and XCTest compile once and later
  runs are incremental. The package is deleted by `cleanup/0` (wired into
  `ExUnit.after_suite/1` in `test_helper.exs`).

  `run_swift_test!/2` writes a test's Swift file into the shared test target and
  removes it again when the test exits, so the target only ever holds the running
  test's file and one test's compile error can never fail another. The generated
  client is compiled once (`swift build`, memoized after the first success); if
  that fails the message says the *shared generated client* failed to compile,
  not the test.

  Tests that need different generated output (the sort-less resource check) use
  `fresh_package/2` and own their build.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias AshSwift.Codegen

  @domains [AshSwift.Test.Domain]
  @key {__MODULE__, :shared}
  @built_key {__MODULE__, :built}

  @doc "Path of the run-wide shared package, generating the client on first use."
  def shared_package do
    case :persistent_term.get(@key, nil) do
      nil ->
        tmp = fresh_package("ash_swift_shared", tests: true)

        # If generation fails, drop the half-built package (it is never
        # registered, so `cleanup/0` could not find it) and re-raise.
        try do
          sources = sources_dir(tmp)
          {:ok, _} = Codegen.generate(@domains, sources)

          # A hand-written consumer exercising the emitted surface, compiled with
          # the client so every build also proves the surface is usable.
          File.cp!(
            Path.join(File.cwd!(), "test/support/swift/ConsumerCheck.swift"),
            Path.join(sources, "ConsumerCheck.swift")
          )
        catch
          kind, reason ->
            File.rm_rf!(tmp)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

        :persistent_term.put(@key, tmp)
        tmp

      tmp ->
        tmp
    end
  end

  @doc """
  A new, unshared package (library target only unless `tests: true`). The
  caller must register `on_exit(fn -> File.rm_rf!(path) end)`; the shared one is
  removed by `cleanup/0`.
  """
  def fresh_package(prefix, opts \\ []) do
    repo_root = File.cwd!()
    tmp = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(sources_dir(tmp))

    runtime =
      ".product(name: \"AshSwiftRuntime\", package: " <>
        "#{inspect(String.downcase(Path.basename(repo_root)))})"

    test_target =
      if opts[:tests] do
        File.mkdir_p!(tests_dir(tmp))

        ~s|,\n        .testTarget(name: "E2ETests", dependencies: ["GeneratedClient", #{runtime}])|
      else
        ""
      end

    File.write!(Path.join(tmp, "Package.swift"), """
    // swift-tools-version:5.9
    import PackageDescription

    let package = Package(
        name: "GeneratedClientE2E",
        platforms: [.iOS(.v16), .macOS(.v13)],
        dependencies: [
            .package(path: #{inspect(repo_root)})
        ],
        targets: [
            .target(name: "GeneratedClient", dependencies: [#{runtime}])#{test_target}
        ]
    )
    """)

    tmp
  end

  def sources_dir(tmp), do: Path.join([tmp, "Sources", "GeneratedClient"])

  def tests_dir(tmp), do: Path.join([tmp, "Tests", "E2ETests"])

  @doc "Removes the shared package (no-op if none was created)."
  def cleanup do
    case :persistent_term.get(@key, nil) do
      nil -> :ok
      tmp -> File.rm_rf!(tmp)
    end

    :persistent_term.erase(@key)
    :persistent_term.erase(@built_key)
    :ok
  end

  @doc """
  Compiles the package's library target (the generated client plus
  `ConsumerCheck.swift`). The first call does the real work; later calls are
  incremental no-ops. Returns `{output, status}`.
  """
  def build_client(tmp), do: System.cmd("swift", ["build"], cd: tmp, stderr_to_stdout: true)

  @doc """
  Writes `swift_source` as `<class>.swift` into the shared package's test
  target, runs `swift test --filter <class>` and asserts it passes. The file is
  removed when the test exits. `class` must be the XCTest class name in the source.
  """
  def run_swift_test!(class, swift_source) do
    tmp = shared_package()
    file = Path.join(tests_dir(tmp), "#{class}.swift")
    File.write!(file, swift_source)
    on_exit(fn -> File.rm(file) end)

    assert_client_built!(tmp, class)

    {output, status} =
      System.cmd("swift", ["test", "--filter", class], cd: tmp, stderr_to_stdout: true)

    assert status == 0, "swift test #{class} failed:\n#{output}"
  end

  # The library target cannot change after `shared_package/0`, so a successful
  # build is memoized; a failure is not, so each test reports it.
  defp assert_client_built!(tmp, class) do
    unless :persistent_term.get(@built_key, false) do
      {output, status} = build_client(tmp)

      assert status == 0,
             "the shared generated client failed to compile (not specific to #{class}):\n" <>
               output

      :persistent_term.put(@built_key, true)
    end

    :ok
  end
end
