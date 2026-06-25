defmodule AshSwift.SwiftBuildTest do
  @moduledoc """
  The essential M1 guarantee: generated Swift type-checks against the
  AshSwiftRuntime package. Type-safety is the product, so a string-comparison
  test alone is insufficient — this runs the real Swift compiler over the
  output, mirroring how AshTypescript runs `tsc` over its generated TypeScript.
  """
  use ExUnit.Case, async: false

  alias AshSwift.Codegen

  @domains [AshSwift.Test.Domain]
  # Excluded automatically when the swift toolchain is absent (see test_helper).
  @moduletag :swift_build

  test "generated Swift, plus a hand-written consumer, compiles against AshSwiftRuntime" do
    repo_root = File.cwd!()
    tmp = make_consumer_package(repo_root)
    sources = Path.join([tmp, "Sources", "GeneratedClient"])

    assert {:ok, written} = Codegen.generate(@domains, sources)
    assert "AshRpcTypes.swift" in written
    assert "AshRpcFunctions.swift" in written

    # Build the generated output alongside a "shouldPass" consumer fixture that
    # exercises the emitted surface, proving it is usable (not just consistent).
    File.cp!(
      Path.join(repo_root, "test/support/swift/ConsumerCheck.swift"),
      Path.join(sources, "ConsumerCheck.swift")
    )

    {output, status} = System.cmd("swift", ["build"], cd: tmp, stderr_to_stdout: true)
    assert status == 0, "swift build failed:\n#{output}"
  end

  test "regenerating with no schema change produces no diff" do
    sources = Path.join(System.tmp_dir!(), "ash_swift_determinism_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(sources) end)

    assert {:ok, first} = Codegen.generate(@domains, sources)
    assert "AshRpcTypes.swift" in first

    # Second run sees identical content and writes nothing — no diff, no churn.
    assert {:ok, []} = Codegen.generate(@domains, sources)
  end

  # Builds a throwaway SPM consumer package that adds the generated files to a
  # target depending on AshSwiftRuntime (via a local path), exactly as a real
  # consuming app would (ADR-0005: no import-path resolution needed).
  defp make_consumer_package(repo_root) do
    tmp = Path.join(System.tmp_dir!(), "ash_swift_build_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(tmp) end)
    File.mkdir_p!(Path.join([tmp, "Sources", "GeneratedClient"]))

    manifest = """
    // swift-tools-version:5.9
    import PackageDescription

    let package = Package(
        name: "GeneratedClientCheck",
        platforms: [.iOS(.v16), .macOS(.v13)],
        dependencies: [
            .package(path: #{inspect(repo_root)})
        ],
        targets: [
            .target(
                name: "GeneratedClient",
                dependencies: [.product(name: "AshSwiftRuntime", package: #{inspect(String.downcase(Path.basename(repo_root)))})]
            )
        ]
    )
    """

    File.write!(Path.join(tmp, "Package.swift"), manifest)
    tmp
  end
end
