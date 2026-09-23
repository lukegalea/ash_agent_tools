# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Graph do
  @shortdoc "Prints one BPMN definition's compiled graph as JSON"

  @moduledoc """
  One BPMN process definition's compiled graph — the engine's public
  `graph` map (`nodes`, `flows`, `joins`, `boundaries`, `feel_engine`,
  `process_id`, `start`) plus the per-element occupancy digests — as JSON.
  **Requires the optional `ash_bpmn` dependency** (otherwise the structured
  "add the dep" error).

  Resolves by `--version`, the key's draft (`--draft`), or the latest
  published version. An **uncompiled draft** has no graph: the report
  renders the stored compile `errors` and says so. Unknown keys come back
  as structured errors with `did_you_mean` candidates.

  **Boot contract: compile, don't start.** **stdout is pure JSON, always.**

  ## Usage

      mix ash_agent.graph KEY [--version N] [--draft] [--domain D] [--no-elements]
          [--out FILE] [--pretty] [--verbose]

  ## Examples

      $ mix ash_agent.graph access_request
      {"key":"access_request","version":2,"status":"published","content_hash":"...",
       "graph":{"nodes":{...},"flows":{...},"start":"Start_1",...},"elements":{...},"errors":[]}

      $ mix ash_agent.graph wip --draft --no-elements
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          version: :integer,
          draft: :boolean,
          domain: :string,
          no_elements: :boolean,
          pretty: :boolean,
          out: :string,
          verbose: :boolean
        ]
      )

    AshAgentTools.TaskOutput.with_quiet_logger(opts, fn ->
      AshAgentTools.TaskOutput.ensure_compiled()
      AshAgentTools.TaskOutput.load_configured_domains()

      case positional do
        [key] ->
          tool_opts = [
            version: opts[:version],
            draft: opts[:draft],
            domain: opts[:domain],
            include_elements: opts[:no_elements] != true
          ]

          try do
            AshAgentTools.process_graph(key, tool_opts)
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

        _ ->
          Mix.raise("Usage: mix ash_agent.graph KEY [--version N] [--draft] [--no-elements]")
      end
    end)
  end
end
