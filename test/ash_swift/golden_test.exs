defmodule AshSwift.GoldenTest do
  @moduledoc """
  Golden-file snapshot of the full codegen output for every domain set the suite
  exercises. Captures the generated Swift byte-for-byte so the `Ash.Info.Manifest`
  re-platform (ADR-0009 / #47) can be proven output-preserving: swap the codegen
  input, and this test must stay green.

  Regenerate the goldens after an **intentional** output change:

      UPDATE_GOLDEN=1 mix test test/ash_swift/golden_test.exs
  """
  use ExUnit.Case, async: true

  alias AshSwift.Codegen

  @golden_root Path.expand("../support/golden", __DIR__)

  # label => domains. One entry per *happy-path* codegen output worth pinning:
  # the primary resources, map-only resources, and tags. CollisionDomain is
  # excluded by design — build_files/1 raises on its name collision, a behavior
  # pinned separately in codegen_test.exs and which must also survive the swap.
  @matrix %{
    "domain" => [AshSwift.Test.Domain],
    "map_only_domain" => [AshSwift.Test.MapOnlyDomain],
    "tag_domain" => [AshSwift.Test.TagDomain]
  }

  # Whether to (re)write the golden files instead of asserting against them.
  # Read at *runtime* inside each test — not a module attribute — because a module
  # attribute bakes the env value into the compiled .beam, and `UPDATE_GOLDEN=1 mix
  # test` after an intentional codegen change wouldn't recompile this unchanged
  # test file, so the stale `false` would make regeneration silently fail.
  defp update?, do: System.get_env("UPDATE_GOLDEN") in ["1", "true"]

  for {label, domains} <- @matrix do
    @label label
    @domains domains

    test "generated output matches golden for #{label}" do
      files = Codegen.build_files(@domains)
      dir = Path.join(@golden_root, @label)

      if update?() do
        File.rm_rf!(dir)
        File.mkdir_p!(dir)
        for {name, content} <- files, do: File.write!(Path.join(dir, name), content)
        assert map_size(files) > 0
      else
        for {name, content} <- files do
          golden_path = Path.join(dir, name)

          assert File.exists?(golden_path),
                 "Missing golden #{@label}/#{name}. Run `UPDATE_GOLDEN=1 mix test` to create it."

          assert File.read!(golden_path) == content,
                 "Generated #{@label}/#{name} differs from its golden. " <>
                   "If the change is intentional, regenerate with `UPDATE_GOLDEN=1 mix test`."
        end

        # Catch goldens left behind for files codegen no longer emits.
        emitted = files |> Map.keys() |> Enum.sort()
        on_disk = dir |> File.ls!() |> Enum.sort()

        assert on_disk == emitted,
               "Golden dir #{@label} has stale files not emitted by codegen: " <>
                 "#{inspect(on_disk -- emitted)}. Regenerate with `UPDATE_GOLDEN=1 mix test`."

        # Generate-twice byte-equality: the cheapest determinism gate, run for
        # every fixture so a non-sorted iteration path that only touches MapOnly
        # or Tag resources can't slip past the single-domain check in codegen_test.
        assert Codegen.build_files(@domains) == files,
               "Codegen for #{@label} is non-deterministic — two runs produced different output."
      end
    end
  end
end
