defmodule AshSwift.DeterminismTest do
  @moduledoc """
  Codegen determinism: regenerating any domain set produces byte-identical output.

  Replaces the golden-file snapshot. That snapshot existed to prove two migrations
  output-preserving — the `Ash.Info.Manifest` re-platform (ADR-0009) and the
  Reader/Emitter split (ADR-0010) — by pinning the generated Swift byte-for-byte.
  Both are done and the seam is stable, so the byte-for-byte net (and its
  `UPDATE_GOLDEN` regen ritual) is retired. What stays is the one property the
  snapshot uniquely guaranteed — determinism — now asserted across every fixture
  domain rather than implied by a single stored copy.

  The real coverage lives elsewhere: `codegen_test` for per-domain structure,
  `reader_test`/`type_map_test` for IR-level classification, and
  `swift_build_test`/`e2e_test` for "it compiles and decodes real JSON".
  """
  use ExUnit.Case, async: true

  alias AshSwift.Codegen

  # One entry per fixture domain set worth pinning — the primary resources,
  # map-only resources, and tags. CollisionDomain is excluded by design:
  # build_files/1 raises on its name collision (pinned in codegen_test).
  @matrix %{
    "domain" => [AshSwift.Test.Domain],
    "map_only_domain" => [AshSwift.Test.MapOnlyDomain],
    "tag_domain" => [AshSwift.Test.TagDomain]
  }

  for {label, domains} <- @matrix do
    @domains domains

    test "codegen is deterministic and non-empty for #{label}" do
      files = Codegen.build_files(@domains)

      assert map_size(files) > 0

      assert Codegen.build_files(@domains) == files,
             "Codegen for #{unquote(label)} is non-deterministic — two runs produced different output."
    end
  end
end
