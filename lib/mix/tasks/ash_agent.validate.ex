# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Validate do
  @shortdoc "Validates params for an Ash action without running it"

  @moduledoc """
  Validates a JSON params map against an Ash resource action and prints a
  JSON report — **without executing the action**. Nothing is written, no
  data layer is touched: the params are cast with `Ash.Type.cast_input/3`
  and the changeset/query is built with `error?: false` and discarded.

  **Boot contract: compile, don't start.** The task boots only
  `app.config` + compile + the domains configured under
  `config :my_app, ash_domains: [...]` — the application is *not started*,
  so nothing runs (no Oban queues, no projectors, no endpoints). Nothing is
  ever executed against your data here either: the action is built, never
  run. See usage-rules.md.

  **stdout is pure JSON, always.** Logger output is suppressed while the
  task runs; use `--verbose` if you want the logs back.

  ## Usage

      mix ash_agent.validate RESOURCE ACTION [JSON_PARAMS] [--out FILE] [--pretty] [--verbose]

  ## Command line options

    * `--out FILE` - write the JSON to FILE instead of stdout
    * `--pretty` - pretty-print the JSON (default: compact)
    * `--verbose` - do not suppress Logger output (breaks pure-JSON stdout)

  ## Examples

      $ mix ash_agent.validate MyApp.Post create '{"title": "Hello", "score": "7"}'
      {"resource":"Elixir.MyApp.Post","action":"create","action_type":"create","valid?":true,
       "errors":[],"normalized_inputs":{"title":"Hello","score":7},...}

      $ mix ash_agent.validate MyApp.Post create '{"score": "not a number"}'
      ... "valid?":false, "errors":[{"path":"score","message":"is invalid",...}]

  """

  use Mix.Task

  # Compile-only boot: introspection needs compiled DSL state, not a
  # running application (see the moduledoc and usage-rules.md).
  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, strict: [pretty: :boolean, out: :string, verbose: :boolean])

    AshAgentTools.TaskOutput.with_quiet_logger(opts, fn ->
      AshAgentTools.TaskOutput.ensure_compiled()

      case positional do
        [resource, action] ->
          validate(resource, action, "{}", opts)

        [resource, action, params] ->
          validate(resource, action, params, opts)

        _ ->
          Mix.raise(
            "Usage: mix ash_agent.validate RESOURCE ACTION [JSON_PARAMS] [--out FILE] [--pretty]"
          )
      end
    end)
  end

  defp validate(resource_name, action_name, params_json, opts) do
    resource = ensure_module!(resource_name)
    params = decode_params!(params_json)

    try do
      AshAgentTools.validate_input(resource, action_name, params)
      |> Jason.encode!(pretty: !!opts[:pretty])
      |> AshAgentTools.TaskOutput.write_json(opts)
    rescue
      # An agent-supplied action name that resolves to nothing must not
      # break the pure-JSON contract: emit a structured error (with
      # did_you_mean) on stdout and exit non-zero instead of crashing Mix
      # into stderr noise. action_did_you_mean/2 guards non-resources
      # itself and suggests [].
      error in ArgumentError ->
        did_you_mean = AshAgentTools.Describe.action_did_you_mean(resource, action_name)

        AshAgentTools.TaskOutput.emit_json_error(
          %{error: Exception.message(error), did_you_mean: did_you_mean},
          opts
        )

        exit({:shutdown, 1})
    end
  end

  defp ensure_module!(name) do
    module = Module.concat([name])

    case Code.ensure_loaded(module) do
      {:module, module} -> module
      {:error, reason} -> Mix.raise("Cannot load #{name}: #{inspect(reason)}")
    end
  end

  defp decode_params!(json) do
    case Jason.decode(json) do
      {:ok, params} when is_map(params) -> params
      {:ok, _} -> Mix.raise("JSON_PARAMS must be a JSON object")
      {:error, reason} -> Mix.raise("Invalid JSON_PARAMS: #{Exception.message(reason)}")
    end
  end
end
