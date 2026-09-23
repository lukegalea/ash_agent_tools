# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

# Compiled conditionally (Ecto's optional-Jason pattern): `ash_state_machine`
# is an *optional* dependency (hex, `~> 0.2.13`), so a host that does not
# ship it still compiles this package cleanly. Without it the tool answers
# with the structured "not available" error that names the dep to add (see
# `AshAgentTools.Availability`).
if Code.ensure_loaded?(AshStateMachine) do
  defmodule AshAgentTools.Transitions do
    @moduledoc """
    State-machine introspection for Ash resources using `AshStateMachine` —
    active only when the host ships the optional `ash_state_machine`
    dependency (see `AshAgentTools.Availability`; without it the tool raises
    the structured "add the dep" error).

    `transitions/2` projects the compiled `state_machine` DSL section —
    states, initial states, and every transition (`action`/`from`/`to`) —
    via `AshStateMachine.Info`, plus the Mermaid diagrams the extension
    itself ships (`AshStateMachine.Charts.mermaid_state_diagram/1` and
    `mermaid_flowchart/1`). Pure projection of compiled DSL state: nothing
    transitions, nothing runs.

    Resources that do not use `AshStateMachine` get a pointed
    `ArgumentError` naming the resource — the same structured-error path as
    an unknown action.
    """

    alias AshAgentTools.Availability
    alias AshAgentTools.Describe
    alias AshAgentTools.Registry

    @doc """
    The state-machine report for `resource`.

    Report shape:

      * `states` — every state the machine can hold (compile-time derived,
        wildcards expanded)
      * `initial_states` / `default_initial_state` — the declared starting
        points
      * `state_attribute` — the attribute holding the state
      * `transitions` — `%{action:, from:, to:}` entries in declaration
        order (`:*` wildcards passed through verbatim)
      * `mermaid` — the extension's own `stateDiagram-v2` and `flowchart TD`
        renderings, as strings ready to paste

    Options: `:mermaid` (default `true`) set to `false` skips the diagram
    generation. Raises `ArgumentError` for non-resources, resources without
    the `state_machine` section, or an absent `ash_state_machine` dep.

    ## Examples

        iex> report = AshAgentTools.Transitions.transitions(AshAgentTools.Test.Machine)
        iex> {report.initial_states, report.default_initial_state, report.state_attribute}
        {[:pending], :pending, :state}

        iex> report = AshAgentTools.Transitions.transitions(AshAgentTools.Test.Machine, mermaid: false)
        iex> Enum.count(report.transitions)
        3
    """
    @spec transitions(module(), keyword()) :: map()
    def transitions(resource, opts \\ []) do
      Availability.ensure_active!(:ash_state_machine)
      Describe.ensure_resource!(resource)
      ensure_state_machine!(resource)

      %{
        resource: resource,
        state_attribute: unwrap(AshStateMachine.Info.state_machine_state_attribute(resource)),
        initial_states: unwrap(AshStateMachine.Info.state_machine_initial_states(resource)),
        default_initial_state:
          unwrap(AshStateMachine.Info.state_machine_default_initial_state(resource)),
        states: AshStateMachine.Info.state_machine_all_states(resource),
        transitions:
          Enum.map(AshStateMachine.Info.state_machine_transitions(resource), fn transition ->
            %{
              action: transition.action,
              from: List.wrap(transition.from),
              to: List.wrap(transition.to)
            }
          end),
        mermaid: mermaid(resource, opts)
      }
    end

    # Spark.InfoGenerator accessors come in {:ok, value} / value pairs of
    # forms; the bang variants raise, the report prefers a plain projection.
    defp unwrap({:ok, value}), do: value
    defp unwrap(value), do: value

    defp mermaid(resource, opts) do
      if Keyword.get(opts, :mermaid, true) do
        %{
          state_diagram: AshStateMachine.Charts.mermaid_state_diagram(resource),
          flowchart: AshStateMachine.Charts.mermaid_flowchart(resource)
        }
      else
        nil
      end
    end

    defp ensure_state_machine!(resource) do
      if AshStateMachine in Ash.Resource.Info.extensions(resource) do
        :ok
      else
        raise ArgumentError,
              "#{Registry.module_name(resource)} does not use AshStateMachine —" <>
                " point this tool at a resource with a `state_machine` block" <>
                " (or add the extension to it)"
      end
    end
  end
else
  defmodule AshAgentTools.Transitions do
    @moduledoc """
    The `ash_state_machine` tooling stub, compiled when the optional
    `ash_state_machine` dependency is absent. `transitions/2` raises the
    structured "not available" error that names the dep to add — see
    `AshAgentTools.Availability`.
    """

    alias AshAgentTools.Availability

    @spec transitions(module(), keyword()) :: map()
    def transitions(_resource, _opts \\ []) do
      Availability.ensure_active!(:ash_state_machine)
    end
  end
end
