# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.DecisionToolsTest do
  use AshAgentTools.BpmnCase, async: true

  # the facade's decisions/2 doctest reads the database — same deal as the
  # bpmn case above.
  doctest AshAgentTools, only: [decisions: 2], tags: [db: true]

  @definition_resource AshAgentTools.Test.Decisions.Definition
  @evaluation_resource AshAgentTools.Test.Decisions.Evaluation
  @domain AshAgentTools.Test.DecisionsDomain

  @surcharge_xml File.read!("test/fixtures/surcharge.dmn")

  describe "decisions/2" do
    @describetag :db

    test "lists the catalogue per key with the declared decisions" do
      publish_definition!(@definition_resource, "surcharge", "Surcharge", @surcharge_xml)

      report = AshAgentTools.decisions()

      assert report.count == 1
      [entry] = report.decisions
      assert entry.domain == "AshAgentTools.Test.DecisionsDomain"
      assert {entry.key, entry.status, entry.has_draft} == {"surcharge", :published, false}
      assert entry.latest_published_version == 1
      assert [%{name: "Surcharge", inputs: inputs, outputs: outputs}] = entry.decisions
      assert Enum.any?(inputs, &(&1.name == "region"))
      assert Enum.any?(outputs, &(&1.name == "surcharge"))
    end

    test "graph and stored verification are available per request" do
      publish_definition!(@definition_resource, "surcharge", "Surcharge", @surcharge_xml)

      bare = AshAgentTools.decisions()
      refute Map.has_key?(hd(bare.decisions), :graph)

      with_graph = AshAgentTools.decisions(nil, graph: true)
      assert is_map(hd(with_graph.decisions).graph)

      # the stored attribute, reported as-is — the Verifier is not re-run
      with_verification = AshAgentTools.decisions(nil, verification: true)
      verification = hd(with_verification.decisions).verification
      assert is_map(verification) or is_nil(verification)
    end
  end

  describe "decision_evaluate/3" do
    @describetag :db

    test "evaluates the published decision and records nothing" do
      publish_definition!(@definition_resource, "surcharge", "Surcharge", @surcharge_xml)

      report = AshAgentTools.decision_evaluate("surcharge", %{"region" => "international"})

      assert report.decision == "Surcharge"
      # a single-output decision evaluates to its scalar value (a Decimal,
      # projected JSON-safe as its string form)
      assert report.outputs == "25"
      assert report.version == 1
      assert report.recorded? == false

      # the record:false proof: the ledger is untouched
      assert Ash.read!(@evaluation_resource, authorize?: false) == []
    end

    test "an explicit version pins the evaluation" do
      publish_definition!(@definition_resource, "surcharge", "Surcharge", @surcharge_xml)

      report =
        AshAgentTools.decision_evaluate("surcharge", %{"region" => "domestic"}, version: 1)

      assert report.outputs == "0"
      assert report.version == 1
    end

    test "an ambiguous document names the declared decisions" do
      publish_definition!(@definition_resource, "surcharge", "Surcharge", @surcharge_xml)

      # the fixture declares one decision, so an explicit WRONG name exercises
      # the structured-error path
      error =
        try do
          AshAgentTools.decision_evaluate("surcharge", %{"region" => "international"},
            decision: "NotDeclared"
          )
        rescue
          e in ArgumentError -> Exception.message(e)
        end

      assert error =~ "failed"
      assert Ash.read!(@evaluation_resource, authorize?: false) == []
    end

    test "a missing key raises with the structured message" do
      assert_raise ArgumentError, ~r/no such decision key "nope"/, fn ->
        AshAgentTools.decision_evaluate("nope", %{})
      end
    end
  end

  describe "the MCP surface" do
    @describetag :db

    test "ash_decision_evaluate answers and writes nothing" do
      publish_definition!(@definition_resource, "surcharge", "Surcharge", @surcharge_xml)

      {:ok, report} =
        AshAgentTools.Mcp.Tools.call("ash_decision_evaluate", %{
          "key" => "surcharge",
          "inputs" => %{"region" => "international"}
        })

      assert {report.decision, report.recorded?} == {"Surcharge", false}
      assert Ash.read!(@evaluation_resource, authorize?: false) == []
    end
  end

  describe "availability" do
    @describetag :db

    test "the report carries both engine integrations with their tools" do
      report = AshAgentTools.Availability.report()

      bpmn = Enum.find(report.integrations, &(&1.integration == :ash_bpmn))
      assert bpmn.active? == true
      assert bpmn.dep =~ "ash_bpmn"
      assert :process_graph in bpmn.tools

      decisions = Enum.find(report.integrations, &(&1.integration == :ash_decisions))
      assert decisions.active? == true
      assert decisions.dep =~ "ash_decisions"
      assert :decision_evaluate in decisions.tools
    end
  end
end
