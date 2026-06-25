defmodule Mix.Tasks.AshSwift.Codegen do
  @shortdoc "Generates a type-safe Swift client for Ash RPC actions"

  @moduledoc """
  Generates Swift client source from the project's reused `typescript_rpc`
  configuration (ADR-0003) and writes it to a configurable output directory.

  ## Usage

      mix ash_swift.codegen
      mix ash_swift.codegen --output swift/Sources/Generated
      mix ash_swift.codegen --check

  ## Configuration

      config :ash_swift, output_dir: "swift/Generated"

  The `--output` flag takes precedence over the `:output_dir` config. Output is
  deterministic and written change-only, so committing it surfaces schema
  changes as reviewable diffs (ADR-0005).

  `--check` writes nothing and exits non-zero if the committed Swift is out of
  date, for use as a CI guard that codegen has been run.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")

    {opts, _remaining, _invalid} =
      OptionParser.parse(args,
        switches: [output: :string, check: :boolean],
        aliases: [o: :output]
      )

    otp_app = Mix.Project.config()[:app]
    output_dir = opts[:output] || AshSwift.output_dir()
    domains = Ash.Info.domains(otp_app)

    if opts[:check] do
      check(domains, output_dir)
    else
      generate(domains, output_dir)
    end
  end

  defp check(domains, output_dir) do
    case AshSwift.Codegen.stale_files(domains, output_dir) do
      [] ->
        Mix.shell().info("ash_swift: generated Swift in #{output_dir} is up to date")

      stale ->
        Mix.raise(
          "ash_swift: generated Swift in #{output_dir} is out of date. " <>
            "Run `mix ash_swift.codegen`. Stale files: #{Enum.join(stale, ", ")}"
        )
    end
  end

  defp generate(domains, output_dir) do
    {:ok, written} = AshSwift.Codegen.generate(domains, output_dir)

    case written do
      [] ->
        Mix.shell().info("ash_swift: generated Swift is up to date in #{output_dir}")

      paths ->
        Mix.shell().info("ash_swift: wrote #{length(paths)} file(s) to #{output_dir}:")
        Enum.each(paths, &Mix.shell().info("  #{&1}"))
    end
  end
end
