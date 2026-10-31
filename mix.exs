defmodule Hyperlang.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/hyperbob-labs/hyperlang"

  def project do
    [
      app: :hyperlang,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Hyperlang",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :syntax_tools],
      mod: {Hyperlang.Application, []}
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Run Erlang-shaped guest programs inside an Elixir host on the same " <>
      "BEAM, with no ambient authority: verified compilation, declared bindings, " <>
      "a frozen stdlib allowlist, and per-run resource limits."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://hexdocs.pm/hyperlang/changelog.html"
      },
      files: ~w(lib src priv patches doc/SECURITY_SPECIFICATION.md doc/COMPARISON.md mix.exs
                .formatter.exs README.md LICENSE NOTICE CHANGELOG.md SECURITY.md CONTRIBUTING.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      output: "_build/docs",
      assets: %{"assets" => "assets"},
      source_ref: "v#{@version}",
      filter_modules: fn module, _metadata ->
        String.starts_with?(Atom.to_string(module), "Elixir.")
      end,
      extras: [
        "README.md",
        "doc/SECURITY_SPECIFICATION.md",
        "doc/COMPARISON.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "SECURITY.md",
        "LICENSE",
        "NOTICE"
      ],
      groups_for_modules: [
        "Host API": [
          Hyperlang,
          Hyperlang.Program,
          Hyperlang.Actor,
          Hyperlang.Binding,
          Hyperlang.Scope
        ],
        "Syscall hosts": [Hyperlang.SyscallHost, Hyperlang.Limits, Hyperlang.Chan],
        Tooling: [Hyperlang.Test, Hyperlang.Check, Hyperlang.Manpage]
      ]
    ]
  end
end
