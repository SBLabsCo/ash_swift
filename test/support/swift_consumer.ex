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

  Test files compile together into one test target, so a broken test file would
  otherwise fail every later test with an error that is not its own. Two guards
  keep failures attributable:

    * the generated client is compiled up front (`swift build`) by every
      `swift_test!/2`; if that fails the message says the *shared generated
      client* failed to compile, not the test;
    * `swift_test!/2` inspects compile errors and, when they point at a different
      test's Swift file, says so and names that file.

  Tests that need different generated output (the sort-less resource check) use
  `fresh_package/2` and own their build.
  """

  import ExUnit.Assertions

  alias AshSwift.Codegen

  @domains [AshSwift.Test.Domain]
  @key {__MODULE__, :shared}

  @doc "Path of the run-wide shared package, generating the client on first use."
  def shared_package do
    case :persistent_term.get(@key, nil) do
      nil ->
        tmp = fresh_package("ash_swift_shared", tests: true)
        sources = sources_dir(tmp)
        {:ok, _} = Codegen.generate(@domains, sources)

        # A hand-written consumer exercising the emitted surface, compiled with
        # the client so every build also proves the surface is usable.
        File.cp!(
          Path.join(File.cwd!(), "test/support/swift/ConsumerCheck.swift"),
          Path.join(sources, "ConsumerCheck.swift")
        )

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

  def tests_dir(tmp) do
    dir = Path.join([tmp, "Tests", "E2ETests"])
    File.mkdir_p!(dir)
    dir
  end

  @doc "Removes the shared package (no-op if none was created)."
  def cleanup do
    case :persistent_term.get(@key, nil) do
      nil -> :ok
      tmp -> File.rm_rf!(tmp)
    end

    :persistent_term.erase(@key)
    :ok
  end

  @doc """
  Compiles the package's library target (the generated client plus
  `ConsumerCheck.swift`). The first call does the real work; later calls are
  incremental no-ops. Returns `{output, status}`.
  """
  def build_client(tmp), do: System.cmd("swift", ["build"], cd: tmp, stderr_to_stdout: true)

  @doc """
  Runs `swift test --filter <class>` in the shared package and asserts it
  passes, attributing compile failures that belong to another test's file.
  """
  def swift_test!(tmp, class) do
    {build_output, build_status} = build_client(tmp)

    assert build_status == 0,
           "the shared generated client failed to compile (not specific to #{class}):\n" <>
             build_output

    {output, status} =
      System.cmd("swift", ["test", "--filter", class], cd: tmp, stderr_to_stdout: true)

    assert status == 0, failure_message(class, output)
  end

  defp failure_message(class, output) do
    other_files =
      ~r{Tests/E2ETests/(\w+)\.swift:\d+:\d+: error:}
      |> Regex.scan(output, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.reject(&(&1 == class))

    if other_files == [] do
      "swift test #{class} failed:\n#{output}"
    else
      "swift test #{class} failed because another test's Swift file does not compile " <>
        "(#{Enum.join(other_files, ", ")}); that test owns the failure:\n#{output}"
    end
  end
end
