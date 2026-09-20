# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Search do
  @shortdoc "Searches symbols across loaded Ash resources as JSON"

  @moduledoc """
  Searches attributes, actions, calculations, and relationships across all
  loaded Ash resources by name substring, and prints the hits as JSON.

  Wraps `AshAgentTools.semantic_search/2`. Matching is case-insensitive on
  the symbol name; nothing is executed against your data.

  **Boot contract: compile, don't start.** The task boots only
  `app.config` + compile + the domains configured under
  `config :my_app, ash_domains: [...]` — the application is *not started*
  (no Oban queues, no projectors, no endpoints). See usage-rules.md.

  **stdout is pure JSON, always.** Logger output is suppressed while the
  task runs; use `--verbose` if you want the logs back.

  ## Usage

      mix ash_agent.search TERM [--kind KIND]... [--out FILE] [--pretty] [--verbose]

  ## Command line options

    * `--kind KIND` - restrict results to one kind (`attribute`, `action`,
      `calculation`, `relationship`); may be repeated
    * `--out FILE` - write the JSON to FILE instead of stdout
    * `--pretty` - pretty-print the JSON (default: compact, which is cheaper for agents)
    * `--verbose` - do not suppress Logger output (breaks pure-JSON stdout)

  ## Examples

      $ mix ash_agent.search tag
      {"query":"tag","kinds":null,"count":2,"results":[
        {"resource":"MyApp.Post","kind":"attribute","name":"tags","type":"array<string>","source":{...}},
        {"resource":"MyApp.Post","kind":"action","name":"by_tag","type":"read","source":{...}}]}

      $ mix ash_agent.search publish --kind action --pretty
      {
        "query": "publish",
        "kinds": ["action"],
        ...
      }

  """

  use Mix.Task

  # Compile-only boot: introspection needs compiled DSL state, not a
  # running application (see the moduledoc and usage-rules.md).
  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          kind: :keep,
          pretty: :boolean,
          out: :string,
          verbose: :boolean,
          max_results: :integer
        ]
      )

    try do
      run_search(opts, positional)
    rescue
      # over-limit refinement errors are answers too: structured JSON, not
      # a crash
      error in ArgumentError ->
        AshAgentTools.TaskOutput.emit_json_error(%{error: Exception.message(error)}, opts)
        exit({:shutdown, 1})
    end
  end

  defp run_search(opts, positional) do
    AshAgentTools.TaskOutput.with_quiet_logger(opts, fn ->
      AshAgentTools.TaskOutput.ensure_compiled()

      # Resource modules load lazily; load the domains configured the way
      # ash projects declare them (`config :my_app, ash_domains: [...]`) so
      # the search covers the whole declared surface.
      AshAgentTools.TaskOutput.load_configured_domains()

      case positional do
        [term] ->
          kinds = kinds_from_opts(opts)

          results =
            AshAgentTools.semantic_search(
              term,
              kinds: kinds,
              max_results: Keyword.get(opts, :max_results, 100)
            )

          envelope =
            %{query: term, kinds: kinds, count: length(results), results: results}
            |> Map.merge(
              if results == [] do
                %{did_you_mean: AshAgentTools.Search.did_you_mean(term)}
              else
                %{}
              end
            )

          envelope
          |> Jason.encode!(pretty: !!opts[:pretty])
          |> AshAgentTools.TaskOutput.write_json(opts)

        _ ->
          Mix.raise("Usage: mix ash_agent.search TERM [--kind KIND] [--out FILE] [--pretty]")
      end
    end)
  rescue
    # over-limit refinement errors are answers too: structured JSON, not a
    # crash
    error in ArgumentError ->
      AshAgentTools.TaskOutput.emit_json_error(%{error: Exception.message(error)}, opts)
      exit({:shutdown, 1})
  end

  # `--kind` is parsed with `:keep`, so repeated flags come back as repeated
  # keyword entries (one value each) — collect them with get_values/2.
  defp kinds_from_opts(opts) do
    case Keyword.get_values(opts, :kind) do
      [] -> nil
      kinds -> kinds!(kinds)
    end
  end

  defp kinds!(kinds) do
    valid = AshAgentTools.Search.valid_kinds()

    Enum.map(kinds, fn kind ->
      normalized =
        if is_binary(kind) do
          Enum.find(valid, &(Atom.to_string(&1) == kind))
        else
          kind
        end

      normalized ||
        Mix.raise(
          "Unknown --kind #{inspect(kind)}. Valid kinds: #{inspect(valid)} (strings accepted too)"
        )
    end)
  end
end
