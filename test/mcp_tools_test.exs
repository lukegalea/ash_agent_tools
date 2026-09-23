# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.Mcp.ToolsTest do
  use ExUnit.Case, async: true

  # The tool dispatch layer, called directly (no HTTP). Without a daemon
  # runtime running, every facade-backed tool falls through to the pure
  # facade functions — the same behavior the plug serves when the runtime
  # is not started.

  alias AshAgentTools.Mcp.Tools

  describe "tool cards" do
    test "every card has a schema and the dispatch knows every name" do
      cards = Tools.tool_cards()

      assert length(cards) >= 7

      for card <- cards do
        assert is_binary(card.name) and is_binary(card.description)
        assert card.inputSchema.type == "object"
        assert is_list(card.inputSchema.required)
      end

      assert Enum.map(cards, & &1.name) == Tools.tool_names()
    end

    test "ash_diff is deliberately absent (deferred in v1)" do
      refute "ash_diff" in Tools.tool_names()
    end
  end

  describe "ash_describe" do
    test "no arguments returns the discovery summary" do
      {:ok, summary} = Tools.call("ash_describe", %{})

      assert summary.resource_count >= 1
      assert "AshAgentTools.Test.Post" in summary.resources
      assert "AshAgentTools.Test.Domain" in summary.domains
    end

    test "a short-name resource miss suggests the full module name" do
      {:error, error} = Tools.call("ash_describe", %{"resource" => "Post"})

      assert error.error =~ "not a loaded module"
      assert "AshAgentTools.Test.Post" in error.did_you_mean
    end

    test "an unknown action misses with did_you_mean candidates" do
      {:error, error} =
        Tools.call("ash_describe", %{"resource" => "AshAgentTools.Test.Post", "action" => "creat"})

      assert error.error =~ "no action named"
      assert "create" in error.did_you_mean
    end
  end

  describe "ash_validate" do
    test "validates params without executing anything" do
      {:ok, report} =
        Tools.call("ash_validate", %{
          "resource" => "AshAgentTools.Test.Post",
          "action" => "create",
          "params" => %{"title" => "Hi", "score" => "7"}
        })

      assert report.valid? == true
      assert report.normalized_inputs["score"] == 7
    end

    test "unknown action errors are structured with did_you_mean" do
      {:error, error} =
        Tools.call("ash_validate", %{"resource" => "AshAgentTools.Test.Post", "action" => "crate"})

      assert error.error =~ "no action named"
      assert "create" in error.did_you_mean
    end

    test "a missing action argument is a structured error" do
      {:error, error} = Tools.call("ash_validate", %{"resource" => "AshAgentTools.Test.Post"})

      assert error.error =~ "\"action\""
    end
  end

  describe "ash_search" do
    test "searches across loaded resources" do
      {:ok, hits} = Tools.call("ash_search", %{"term" => "by_tag"})

      assert Enum.any?(hits, &(&1.resource == AshAgentTools.Test.Post and &1.name == :by_tag))
    end

    test "kind filters accept JSON strings" do
      {:ok, hits} = Tools.call("ash_search", %{"term" => "score", "kinds" => ["attribute"]})

      assert Enum.all?(hits, &(&1.kind == :attribute))
    end

    test "an unknown kind is a structured error" do
      {:error, error} = Tools.call("ash_search", %{"term" => "score", "kinds" => ["nope"]})

      assert error.error =~ "unknown search kind"
    end
  end

  describe "ash_context" do
    test "resolves the module at a file position" do
      {:ok, report} =
        Tools.call("ash_context", %{"file" => "test/support/context_probe.ex", "line" => 21})

      assert report.match.kind == :attribute
      assert report.match.name == :excerpt
    end

    test "a bad line argument is a structured error" do
      {:error, error} = Tools.call("ash_context", %{"file" => "lib/foo.ex", "line" => "21"})

      assert error.error =~ "positive integer"
    end
  end

  describe "ash_forbidden" do
    test "lists the policies of a resource" do
      {:ok, report} =
        Tools.call("ash_forbidden", %{
          "resource" => "AshAgentTools.Test.Guarded",
          "action" => "read"
        })

      assert length(report.policies) == 2
      assert Enum.any?(report.policies, & &1.bypass?)
    end
  end

  describe "ash_can" do
    test "answers an anonymous verdict without executing anything" do
      {:ok, report} =
        Tools.call("ash_can", %{"resource" => "AshAgentTools.Test.Guarded", "action" => "create"})

      assert report.allowed == false
      assert report.verdict == :forbidden
      assert report.actor.kind == :none
    end

    test "accepts the MODULE:ID actor spelling" do
      {:ok, admin} = create_user!(%{admin: true})

      {:ok, report} =
        Tools.call("ash_can", %{
          "resource" => "AshAgentTools.Test.User",
          "action" => "update",
          "actor" => "AshAgentTools.Test.User:#{admin.id}"
        })

      assert {report.allowed, report.verdict} == {true, :allowed}
    end

    test "accepts the object actor spelling" do
      {:ok, user} = create_user!(%{})

      {:ok, report} =
        Tools.call("ash_can", %{
          "resource" => "AshAgentTools.Test.User",
          "action" => "update",
          "actor" => %{"resource" => "AshAgentTools.Test.User", "id" => user.id}
        })

      assert report.allowed == false
      assert report.responsible.reason == :unknown
    end

    test "a malformed actor spec is a structured error" do
      {:error, error} =
        Tools.call("ash_can", %{
          "resource" => "AshAgentTools.Test.User",
          "action" => "update",
          "actor" => 42
        })

      assert error.error =~ "actor must be"
    end

    defp create_user!(params) do
      AshAgentTools.Test.User
      |> Ash.Changeset.for_create(:create, params)
      |> Ash.create(authorize?: false)
    end
  end

  describe "ash_rules" do
    test "no arguments lists the loaded rule sets" do
      {:ok, rule_sets} = Tools.call("ash_rules", %{})

      assert Enum.any?(rule_sets, &(&1.module == AshAgentTools.Test.RuleSets.KYC))
    end

    test "a module argument describes one rule set" do
      {:ok, report} = Tools.call("ash_rules", %{"module" => "AshAgentTools.Test.RuleSets.KYC"})

      assert report.combining == :deny_overrides
      assert length(report.rules) == 2
    end

    test "module + facts dry-evaluates the bundle" do
      {:ok, report} =
        Tools.call("ash_rules", %{
          "module" => "AshAgentTools.Test.RuleSets.KYC",
          "facts" => [
            %{"subject" => "customer", "predicate" => "status", "value" => "active"},
            %{"subject" => "customer", "predicate" => "jurisdiction", "value" => "regulated"},
            %{"subject" => "customer", "predicate" => "has_valid_kyc", "value" => false}
          ]
        })

      assert report.overall == :noncompliant
    end

    test "an invalid bundle module is a structured error" do
      {:error, error} = Tools.call("ash_rules", %{"module" => "AshAgentTools.Test.Post"})

      assert error.error =~ "not a loaded AshRules rule set"
    end
  end

  describe "ash_transitions" do
    test "describes a state-machine resource with diagrams" do
      {:ok, report} =
        Tools.call("ash_transitions", %{"resource" => "AshAgentTools.Test.Machine"})

      assert report.state_attribute == :state
      assert length(report.transitions) == 3
      assert report.mermaid.state_diagram =~ "stateDiagram-v2"
    end

    test "a non-state-machine resource is a structured error" do
      {:error, error} =
        Tools.call("ash_transitions", %{"resource" => "AshAgentTools.Test.Post"})

      assert error.error =~ "does not use AshStateMachine"
    end
  end

  describe "daemon-only tools without a running daemon" do
    test "ash_daemon_status reports the absent runtime honestly" do
      {:ok, status} = Tools.call("ash_daemon_status", %{})

      assert status.status == :no_runtime
    end

    test "ash_reload errors with a hint instead of crashing" do
      {:error, error} = Tools.call("ash_reload", %{})

      assert error.error =~ "runtime is not started"
      assert error.hint =~ "mix ash_agent.serve"
    end
  end

  describe "unknown tools" do
    test "miss with did_you_mean over the real tool names" do
      {:error, error} = Tools.call("ash_describ", %{})

      assert error.error =~ "unknown tool"
      assert "ash_describe" in error.did_you_mean
    end
  end
end
