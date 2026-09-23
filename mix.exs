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

      # Kaizen tool-gap events (:telemetry is called directly, not just
      # transitively through ash).
      {:telemetry, "~> 1.2"},

      # Precise AST ranges for the semantic edit tools: editing a DSL block
      # means splicing exact source spans, and hand-rolled range math is
      # exactly the class of bug (Serena's "range-fidelity bugs") this
      # avoids. Sourceror is small, pure Elixir, and already in most Ash
      # projects' dependency graphs via igniter.
      {:sourceror, "~> 1.2"},

      # Pure-Elixir SAT solver, needed to verify the policies of the
      # test-only resource that exercises `explain_forbidden/2`.
      # Production users of Ash.Policy.Authorizer choose their own solver
      # (picosat_elixir is the usual pick) — this package itself never
      # evaluates policies.
      {:simple_sat, "~> 0.1", only: [:dev, :test]},

      # Optional BEAM runtime introspection backend for
      # `AshAgentTools.Runtime`. When the host application ships
      # observer_cli 2.0 (+ recon, its pinned dependency), the runtime tools
      # delegate to its heap-capped, JSON-safe snapshot worker; otherwise
      # they fall back to built-in Process/:ets/:supervisor walks. Optional
      # so hosts without it pay nothing.
      {:observer_cli, "~> 2.0", only: :dev, optional: true},
      {:recon, "2.5.6", only: :dev, optional: true},

      # Optional concept tooling. Hosts add the dep, the tools activate
      # (see AshAgentTools.Availability); without them the rules/transitions/
      # bpmn/decisions tools answer with a structured "add the dep" error and
      # the package stays useful. Both are gated behind `Code.ensure_loaded?/1`
      # conditional compilation (the Ecto-Jason pattern, as with the MCP
      # plug) so a host without either still compiles this package cleanly.
      #
      # ash_rules (compliance rules as data — fact schemas + dry evaluation),
      # ash_bpmn (BPMN process engine) and ash_decisions (DMN decisions) are
      # GitHub deps.
      {:ash_rules, github: "lukegalea/ash_rules", optional: true},
      {:ash_state_machine, "~> 0.2.13", optional: true},
      {:ash_bpmn, github: "lukegalea/ash_bpmn", optional: true},
      {:ash_decisions, github: "lukegalea/ash_decisions", optional: true},

      # Test workhorse: the ash_bpmn/ash_decisions resource macros are
      # AshPostgres by construction (`repo:` is a required option), so the
      # BPMN/decision tooling tests run against a real PostgreSQL through a
      # sandboxed TestRepo. The library code itself never touches it.
      # `optional:` (ash_bpmn requires it unconditionally, so it cannot be
      # test-only) keeps it out of consumers' dependency graphs.
      {:ash_postgres, "~> 2.13", optional: true},

      # Optional MCP-over-HTTP daemon (`mix ash_agent.serve`). All three are
      # `optional:` so hosts pay nothing unless they serve the daemon, and the
      # package keeps its MIT/no-hard-dep story. The serve task and supervisor
      # gate every use behind `Code.ensure_loaded?/1` with a pointed error
      # message when a piece is missing; `AshAgentTools.Mcp.Plug` is compiled
      # conditionally (Ecto's optional-Jason pattern) so a host without Plug
      # still compiles this package cleanly.
      {:plug, "~> 1.16", optional: true},
      {:bandit, "~> 1.5", optional: true},
      {:file_system, "~> 1.1", optional: true},

      # Dev hygiene: static analysis and type checking.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # Docs and dependency advisories, for CI's `mix docs` / `mix deps.audit`.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/lukegalea/ash_agent_tools",
        "Usage rules" => "https://github.com/lukegalea/ash_agent_tools/blob/HEAD/usage-rules.md"
      },
      files: ~w(lib mix.exs README.md LICENSE LICENSES usage-rules.md usage-rules .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "usage-rules.md", "usage-rules/iron-laws.md"] ++ extra_docs()
    ]
  end

  # EXTRA_DOCS=AGENTS.md mix docs routes standalone agent docs (AGENTS.md,
  # usage rules output) through the extras pipeline so broken refs warn like
  # any other doc. The value is a single Path.wildcard glob; e.g.
  # EXTRA_DOCS='AGENTS.md' or EXTRA_DOCS='usage-rules/*.md' (avoid globs that
  # match files already in extras — ex_doc would see a duplicate entry). CI
  # may add warnings_as_errors: true.
  defp extra_docs do
    if glob = System.get_env("EXTRA_DOCS"), do: Path.wildcard(glob), else: []
  end
end
