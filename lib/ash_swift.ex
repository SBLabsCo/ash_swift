defmodule AshSwift do
  @moduledoc """
  AshSwift is an Elixir/Mix Ash extension that reads Ash resources and their
  reused `typescript_rpc` configuration (see ADR-0003) and generates a
  type-safe Swift client — `Codable` models plus `async`/`await` functions —
  that talks JSON over HTTP to the same RPC endpoint AshTypescript serves.

  This module exposes the small amount of static configuration the codegen
  reads. See `Mix.Tasks.AshSwift.Codegen` for the entry point and
  `AshSwift.Codegen` for the generator itself.
  """

  @default_output_dir "swift/Generated"

  @doc """
  The directory generated Swift source is written to, relative to the project
  root. Configurable via `config :ash_swift, output_dir: "..."`.
  """
  @spec output_dir() :: String.t()
  def output_dir do
    Application.get_env(:ash_swift, :output_dir, @default_output_dir)
  end
end
