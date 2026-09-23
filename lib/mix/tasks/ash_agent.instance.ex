# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Instance do
  @shortdoc "Shows in-flight BPMN instances, tokens, and open tasks as JSON"

  @moduledoc """
  What is in flight in the host's BPMN engine — instances, their tokens
  (interpreted against the definition each instance pinned), and open human
  tasks with their candidate rows — as JSON. **Requires the optional
  `ash_bpmn` dependency.**

  Read-only by construction: the export is the engine's own read-only
  state view, and no task is completed, no token advanced, no instance
  cancelled here — those are host mutations with downstream service
  effects, deliberately outside this toolset (a future opt-in config could
  change that; today it does not exist).

  Correlation keys are **digested** unless `--include-correlation-keys` is
  given — the privacy line the export itself draws. Token positions ride
  with `definition_version` + `definition_content_hash` so version drift
  is decidable.

  **Boot contract: compile, don't start.** **stdout is pure JSON, always.**

  ## Usage

      mix ash_agent.instance [--instance-id ID | --subject TYPE:ID] [--key K]
          [--statuses running,completed,...] [--no-children]
          [--include-correlation-keys] [--scope engine]
          [--out FILE] [--pretty] [--verbose]

  ## Command line options

    * `--instance-id ID` - one instance
    * `--subject TYPE:ID` - instances of that subject
    * `--key K` - instances of one process key
    * `--statuses` - comma-separated instance statuses (default `running`)
    * `--no-children` - do not follow call-activity children
    * `--include-correlation-keys` - emit correlation keys in the clear
    * `--scope engine` - force the engine scope even with an actor given

  ## Examples

      $ mix ash_agent.instance --key access_request
      {"count":1,"instances":[{"id":"...","status":"running","definition_key":"access_request",
        "definition_version":2,"tokens":[{"node_id":"SecurityApproval","status":"waiting",...}],
        "open_tasks":[{"node_id":"SecurityApproval","candidates":[...]}]}],...}
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          instance_id: :string,
          subject: :string,
          key: :string,
          statuses: :string,
          no_children: :boolean,
          include_correlation_keys: :boolean,
          scope: :string,
          actor: :string,
          pretty: :boolean,
          out: :string,
          verbose: :boolean
        ]
      )

    AshAgentTools.TaskOutput.with_quiet_logger(opts, fn ->
      AshAgentTools.TaskOutput.ensure_compiled()
      AshAgentTools.TaskOutput.load_configured_domains()

      unless positional == [] do
        Mix.raise("Usage: mix ash_agent.instance [options] — instances are selected by flags")
      end

      tool_opts = [
        instance_id: opts[:instance_id],
        subject_type: subject_opts(opts)[:subject_type],
        subject_id: subject_opts(opts)[:subject_id],
        definition_key: opts[:key],
        statuses: statuses(opts[:statuses]),
        include_children: opts[:no_children] != true,
        include_correlation_keys: opts[:include_correlation_keys],
        scope: opts[:scope] && String.to_existing_atom(opts[:scope]),
        actor: actor(opts[:actor])
      ]

      try do
        AshAgentTools.process_instance(tool_opts)
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
    end)
  end

  defp subject_opts(opts) do
    case opts[:subject] do
      nil ->
        []

      subject ->
        case String.split(subject, ":", parts: 2) do
          [type, id] -> [subject_type: type, subject_id: id]
          _ -> Mix.raise("Invalid --subject #{inspect(subject)}: use TYPE:ID")
        end
    end
  end

  defp statuses(nil), do: nil

  defp statuses(csv) do
    Enum.map(String.split(csv, ","), fn s ->
      String.to_existing_atom(String.trim(s))
    end)
  end

  defp actor(nil), do: nil
  defp actor("none"), do: nil

  defp actor(spec) do
    case String.split(spec, ":", parts: 2) do
      [module_name, id] ->
        module = Module.concat([module_name])

        case Code.ensure_loaded(module) do
          {:module, _} -> %{resource: module, id: id}
          {:error, reason} -> Mix.raise("Cannot load #{module_name}: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("Invalid --actor #{inspect(spec)}: use MODULE:ID")
    end
  end
end
