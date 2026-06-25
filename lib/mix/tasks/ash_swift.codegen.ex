defmodule Mix.Tasks.AshSwift.Codegen do
  @shortdoc "Generates a type-safe Swift client for Ash RPC actions"

  @moduledoc """
  Generates Swift client source from the project's reused `typescript_rpc`
  configuration (ADR-0003) and writes it to a configurable output directory.

  ## Usage

      mix ash_swift.codegen
      mix ash_swift.codegen --output swift/Sources/Generated

  ## Configuration

      config :ash_swift, output_dir: "swift/Generated"

  The `--output` flag takes precedence over the `:output_dir` config. Output is
  deterministic and written change-only, so committing it surfaces schema
  changes as reviewable diffs (ADR-0005).
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")

    {opts, _remaining, _invalid} =
      OptionParser.parse(args, switches: [output: :string], aliases: [o: :output])

    otp_app = Mix.Project.config()[:app]
    output_dir = opts[:output] || AshSwift.output_dir()
    domains = Ash.Info.domains(otp_app)

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
