# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Decisions do
  @shortdoc "Lists DMN decision definitions per key as JSON"

  @moduledoc """
  Lists the host's DMN decision definitions — the `AshDecisions.Catalogue`
  projection — as JSON. **Requires the optional `ash_decisions` dependency**
  (otherwise the structured "add the dep" error).

  Per key: name, status, `has_draft`, `latest_published_version`, and the
  decisions the document declares (inputs, outputs, document order). With
  `--graph` and/or `--verification`, the stored graph snapshot and the
  stored publish-time verification ride along — read as stored, never
  re-verified.

  **Boot contract: compile, don't start.** **stdout is pure JSON, always.**

  ## Usage

      mix ash_agent.decisions [DOMAIN] [--key K] [--graph] [--verification]
          [--out FILE] [--pretty] [--verbose]

  ## Examples

      $ mix ash_agent.decisions
      {"count":1,"decisions":[{"domain":"Elixir.MyApp.Decisions","key":"surcharge",
        "name":"Surcharge","status":"published","has_draft":false,
        "latest_published_version":1,"decisions":[{"name":"Surcharge","inputs":[...],
        "outputs":[...]}]}]}
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          key: :string,
          graph: :boolean,
          verification: :boolean,
          pretty: :boolean,
          out: :string,
          verbose: :boolean
        ]
      )

    AshAgentTools.TaskOutput.with_quiet_logger(opts, fn ->
      AshAgentTools.TaskOutput.ensure_compiled()
      AshAgentTools.TaskOutput.load_configured_domains()

      case positional do
        [] ->
          emit(opts, nil)

        [domain] ->
          emit(opts, domain)

        _ ->
          Mix.raise(
            "Usage: mix ash_agent.decisions [DOMAIN] [--key K] [--graph] [--verification]"
          )
      end
    end)
  end

  defp emit(opts, domain) do
    AshAgentTools.decisions(domain,
      key: opts[:key],
      graph: opts[:graph],
      verification: opts[:verification]
    )
    |> Jason.encode!(pretty: !!opts[:pretty])
    |> AshAgentTools.TaskOutput.write_json(opts)
  rescue
    error in ArgumentError ->
      AshAgentTools.TaskOutput.emit_json_error(
        %{error: Exception.message(error), did_you_mean: []},
        opts
      )

      exit({:shutdown, 1})
  end
end
