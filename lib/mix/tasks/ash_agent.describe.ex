# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Describe do
  @shortdoc "Describes Ash resources and actions as JSON"

  @moduledoc """
  Prints a JSON description of Ash domains, resources, and actions.

  Intended for agents and scripts that compose Ash actions without a human
  reading source code. Wraps `AshAgentTools.describe_resource/1` and
  `AshAgentTools.describe_action/2` (or prints a discovery summary when given
  no arguments). Nothing is executed against your data.

  **Boot contract: compile, don't start.** The task boots only
  `app.config` + compile + the domains configured under
  `config :my_app, ash_domains: [...]` — the application is *not started*,
  so nothing runs (no Oban queues, no projectors, no endpoints). See the
  caveats in usage-rules.md.

  **stdout is pure JSON, always.** Logger output is suppressed while the
  task runs, and compilation output is routed away from stdout, so the
  output pipes cleanly into a JSON parser; use `--verbose` if you want the
  logs back.

  ## Usage

      # Discover what is loaded
      mix ash_agent.describe

      # Describe a resource (fields, relationships, actions)
      mix ash_agent.describe MyApp.Post

      # Describe a single action (input contract, return shape, interfaces)
      mix ash_agent.describe MyApp.Post --action create
      mix ash_agent.describe MyApp.Post create

  ## Command line options

    * `--action` - the action name (may also be given as the second positional argument)
    * `--out FILE` - write the JSON to FILE instead of stdout
    * `--pretty` - pretty-print the JSON (default: compact, which is cheaper for agents)
    * `--verbose` - do not suppress Logger output (breaks pure-JSON stdout)

  ## Examples

      $ mix ash_agent.describe MyApp.Post --action publish --pretty
      {
        "resource": "Elixir.MyApp.Post",
        "name": "publish",
        "type": "update",
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
        strict: [action: :string, pretty: :boolean, out: :string, verbose: :boolean]
      )

    AshAgentTools.TaskOutput.with_quiet_logger(opts, fn ->
      AshAgentTools.TaskOutput.ensure_compiled()

      # Resource modules load lazily; make the no-argument discovery summary
      # useful by loading the domains configured the way ash projects declare
      # them (`config :my_app, ash_domains: [...]`).
      AshAgentTools.TaskOutput.load_configured_domains()

      json =
        case {positional, opts[:action]} do
          {[], nil} ->
            summary()

          {[resource], nil} ->
            run_describe(resource, nil, opts)

          {[resource], action} ->
            run_describe(resource, action, opts)

          {[resource, action], nil} ->
            run_describe(resource, action, opts)

          {_, action} when is_binary(action) ->
            run_describe(hd(positional), action, opts)

          _ ->
            Mix.raise("Usage: mix ash_agent.describe [RESOURCE] [--action ACTION]")
        end

      json
      |> Jason.encode!(pretty: !!opts[:pretty])
      |> AshAgentTools.TaskOutput.write_json(opts)
    end)
  end

  # A resource with no action describes the resource itself (the documented
  # `mix ash_agent.describe MyApp.Post` usage).
  defp run_describe(resource_name, nil, opts) do
    module = to_module!(resource_name)

    try do
      AshAgentTools.describe_resource(module)
    rescue
      error in ArgumentError -> emit_describe_error(error, module, nil, opts)
    end
  end

  defp run_describe(resource_name, action, opts) do
    module = to_module!(resource_name)

    try do
      AshAgentTools.describe_action(module, action)
    rescue
      # An agent-supplied action name that resolves to nothing must not
      # break the pure-JSON contract: emit a structured error (with
      # did_you_mean) on stdout and exit non-zero, instead of letting the
      # ArgumentError crash Mix into stderr noise.
      error in ArgumentError ->
        emit_describe_error(error, module, action, opts)
    end
  end

  defp emit_describe_error(error, module, action, opts) do
    did_you_mean =
      if is_binary(action),
        do: AshAgentTools.Describe.action_did_you_mean(module, action),
        else: []

    AshAgentTools.TaskOutput.emit_json_error(
      %{error: Exception.message(error), did_you_mean: did_you_mean},
      opts
    )

    exit({:shutdown, 1})
  end

  defp summary do
    %{
      domains: Enum.map(AshAgentTools.list_domains(), &AshAgentTools.Registry.module_name/1),
      resources: Enum.map(AshAgentTools.list_resources(), &AshAgentTools.Registry.module_name/1)
    }
  end

  defp to_module!(name) when is_binary(name) do
    module = Module.concat([name])

    case Code.ensure_loaded(module) do
      {:module, module} -> module
      {:error, reason} -> Mix.raise("Cannot load #{name}: #{inspect(reason)}")
    end
  end
end
