# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshAgent.Transitions do
  @shortdoc "Describes an AshStateMachine resource as JSON (+ Mermaid)"

  @moduledoc """
  Describes an Ash resource's `AshStateMachine` — states, transitions, and
  the Mermaid diagrams the extension itself ships — as JSON.

  **Requires the optional `ash_state_machine` dependency** (hosts add the
  dep, the tools activate; without it the task answers with the structured
  "add the dep" error). Resources without a `state_machine` section get a
  structured error naming the resource.

  Pure projection of compiled DSL state: nothing transitions, nothing runs.

  **Boot contract: compile, don't start.** **stdout is pure JSON, always.**

  ## Usage

      mix ash_agent.transitions RESOURCE [--no-mermaid] [--out FILE] [--pretty] [--verbose]

  ## Command line options

    * `--no-mermaid` - skip the Mermaid diagram generation
    * `--out FILE` - write the JSON to FILE instead of stdout
    * `--pretty` - pretty-print the JSON (default: compact)
    * `--verbose` - do not suppress Logger output (breaks pure-JSON stdout)

  ## Examples

      $ mix ash_agent.transitions MyApp.Order
      {"resource":"Elixir.MyApp.Order","state_attribute":"state",
       "initial_states":["pending"],"states":["pending","confirmed",...],
       "transitions":[{"action":"confirm","from":["pending"],"to":["confirmed"]},...],
       "mermaid":{"state_diagram":"stateDiagram-v2\\npending --> confirmed: confirm\\n..."}}

  `mermaid.state_diagram` renders as `stateDiagram-v2`,
  `mermaid.flowchart` as `flowchart TD` — both paste straight into docs and
  PRs.
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
          no_mermaid: :boolean,
          pretty: :boolean,
          out: :string,
          verbose: :boolean
        ]
      )

    AshAgentTools.TaskOutput.with_quiet_logger(opts, fn ->
      AshAgentTools.TaskOutput.ensure_compiled()
      AshAgentTools.TaskOutput.load_configured_domains()

      case positional do
        [resource_name] ->
          transitions(resource_name, opts)

        _ ->
          Mix.raise("Usage: mix ash_agent.transitions RESOURCE [--no-mermaid]")
      end
    end)
  end

  defp transitions(resource_name, opts) do
    resource = ensure_module!(resource_name)

    try do
      AshAgentTools.transitions(resource, mermaid: !opts[:no_mermaid])
      |> Jason.encode!(pretty: !!opts[:pretty])
      |> AshAgentTools.TaskOutput.write_json(opts)
    rescue
      error in ArgumentError -> structured_error!(error, opts)
    end
  end

  defp ensure_module!(name) do
    module = Module.concat([name])

    case Code.ensure_loaded(module) do
      {:module, module} -> module
      {:error, reason} -> Mix.raise("Cannot load #{name}: #{inspect(reason)}")
    end
  end

  defp structured_error!(error, opts) do
    AshAgentTools.TaskOutput.emit_json_error(
      %{error: Exception.message(error), did_you_mean: []},
      opts
    )

    exit({:shutdown, 1})
  end
end
