# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description """
  Read-only Ash introspection for AI agents: describe resources and actions,
  validate inputs, and explain authorization. Ships as plain modules and Mix
  tasks plus usage rules, so agents compose the tools themselves.
  """

  def project do
    [
      app: :ash_agent_tools,
      version: @version,
      description: @description,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
      source_url: "https://github.com/lukegalea/ash_agent_tools",
      docs: docs(),

      # The mix tasks in this package call into the Mix module, so the PLT
      # must include it (it is not part of the default PLT core). The ignore
      # file documents the deliberate defensive clause Dialyzer flags.
      dialyzer: [
        plt_add_apps: [:mix],
        ignore_warnings: "dialyzer.ignore-warnings.exs"
      ]
    ]
  end

  # No supervision tree: every function in this package is a pure, read-only
  # introspection call over already-loaded Ash modules.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Compile the test support resources (a minimal domain + resources used by
  # the doctests and tests).
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:jason, "~> 1.4"},

      # Pure-Elixir SAT solver, needed to verify the policies of the
      # test-only resource that exercises `explain_forbidden/2`.
      # Production users of Ash.Policy.Authorizer choose their own solver
      # (picosat_elixir is the usual pick) — this package itself never
      # evaluates policies.
      {:simple_sat, "~> 0.1", only: [:dev, :test]},

      # Dev hygiene: static analysis and type checking.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/lukegalea/ash_agent_tools",
        "Usage rules" => "https://github.com/lukegalea/ash_agent_tools/blob/main/usage-rules.md"
      },
      files: ~w(lib mix.exs README.md LICENSE LICENSES usage-rules.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "usage-rules.md"]
    ]
  end
end
