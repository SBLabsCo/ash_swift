defmodule Mix.Tasks.AshSwift.Contract do
  @shortdoc "Exports the RPC contract codegen reads as deterministic JSON"

  @moduledoc """
  Reads the project's reused `typescript_rpc` configuration (ADR-0003) into
  the codegen intermediate model and prints it as a stable, sorted JSON
  document — the same model `mix ash_swift.codegen` renders into Swift,
  described independently of Swift syntax (issue #85).

  ## Usage

      mix ash_swift.contract --output contract.json
      mix ash_swift.contract

  **`--output PATH` is the documented CI path** and the only one to script
  against: the contract JSON is the file's *only* content, so nothing else
  that shares stdout — compiler output from the `mix compile` this task runs
  first, or a `Logger.warning` from the reader (e.g. an unsupported attribute
  type) — can land inside it. Without `--output`, the document prints to
  stdout via `IO.write/1`, but that stream is shared with exactly that compile
  output and those warnings; treat un-redirected stdout as eyeball-only, never
  as a channel a script parses.

  Two runs against the same domains produce byte-identical JSON (whichever way
  you read it out), so the intended use is a structural compatibility gate:
  fetch the contract at a prior release (a git tag, a previous CI artifact, …)
  and at the current revision, then diff the two documents to classify each
  change as additive (a new optional field, action, or enum value) or breaking
  (a removed action, field, or enum value; a changed type; a newly required
  input). Diffing this document is far more robust than diffing the emitted
  Swift text, which churns on formatting and naming details that carry no
  contract meaning. Compare **structurally, keyed by name** (e.g. decode the
  JSON and index each list by its `name`) rather than byte-for-byte — pretty-
  printed key/array ordering is stable across two runs of *this* `Jason`
  version, but isn't a promise `Jason` itself makes across its own versions.
  Exclude `ash_swift_version` from the diff (it's metadata: which AshSwift
  build produced the document, not contract content) and assert
  `contract_version` for **equality** first — a mismatch means the document
  *shape* changed, which a diff written against the old shape can't safely
  interpret.

  Raises (exit non-zero, message on stderr) when the resolved domains carry
  zero RPC actions — almost always a misconfiguration (no domain's
  `typescript_rpc` is set up, or `:ash_domains` doesn't name the right domain
  for this `MIX_ENV`) rather than a real "every action was removed" event, so
  it must not be allowed to pass silently as an empty-but-valid contract.

  Unrecognized flags are ignored (`OptionParser.parse/2`'s `_invalid`), the
  same as `mix ash_swift.codegen` — kept consistent with that task rather than
  making one of the two stricter on its own.

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
    document = AshSwift.Codegen.Contract.build(domains)

    if document.actions == [] do
      Mix.raise(
        "AshSwift: the RPC contract for #{inspect(domains)} has zero actions. This almost " <>
          "always means a misconfiguration rather than an intentional \"every action was " <>
          "removed\" — either no domain configures `typescript_rpc` (ADR-0003), or " <>
          "`config :#{otp_app}, ash_domains: [...]` doesn't name the right domain(s) for " <>
          "MIX_ENV=#{Mix.env()}. A silently empty contract would otherwise look identical to " <>
          "a real, catastrophic breaking change to any downstream diff gate."
      )
    end

    json = AshSwift.Codegen.Contract.encode_document(document)

    case opts[:output] do
      nil ->
        IO.write(json <> "\n")

      path ->
        path |> Path.dirname() |> File.mkdir_p!()
        File.write!(path, json <> "\n")
        Mix.shell().info("ash_swift: wrote RPC contract to #{path}")
    end
  end
end
