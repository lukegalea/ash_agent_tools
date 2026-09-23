# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Rules do
  @shortdoc "Lists AshRules rule sets and dry-evaluates them as JSON"

  @moduledoc """
  Introspects and dry-evaluates `AshRules` rule sets — **requires the
  optional `ash_rules` dependency** (hosts add the dep, the tools activate;
  without it every invocation answers with the structured "add the dep"
  error instead of raising).

  Three modes:

    * no arguments — every loaded rule set, with fact schemas and rules
    * `MODULE` — one rule set's full bundle report
    * `MODULE --facts JSON` (or `--bundle FILE --facts JSON`) — **dry
      evaluation**: the bundle is evaluated against the fact triples you
      provide and the full result is printed. Zero host state: nothing is
      read from your data layer, nothing is persisted, nothing is decided
      about real records.

  **Boot contract: compile, don't start** (the evaluation is pure — it
  touches only the triples you pass). **stdout is pure JSON, always.**

  ## Usage

      mix ash_agent.rules
      mix ash_agent.rules MODULE
      mix ash_agent.rules MODULE --facts JSON
      mix ash_agent.rules --bundle FILE --facts JSON

  ## Command line options

    * `--facts JSON` - a JSON array of `{subject, predicate, value}` triples
      (or `[subject, predicate, value]` arrays); required for the
      evaluation mode
    * `--bundle FILE` - evaluate a bundle JSON document instead of a loaded
      module (admitted through the same validation the library uses)
    * `--out FILE` - write the JSON to FILE instead of stdout
    * `--pretty` - pretty-print the JSON (default: compact)
    * `--verbose` - do not suppress Logger output (breaks pure-JSON stdout)

  ## Examples

      $ mix ash_agent.rules
      {"count":1,"rule_sets":[{"module":"Elixir.MyApp.Compliance.Rules",
        "combining":"deny_overrides","content_hash":"...","fact_schema":[...],
        "rules":[...]}]}

      $ mix ash_agent.rules MyApp.Compliance.Rules --facts \
          '[{"subject":"customer","predicate":"status","value":"active"}]'
      {"overall":"unknown","requirements":[...],"missing_facts":[...],...}

  The DSL-level view of the same rule sets is searchable with
  `mix ash_agent.search --kind rules_fact_schema`.
  """

  use Mix.Task

  # Compile-only boot: the evaluation is pure, so compiled DSL state is all
  # it needs (see the moduledoc and usage-rules.md).
  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          facts: :string,
          bundle: :string,
          pretty: :boolean,
          out: :string,
          verbose: :boolean
        ]
      )

    AshAgentTools.TaskOutput.with_quiet_logger(opts, fn ->
      AshAgentTools.TaskOutput.ensure_compiled()

      cond do
        opts[:bundle] && positional != [] ->
          Mix.raise("Usage: pass either MODULE or --bundle FILE, not both")

        opts[:bundle] || opts[:facts] ->
          evaluate(opts, positional)

        true ->
          list(opts, positional)
      end
    end)
  end

  defp list(opts, []) do
    rule_sets = AshAgentTools.rule_sets()

    %{count: length(rule_sets), rule_sets: rule_sets}
    |> Jason.encode!(pretty: !!opts[:pretty])
    |> AshAgentTools.TaskOutput.write_json(opts)
  end

  defp list(opts, [module_name]) do
    module = ensure_module!(module_name)

    try do
      AshAgentTools.Rules.describe(module)
      |> Jason.encode!(pretty: !!opts[:pretty])
      |> AshAgentTools.TaskOutput.write_json(opts)
    rescue
      error in ArgumentError -> structured_error!(error, opts)
    end
  end

  defp list(_opts, _other) do
    Mix.raise("Usage: mix ash_agent.rules [MODULE] [--facts JSON | --bundle FILE --facts JSON]")
  end

  defp evaluate(opts, positional) do
    unless opts[:facts] do
      Mix.raise("Evaluation needs --facts JSON (a JSON array of triples)")
    end

    module_or_path =
      case {opts[:bundle], positional} do
        {nil, [module_name]} -> ensure_module!(module_name)
        {nil, []} -> Mix.raise("Evaluation needs MODULE or --bundle FILE")
        {path, []} -> path
        _ -> Mix.raise("Usage: pass either MODULE or --bundle FILE, not both")
      end

    facts = decode_facts!(opts[:facts])

    try do
      AshAgentTools.evaluate_rules(module_or_path, facts)
      |> Jason.encode!(pretty: !!opts[:pretty])
      |> AshAgentTools.TaskOutput.write_json(opts)
    rescue
      error in ArgumentError -> structured_error!(error, opts)
    end
  end

  defp decode_facts!(json) do
    case Jason.decode(json) do
      {:ok, facts} when is_list(facts) -> facts
      {:ok, _} -> Mix.raise("--facts must be a JSON array of triples")
      {:error, reason} -> Mix.raise("Invalid --facts JSON: #{Exception.message(reason)}")
    end
  end

  defp ensure_module!(name) do
    module = Module.concat([name])

    case Code.ensure_loaded(module) do
      {:module, module} -> module
      {:error, reason} -> Mix.raise("Cannot load #{name}: #{inspect(reason)}")
    end
  end

  defp structured_error!(error, opts) do
    AshAgentTools.TaskOutput.emit_json_error(
      %{error: Exception.message(error), did_you_mean: []},
      opts
    )

    exit({:shutdown, 1})
  end
end
