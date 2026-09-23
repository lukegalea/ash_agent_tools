# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Can do
  @shortdoc "Answers can <actor> perform <action>? as JSON, without executing"

  @moduledoc """
  Answers "can this actor perform this action?" for an Ash resource action
  and prints the JSON verdict — **without executing anything**. The actor
  record is resolved (unauthorized read), the changeset/query is built
  exactly as an action run would build it, and `Ash.can/3` evaluates the
  policies. The subject is never run; the evaluation itself runs with
  `run_queries?: false`, so data-dependent checks surface as an honest
  `"verdict":"maybe"`.

  **Boot contract: compile, don't start.** The task boots only `app.config`
  + compile + the domains configured under
  `config :my_app, ash_domains: [...]` — the application is *not started*.
  **stdout is pure JSON, always.**

  ## Usage

      mix ash_agent.can RESOURCE ACTION [--actor SPEC] [JSON_PARAMS] [--out FILE] [--pretty] [--verbose]

  ## Command line options

    * `--actor SPEC` - the actor: `MODULE:ID` (the record is resolved with
      `Ash.get!/2`, `authorize?: false`), `none` (default — anonymous), or
      `record` to use the action's target record as the actor
    * `--record ID` - for `update`/`destroy` actions, the target record id
      (default: the actor's own record)
    * `--out FILE` - write the JSON to FILE instead of stdout
    * `--pretty` - pretty-print the JSON (default: compact)
    * `--verbose` - do not suppress Logger output (breaks pure-JSON stdout)

  ## Examples

      $ mix ash_agent.can MyApp.Post create --actor none
      {"resource":"Elixir.MyApp.Post","action":"create","allowed":false,
       "verdict":"forbidden","per_policy":[...],"responsible":{...},...}

      $ mix ash_agent.can MyApp.Post update --actor MyApp.User:8e1c-... '{"title": "New"}'
      {"allowed":true,"verdict":"allowed",...}

  On denial, read `responsible` first: the non-bypass policy
  `Ash.Policy.Policy.responsible_for_forbidden/2` holds accountable, with
  the per-check facts that decided it.
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
          actor: :string,
          record: :string,
          pretty: :boolean,
          out: :string,
          verbose: :boolean
        ]
      )

    AshAgentTools.TaskOutput.with_quiet_logger(opts, fn ->
      AshAgentTools.TaskOutput.ensure_compiled()
      AshAgentTools.TaskOutput.load_configured_domains()

      case positional do
        [resource, action] ->
          can(resource, action, "{}", opts)

        [resource, action, params] ->
          can(resource, action, params, opts)

        _ ->
          Mix.raise("Usage: mix ash_agent.can RESOURCE ACTION [--actor SPEC] [JSON_PARAMS]")
      end
    end)
  end

  defp can(resource_name, action_name, params_json, opts) do
    resource = ensure_module!(resource_name)
    actor = parse_actor!(opts[:actor])
    params = decode_params!(params_json)

    try do
      AshAgentTools.Can.can(resource, action_name, actor, params, record: opts[:record])
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

  # `MODULE:ID` | `none` | `record` — the CLI spelling of the facade's
  # actor spec. `record` resolves the target record and uses it as the
  # actor (the "can this record act on itself?" case).
  defp parse_actor!(nil), do: :none
  defp parse_actor!("none"), do: :none
  defp parse_actor!("record"), do: :record

  defp parse_actor!(spec) do
    case String.split(spec, ":", parts: 2) do
      [module_name, id] ->
        module = ensure_module!(module_name)
        %{resource: module, id: id}

      _ ->
        Mix.raise("Invalid --actor #{inspect(spec)}: use MODULE:ID or none")
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
