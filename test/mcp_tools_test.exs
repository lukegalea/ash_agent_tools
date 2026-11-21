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

      assert error.error =~ "not a loaded Ash resource"
      assert "AshAgentTools.Test.Post" in error.did_you_mean
    end

    test "every resource sharing the short name is suggested" do
      named = [
        {"post", "MyApp.Blog.Post"},
        {"post", "MyApp.Archive.Post"},
        {"author", "MyApp.Blog.Author"}
      ]

      assert Tools.resource_did_you_mean("Post", named) == [
               "MyApp.Archive.Post",
               "MyApp.Blog.Post"
             ]
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

      assert Enum.any?(hits, &(&1.resource == "AshAgentTools.Test.Post" and &1.name == :by_tag))
    end

    test "resources are module names, never Elixir.-prefixed atom strings" do
      {:ok, hits} = Tools.call("ash_search", %{"term" => "tag"})

      assert hits != []

      assert Enum.all?(
               hits,
               &(is_binary(&1.resource) and not String.starts_with?(&1.resource, "Elixir."))
             )

      refute hits |> Jason.encode!() |> String.contains?("Elixir.")
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

  describe "ash_search kinds" do
    test "accepts the dynamic kinds the card advertises" do
      card_kinds =
        get_in(Tools.tool_cards() |> Enum.find(&(&1.name == "ash_search")), [
          :inputSchema,
          :properties,
          "kinds",
          :items,
          :enum
        ])

      assert "probe_widgets" in card_kinds

      assert {:ok, hits} =
               Tools.call("ash_search", %{"term" => "e", "kinds" => ["probe_widgets"]})

      assert Enum.all?(hits, &(&1.kind == :probe_widgets))
    end
  end

  describe "module arguments never create atoms (iron law #10)" do
    # Each call passes a module name nobody has ever spelled, then checks the
    # atom table: a client string must be matched against known modules, not
    # converted.
    defp fresh_name, do: "NeverSeen.Mod#{System.unique_integer([:positive])}"

    defp refute_atom(name) do
      assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> name) end
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "resource arguments on every resource tool" do
      for tool <- ~w(ash_describe ash_validate ash_can ash_forbidden ash_transitions) do
        name = fresh_name()

        assert {:error, error} =
                 Tools.call(tool, %{"resource" => name, "action" => "create"})

        assert error.error =~ "not a loaded Ash resource"
        refute_atom(name)
      end
    end

    test "the ash_can actor resource, in both spellings" do
      name = fresh_name()

      assert {:error, error} =
               Tools.call("ash_can", %{
                 "resource" => "AshAgentTools.Test.User",
                 "action" => "update",
                 "actor" => name <> ":1"
               })

      assert error.error =~ "not a loaded Ash resource"
      refute_atom(name)

      name = fresh_name()

      assert {:error, _} =
               Tools.call("ash_can", %{
                 "resource" => "AshAgentTools.Test.User",
                 "action" => "update",
                 "actor" => %{"resource" => name, "id" => "1"}
               })

      refute_atom(name)
    end

    test "domain arguments on the BPMN and decision tools" do
      for {tool, args} <- [
            {"ash_processes", %{}},
            {"ash_decisions", %{}},
            {"ash_process_graph", %{"key" => "k"}},
            {"ash_decision_evaluate", %{"key" => "k", "inputs" => %{}}}
          ] do
        name = fresh_name()

        assert {:error, error} = Tools.call(tool, Map.put(args, "domain", name))
        assert error.error =~ "not a loaded Ash domain"
        refute_atom(name)
      end
    end

    test "the ash_rules module argument, alone and with facts" do
      name = fresh_name()
      assert {:error, error} = Tools.call("ash_rules", %{"module" => name})
      assert error.error =~ "not a loaded AshRules rule set"
      refute_atom(name)

      name = fresh_name()
      assert {:error, _} = Tools.call("ash_rules", %{"module" => name, "facts" => []})
      refute_atom(name)
    end

    test "known modules still resolve, with or without the Elixir. prefix" do
      assert {:ok, report} =
               Tools.call("ash_describe", %{"resource" => "Elixir.AshAgentTools.Test.Post"})

      assert report.module == AshAgentTools.Test.Post
    end
  end

  describe "unknown tools" do
    test "miss with did_you_mean over the real tool names" do
      {:error, error} = Tools.call("ash_describ", %{})

      assert error.error =~ "unknown tool"
      assert "ash_describe" in error.did_you_mean
    end
  end

  describe "ash_laws" do
    alias AshAgentTools.Laws

    test "answers exactly what the judge answers for a snippet" do
      source = "def boom(x), do: String.to_atom(x)"

      assert {:ok, report} = Tools.call("ash_laws", %{"source" => source})
      assert report == Laws.judge(source)
      assert [%{law: "10", tier: :definite}] = report.violations
    end

    test "min_tier, laws and diff mirror mix ash_agent.laws" do
      diff = "+++ b/lib/x.ex\n+MyApp.EmailWorker.new(%{user_id: 1})\n"

      assert {:ok, report} = Tools.call("ash_laws", %{"diff" => diff, "laws" => ["08"]})
      assert report == Laws.judge(diff, diff?: true, laws: ["08"])
      assert [%{law: "08", tier: :likely}] = report.violations

      assert {:ok, %{laws_checked: 1}} =
               Tools.call("ash_laws", %{"source" => "x", "laws" => ["10"], "min_tier" => "review"})
    end

    test "reads a project file, relative to the project root" do
      assert {:ok, report} = Tools.call("ash_laws", %{"file" => "mix.exs"})
      assert report.source == "mix.exs"
    end

    test "refuses a file outside the root and reads nothing" do
      for path <- ["../../etc/passwd", "/etc/passwd", "lib/../../outside.ex"] do
        assert {:error, %{error: error}} = Tools.call("ash_laws", %{"file" => path})
        assert error =~ "inside the project root"
      end
    end

    test "refuses a symlink that leads out of the root" do
      dir = Path.join(File.cwd!(), "tmp_laws_link_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      link = Path.join(dir, "escape.ex")
      File.ln_s!("/etc/hostname", link)

      try do
        assert {:error, %{error: error}} =
                 Tools.call("ash_laws", %{"file" => Path.relative_to_cwd(link)})

        assert error =~ "inside the project root"
      after
        File.rm_rf!(dir)
      end
    end

    test "structured errors for bad input" do
      assert {:error, %{error: e}} = Tools.call("ash_laws", %{})
      assert e =~ "exactly one"
      assert {:error, %{error: e}} = Tools.call("ash_laws", %{"source" => "x", "diff" => "y"})
      assert e =~ "exactly one"

      assert {:error, %{did_you_mean: tiers}} =
               Tools.call("ash_laws", %{"source" => "x", "min_tier" => "bad"})

      assert "likely" in tiers
      assert {:error, %{error: e}} = Tools.call("ash_laws", %{"source" => "x", "laws" => ["99"]})
      assert e =~ "99"
    end
  end
end
