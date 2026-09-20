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

  **stdout is pure JSON, always.** Logger output from application start
  (repo wiring, banners, debug logs) is suppressed while the task runs, so
  the output pipes cleanly into a JSON parser; use `--verbose` if you want
  the logs back.

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

  # app.start runs inside run/1 (not via @requirements) so the logger is
  # silenced before the application boots.
  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [kind: :keep, pretty: :boolean, out: :string, verbose: :boolean]
      )

    AshAgentTools.TaskOutput.with_quiet_logger(opts, fn ->
      Mix.Task.run("app.start")

      # Resource modules load lazily; load the domains configured the way
      # ash projects declare them (`config :my_app, ash_domains: [...]`) so
      # the search covers the whole declared surface.
      load_configured_domains()

      case positional do
        [term] ->
          kinds = kinds_from_opts(opts)

          results = AshAgentTools.semantic_search(term, kinds: kinds)

          %{query: term, kinds: kinds, count: length(results), results: results}
          |> Jason.encode!(pretty: !!opts[:pretty])
          |> AshAgentTools.TaskOutput.write_json(opts)

        _ ->
          Mix.raise("Usage: mix ash_agent.search TERM [--kind KIND] [--out FILE] [--pretty]")
      end
    end)
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

  defp load_configured_domains do
    app = Mix.Project.config()[:app]

    for domain <- Application.get_env(app, :ash_domains, []) do
      with {:module, domain} <- Code.ensure_loaded(domain),
           true <- function_exported?(domain, :spark_is, 0) do
        for resource <- Ash.Domain.Info.resources(domain) do
          Code.ensure_loaded(resource)
        end
      else
        _ -> :ok
      end
    end

    :ok
  end
end
