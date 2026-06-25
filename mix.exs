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
      description: description(),
      package: package(),
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp description do
    "An Ash extension that generates a type-safe Swift client for Ash RPC actions."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/SBLabsCo/ash_swift"},
      # The Swift runtime (Sources/, Package.swift), tests, and CI configs don't
      # belong in the Hex release — ship only the Elixir codegen and docs.
      files: ~w(lib mix.exs README.md LICENSE)
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
