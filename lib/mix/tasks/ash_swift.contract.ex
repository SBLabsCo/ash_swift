defmodule Mix.Tasks.AshSwift.Contract do
  @shortdoc "Exports the RPC contract codegen reads as deterministic JSON"

  @moduledoc """
  Reads the project's reused `typescript_rpc` configuration (ADR-0003) into
  the codegen intermediate model and prints it as a stable, sorted JSON
  document — the same model `mix ash_swift.codegen` renders into Swift,
  described independently of Swift syntax (issue #85).

  ## Usage

      mix ash_swift.contract
      mix ash_swift.contract --output contract.json

  Without `--output` the document is printed to stdout. Two runs against the
  same domains produce byte-identical JSON, so the intended use is a
  structural compatibility gate: fetch the contract at a prior release (a git
  tag, a previous CI artifact, …) and at the current revision, then diff the
  two documents to classify each change as additive (a new optional field,
  action, or enum value) or breaking (a removed action, field, or enum value;
  a changed type; a newly required input). Diffing this document is far more
  robust than diffing the emitted Swift text, which churns on formatting and
  naming details that carry no contract meaning.

  See `AshSwift.Codegen.Contract` for the document's shape.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")

    {opts, _remaining, _invalid} =
      OptionParser.parse(args, switches: [output: :string], aliases: [o: :output])

    otp_app = Mix.Project.config()[:app]
    domains = Ash.Info.domains(otp_app)
    json = AshSwift.Codegen.Contract.encode(domains)

    case opts[:output] do
      nil ->
        Mix.shell().info(json)

      path ->
        path |> Path.dirname() |> File.mkdir_p!()
        File.write!(path, json <> "\n")
        Mix.shell().info("ash_swift: wrote RPC contract to #{path}")
    end
  end
end
