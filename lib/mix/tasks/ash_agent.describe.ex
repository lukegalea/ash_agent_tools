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
  no arguments). The output is plain JSON; nothing is executed against your
  data.

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
    * `--pretty` - pretty-print the JSON (default: compact, which is cheaper for agents)

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

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, strict: [action: :string, pretty: :boolean])

    # Resource modules load lazily; make the no-argument discovery summary
    # useful by loading the domains configured the way ash projects declare
    # them (`config :my_app, ash_domains: [...]`).
    load_configured_domains()

    json =
      case {positional, opts[:action]} do
        {[], nil} ->
          summary()

        {[resource], action} ->
          AshAgentTools.describe_action(to_module!(resource), action_or_action_opt(action))

        {[resource, action], nil} ->
          AshAgentTools.describe_action(to_module!(resource), action)

        {_, action} when is_binary(action) ->
          AshAgentTools.describe_action(to_module!(hd(positional)), action)

        _ ->
          Mix.raise("Usage: mix ash_agent.describe [RESOURCE] [--action ACTION]")
      end

    print(json, opts)
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

  defp summary do
    %{
      domains: Enum.map(AshAgentTools.list_domains(), &AshAgentTools.Registry.module_name/1),
      resources: Enum.map(AshAgentTools.list_resources(), &AshAgentTools.Registry.module_name/1)
    }
  end

  defp action_or_action_opt(nil),
    do: raise(ArgumentError, "no action given (use --action ACTION)")

  defp action_or_action_opt(action), do: action

  defp to_module!(name) when is_binary(name) do
    module = Module.concat([name])

    case Code.ensure_loaded(module) do
      {:module, module} -> module
      {:error, reason} -> Mix.raise("Cannot load #{name}: #{inspect(reason)}")
    end
  end

  defp print(json, opts) do
    json
    |> Jason.encode!(pretty: !!opts[:pretty])
    |> Mix.shell().info()
  end
end
