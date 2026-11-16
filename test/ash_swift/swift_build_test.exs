defmodule AshSwift.SwiftBuildTest do
  @moduledoc """
  The essential M1 guarantee: generated Swift type-checks against the
  AshSwiftRuntime package. Type-safety is the product, so a string-comparison
  test alone is insufficient — this runs the real Swift compiler over the
  output, mirroring how AshTypescript runs `tsc` over its generated TypeScript.
  """
  use ExUnit.Case, async: false

  alias AshSwift.Codegen
  alias AshSwift.Test.SwiftConsumer

  # Excluded automatically when the swift toolchain is absent (see test_helper).
  @moduletag :swift_build

  test "generated Swift, plus a hand-written consumer, compiles against AshSwiftRuntime" do
    # The shared package holds the generated client plus the "shouldPass"
    # ConsumerCheck fixture that exercises the emitted surface, proving it is
    # usable (not just consistent). The package is built incrementally, so
    # whichever :swift_build test runs first pays for the cold build.
    tmp = SwiftConsumer.shared_package()
    sources = SwiftConsumer.sources_dir(tmp)

    for file <- ~w(AshRpcTypes.swift AshRpcFunctions.swift ConsumerCheck.swift) do
      assert File.exists?(Path.join(sources, file)), "missing #{file}"
    end

    {output, status} = SwiftConsumer.build_client(tmp)
    assert status == 0, "swift build failed:\n#{output}"
  end

  test "a sort-enabled read over a resource with no sortable attributes compiles (issue #41)" do
    # Different generated output from the shared package, so it owns a package.
    tmp = SwiftConsumer.fresh_package("ash_swift_build")
    on_exit(fn -> File.rm_rf!(tmp) end)
    sources = SwiftConsumer.sources_dir(tmp)

    # MapOnlyDomain's `list_map_onlys_sortable` is a sort-enabled read over a
    # resource whose only public attribute is a non-sortable Map. Before #41 this
    # emitted an empty `public enum MapOnlySortField: String, Sendable {}`, which
    # swiftc rejects ("an enum with no cases cannot declare a raw type"). The fix
    # drops the sort surface; this proves the result actually type-checks.
    assert {:ok, _written} = Codegen.generate([AshSwift.Test.MapOnlyDomain], sources)

    {output, status} = SwiftConsumer.build_client(tmp)
    assert status == 0, "swift build failed:\n#{output}"
  end

  test "a get_by field named like a Swift keyword compiles (issue #142)" do
    tmp = SwiftConsumer.fresh_package("ash_swift_build")
    on_exit(fn -> File.rm_rf!(tmp) end)
    sources = SwiftConsumer.sources_dir(tmp)

    assert {:ok, _written} = Codegen.generate([AshSwift.Test.KeywordGetByDomain], sources)

    {output, status} = SwiftConsumer.build_client(tmp)
    assert status == 0, "swift build failed:\n#{output}"
  end
end
