# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Processes do
  @shortdoc "Lists BPMN process definitions per key as JSON"

  @moduledoc """
  Lists the host's BPMN process definitions, aggregated per key, as JSON —
  **requires the optional `ash_bpmn` dependency** (hosts add the dep, the
  tools activate; without it every invocation answers with the structured
  "add the dep" error).

  Per key: the representative version (the draft when one exists, else the
  latest published), its status and content hash, the stored error count,
  `has_draft`, and the latest published version. The raw `xml` is never
  returned (it is `sensitive?` in the engine). Read-only: definitions and
  graphs read as the engine.

  **Boot contract: compile, don't start.** **stdout is pure JSON, always.**

  ## Usage

      mix ash_agent.processes [DOMAIN] [--key K] [--out FILE] [--pretty] [--verbose]

  ## Examples

      $ mix ash_agent.processes
      {"count":2,"processes":[{"domain":"Elixir.MyApp.Bpmn","key":"access_request",
        "name":"Access request","version":2,"status":"published","content_hash":"...",
        "errors_count":0,"has_draft":false,"latest_published_version":2},...]}

      $ mix ash_agent.processes --key access_request
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [key: :string, pretty: :boolean, out: :string, verbose: :boolean]
      )

    AshAgentTools.TaskOutput.with_quiet_logger(opts, fn ->
      AshAgentTools.TaskOutput.ensure_compiled()
      AshAgentTools.TaskOutput.load_configured_domains()

      case positional do
        [] ->
          emit(opts, nil, opts[:key])

        [domain] ->
          emit(opts, domain, opts[:key])

        _ ->
          Mix.raise("Usage: mix ash_agent.processes [DOMAIN] [--key K]")
      end
    end)
  end

  defp emit(opts, domain, key) do
    AshAgentTools.processes(domain, key: key)
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
