defmodule AshSwift.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :ash_swift,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.0"},
      # Pinned to the minor we build the codegen against: it reads AshTypescript
      # internals (RPC entity shape, Resource.Info type_name accessor) that can
      # change across 0.x minors (ADR-0003).
      {:ash_typescript, "~> 0.17"}
    ]
  end

  defp aliases do
    []
  end
end
