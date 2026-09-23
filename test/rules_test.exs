# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ast-forks/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.RulesTest do
  use ExUnit.Case, async: true

  doctest AshAgentTools.Rules

  alias AshAgentTools.Test.RuleSets.KYC

  describe "list_rule_sets/0" do
    test "finds the fixture rule set with its bundle metadata" do
      rule_sets = AshAgentTools.rule_sets()

      kyc = Enum.find(rule_sets, &(&1.module == KYC))
      assert kyc != nil
      assert kyc.combining == :deny_overrides
      assert kyc.compiler_version == "1"
      assert String.length(kyc.content_hash) == 64
    end

    test "is JSON-encodable" do
      assert is_binary(Jason.encode!(AshAgentTools.rule_sets()))
    end
  end

  describe "describe/1" do
    test "projects the fact schema with absence semantics" do
      report = AshAgentTools.Rules.describe(KYC)

      facts = Map.new(report.fact_schema, &{&1.name, &1})
      status = Map.fetch!(facts, :status)

      assert status.type == :atom
      assert status.one_of == ["active", "suspended"]
      assert status.missing == false

      has_valid_kyc = Map.fetch!(facts, :has_valid_kyc)
      assert has_valid_kyc.missing == :unknown
      assert has_valid_kyc.description =~ "no data means we cannot know"
    end

    test "projects rules with predicates, outcomes, and metadata" do
      report = AshAgentTools.Rules.describe(KYC)

      rules = Map.new(report.rules, &{&1.id, &1})
      kyc_rule = Map.fetch!(rules, "kyc.valid_required")

      assert kyc_rule.severity == :medium
      assert kyc_rule.outcome == %{outcome: :noncompliant, gap: "kyc.valid_required"}

      # projected JSON-safe: atoms render as strings
      assert [%{op: :has, name: :status, value: "active"}, %{op: :has, name: :jurisdiction}] =
               kyc_rule.applicability

      assert [%{op: :neg, name: :has_valid_kyc, value: true}] = kyc_rule.failure_conditions

      balance = Map.fetch!(rules, "acct.balance_frozen")
      assert [%{subject: %{var: "account"}}] = balance.failure_conditions
    end

    test "a non-rule-set module raises with the loaded candidates" do
      assert_raise ArgumentError, ~r/not a loaded AshRules rule set/, fn ->
        AshAgentTools.Rules.describe(AshAgentTools.Test.Post)
      end
    end
  end

  describe "evaluate/3" do
    test "dry-evaluates a module against triples, firing findings" do
      report =
        AshAgentTools.evaluate_rules(KYC, [
          {:customer, :status, :active},
          {:customer, :jurisdiction, :regulated},
          {:customer, :has_valid_kyc, false}
        ])

      assert report.overall == :noncompliant
      assert report.combining == :deny_overrides
      assert is_binary(report.bundle_hash)

      finding = Enum.find(report.requirements, &(&1.rule_id == "kyc.valid_required"))
      assert {finding.outcome, finding.gap} == {:noncompliant, "kyc.valid_required"}
      # a rule without a message renders its own name
      assert finding.message == "active regulated customer requires valid KYC"

      other = Enum.find(report.requirements, &(&1.rule_id == "acct.balance_frozen"))
      assert other.outcome == :not_applicable
    end

    test "absence semantics surface as unknown, never silent compliance" do
      report =
        AshAgentTools.evaluate_rules(KYC, [
          {"customer", "status", "active"},
          {"customer", "jurisdiction", "regulated"}
        ])

      assert report.overall == :unknown

      finding = Enum.find(report.requirements, &(&1.rule_id == "kyc.valid_required"))
      assert finding.outcome == :unknown
      assert Enum.any?(report.missing_facts, &(&1.predicate == :has_valid_kyc))
    end

    test "variables bind across facts" do
      report =
        AshAgentTools.evaluate_rules(KYC, [
          {"customer", "status", "suspended"},
          {"acct_1", "owner", "customer"},
          {"acct_1", "balance", 500}
        ])

      finding = Enum.find(report.requirements, &(&1.rule_id == "acct.balance_frozen"))
      assert finding.outcome == :noncompliant
      assert [%{"account" => "acct_1"}] = finding.bindings
    end

    test "accepts map-shaped triples and converts schema-typed values" do
      report =
        AshAgentTools.evaluate_rules(KYC, [
          %{"subject" => "customer", "predicate" => "status", "value" => "active"},
          %{"subject" => "customer", "predicate" => "jurisdiction", "value" => "regulated"},
          %{"subject" => "customer", "predicate" => "has_valid_kyc", "value" => false}
        ])

      assert report.overall == :noncompliant
    end

    test "invalid facts raise with the evaluator's structured message" do
      assert_raise ArgumentError, ~r/bogus_predicate/, fn ->
        AshAgentTools.evaluate_rules(KYC, [{"customer", "bogus_predicate", 1}])
      end
    end

    test "evaluates a bundle JSON document without any module" do
      path = bundle_fixture!()

      try do
        report =
          AshAgentTools.evaluate_rules(path, [
            {"customer", "status", "suspended"},
            {"acct_1", "owner", "customer"},
            {"acct_1", "balance", 100}
          ])

        assert report.overall == :noncompliant
      after
        File.rm(path)
      end
    end

    test "an unreadable bundle document raises with the path" do
      assert_raise ArgumentError, ~r/cannot read bundle document/, fn ->
        AshAgentTools.evaluate_rules("no/such/bundle.json", [])
      end
    end

    test "the result is JSON-encodable" do
      report = AshAgentTools.evaluate_rules(KYC, [{"customer", "status", "active"}])
      assert is_binary(Jason.encode!(report))
    end

    defp bundle_fixture! do
      path =
        Path.join(
          System.tmp_dir!(),
          "ash_agent_tools_bundle_#{System.unique_integer([:positive])}.json"
        )

      bundle = KYC.__bundle__()

      document =
        Jason.encode!(%{
          "revision" => bundle.revision,
          "combining" => Atom.to_string(bundle.combining),
          "fact_schema" => AshRules.Ir.FactSchema.to_json(bundle.fact_schema),
          "rules" => Enum.map(bundle.rules, &AshRules.Ir.Rule.to_json/1)
        })

      File.write!(path, document)
      path
    end
  end

  describe "availability" do
    test "the report marks ash_rules active with its dep and tools" do
      report = AshAgentTools.Availability.report()

      integration = Enum.find(report.integrations, &(&1.integration == :ash_rules))
      assert integration.active? == true
      assert integration.dep =~ "ash_rules"
      assert :rules in integration.tools
    end

    test "the rules tooling is active in this VM" do
      assert AshAgentTools.Availability.active?(:ash_rules) == true
    end
  end
end
