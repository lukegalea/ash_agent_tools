# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ast-forks/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.TransitionsTest do
  use ExUnit.Case, async: true

  doctest AshAgentTools.Transitions

  alias AshAgentTools.Test.{Machine, Post}

  describe "transitions/2" do
    test "projects states, initial states, and the state attribute" do
      report = AshAgentTools.transitions(Machine)

      assert report.resource == Machine
      assert report.state_attribute == :state
      assert report.initial_states == [:pending]
      assert report.default_initial_state == :pending
      # compile-time derived: every state named by the transitions
      assert Enum.sort(report.states) ==
               Enum.sort([:pending, :confirmed, :rejected, :cancelled, :archived])
    end

    test "projects every transition with wildcards passed through" do
      report = AshAgentTools.transitions(Machine)

      transitions = Map.new(report.transitions, &{&1.action, &1})

      assert Map.fetch!(transitions, :confirm).from == [:pending]
      assert Map.fetch!(transitions, :confirm).to == [:confirmed]

      assert Map.fetch!(transitions, :reject).to == [:rejected, :cancelled]

      assert Map.fetch!(transitions, :archive).from == [:confirmed, :rejected]
      assert Map.fetch!(transitions, :archive).to == [:archived]
    end

    test "generates the extension's own Mermaid diagrams" do
      report = AshAgentTools.transitions(Machine)

      assert report.mermaid.state_diagram =~ "stateDiagram-v2"
      assert report.mermaid.state_diagram =~ "pending --> confirmed: confirm"

      assert report.mermaid.flowchart =~ "flowchart TD"
    end

    test "the :mermaid opt skips the diagram generation" do
      report = AshAgentTools.transitions(Machine, mermaid: false)

      assert report.mermaid == nil
    end

    test "a resource without the state_machine section raises with its name" do
      assert_raise ArgumentError, ~r/does not use AshStateMachine/, fn ->
        AshAgentTools.transitions(Post)
      end
    end

    test "non-resources and unknown modules raise the usual errors" do
      assert_raise ArgumentError, ~r/not a loaded Ash resource/, fn ->
        AshAgentTools.transitions(String)
      end
    end

    test "the report is JSON-encodable" do
      assert is_binary(Jason.encode!(AshAgentTools.transitions(Machine)))
    end
  end

  describe "availability" do
    test "the report marks ash_state_machine active with its dep and tools" do
      report = AshAgentTools.Availability.report()

      integration = Enum.find(report.integrations, &(&1.integration == :ash_state_machine))
      assert integration.active? == true
      assert integration.dep =~ "ash_state_machine"
      assert :transitions in integration.tools
    end

    test "an unknown integration name raises" do
      assert_raise ArgumentError, ~r/unknown optional integration/, fn ->
        AshAgentTools.Availability.ensure_active!(:bpmn)
      end
    end
  end
end
