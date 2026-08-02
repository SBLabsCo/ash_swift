defmodule AshSwift.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/SBLabsCo/ash_swift"

  def project do
    [
      app: :ash_swift,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      name: "AshSwift",
      description: description(),
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp description do
    "An Ash extension that generates a type-safe Swift client for Ash RPC actions."
  end

  # README is the package's landing page on HexDocs (the standard Hex convention).
  # Design docs (docs/adr, docs/prd, CONTEXT.md) are deliberately left out: they
  # are implementation/maintainer detail, not adopter-facing API documentation.
  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
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
      # 3.29 introduced `Ash.Info.Manifest`, the language-agnostic codegen IR this
      # extension reads as its sole metadata source (ADR-0009). Earlier 3.x lacks it.
      {:ash, "~> 3.29"},
      # Pinned to the minor we build the codegen against: it reads AshTypescript
      # internals (RPC entity shape, Resource.Info type_name accessor) that can
      # change across 0.x minors (ADR-0003).
      {:ash_typescript, "~> 0.17"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    []
  end
end
