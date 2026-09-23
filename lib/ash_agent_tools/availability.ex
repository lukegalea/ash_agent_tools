# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Availability do
  @moduledoc """
  Which optional concept integrations are active in this VM.

  Concept tooling (compliance rules, state machines) arrives behind
  **optional** dependencies: hosts add the dep, the tools activate. Nothing
  is forced on hosts that do not need the concept, and a missing dep is
  never a compile-time problem — every integration is gated behind
  `Code.ensure_loaded?/1` conditional compilation (the same Ecto-Jason
  pattern the MCP plug uses), so this package compiles cleanly with or
  without any of them. At runtime, a tool whose integration is absent
  answers with a structured "not available" error that names the dep to
  add:

      ** (ArgumentError) ash_rules tooling is not available: add
      {:ash_rules, github: "lukegalea/ash_rules"} to your deps to use this

  `report/0` is the discovery side of that contract: one entry per optional
  integration with its activation status, the dep to add, and the tools it
  unlocks.
  """

  @type integration ::
          :ash_rules | :ash_state_machine | :ash_bpmn | :ash_decisions

  @integrations [
    %{
      integration: :ash_rules,
      module: AshRules,
      dep: ~s({:ash_rules, github: "lukegalea/ash_rules"}),
      tools: [:rules],
      concept: "compliance rules as data: fact schemas, rule bundles, dry evaluation"
    },
    %{
      integration: :ash_state_machine,
      module: AshStateMachine,
      dep: ~s({:ash_state_machine, "~> 0.2.13"}),
      tools: [:transitions],
      concept: "resource state machines: states, transitions, Mermaid diagrams"
    },
    %{
      integration: :ash_bpmn,
      module: AshBpmn,
      dep: ~s({:ash_bpmn, github: "lukegalea/ash_bpmn"}),
      tools: [:processes, :process_graph, :process_instance],
      concept: "BPMN process engine: definitions, graphs, in-flight instances and tasks"
    },
    %{
      integration: :ash_decisions,
      module: AshDecisions,
      dep: ~s({:ash_decisions, github: "lukegalea/ash_decisions"}),
      tools: [:decisions, :decision_evaluate],
      concept: "DMN decisions: catalogues, stored verification, dry evaluation"
    }
  ]

  @doc """
  The optional integrations this package knows about, as plain data:
  `:integration`, the module that marks it loaded, the `:dep` to add, the
  `:tools` it unlocks, and the `:concept` it serves.
  """
  @spec integrations() :: [map()]
  def integrations, do: @integrations

  @doc """
  Whether the optional integration is active: its marker module is loaded
  (which for a host application means it ships the dep).
  """
  @spec active?(integration()) :: boolean()
  def active?(integration) do
    case fetch(integration) do
      %{module: module} -> Code.ensure_loaded?(module)
      nil -> false
    end
  end

  @doc """
  The availability report: one entry per optional integration, sorted by
  name. Plain and JSON-encodable; never raises.
  """
  @spec report() :: map()
  def report do
    %{
      integrations:
        @integrations
        |> Enum.map(fn integration ->
          %{
            integration: integration.integration,
            active?: active?(integration.integration),
            dep: integration.dep,
            tools: integration.tools,
            concept: integration.concept
          }
        end)
        |> Enum.sort_by(& &1.integration)
    }
  end

  @doc """
  Raises the structured "not available" error for an inactive integration:
  it names the dep to add, so the agent (or the human behind it) can fix the
  environment in one step. The happy path is silence — an active integration
  returns `:ok`.
  """
  @spec ensure_active!(integration()) :: :ok
  def ensure_active!(integration) do
    case fetch(integration) do
      %{dep: dep} ->
        unless active?(integration) do
          raise ArgumentError,
                "#{Atom.to_string(integration)} tooling is not available:" <>
                  " add #{dep} to your deps to use this" <>
                  " (see AshAgentTools.Availability.report/0)"
        end

        :ok

      nil ->
        raise ArgumentError, "unknown optional integration #{inspect(integration)}"
    end
  end

  defp fetch(integration) do
    Enum.find(@integrations, &(&1.integration == integration))
  end
end
