# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.GateSystemOneTest do
  use ExUnit.Case, async: true

  alias AshAgentTools.Gate
  alias AshAgentTools.Test.GateRung

  @table Path.expand("fixtures/agent_gate_system_one.dmn", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "gate_s1_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp ask(ctx, command, opts \\ []) do
    Gate.explain(
      %{
        "hook_event_name" => "PreToolUse",
        "tool_name" => "Bash",
        "tool_input" => %{"command" => command},
        "cwd" => ctx.root,
        "session_id" => GateRung.session(self())
      },
      Keyword.merge(
        [root: ctx.root, system_one: GateRung, system_one_table: @table, system_one_timeout: 500],
        opts
      )
    )
  end

  defp decision(result), do: {result.decision, result.rule_id}

  describe "only a deferred call reaches the rung" do
    test "a rule's deny makes no model call", ctx do
      result = ask(ctx, "git push -f origin main")
      assert decision(result) == {"deny", "gate_force_push"}
      assert result.rung == "deterministic"
      assert result.system_one == nil
      refute_received {:rung_called, _pid}
    end

    test "a rule's ask makes no model call", ctx do
      assert {"ask", _rule} = ask(ctx, "git push origin main") |> decision()
      refute_received {:rung_called, _pid}
    end

    test "with no rung configured, a deferred call stays deferred", ctx do
      result = ask(ctx, "rung-yes", system_one: false)
      assert decision(result) == {"defer", "gate_no_rule"}
      refute_received {:rung_called, _pid}
    end
  end

  describe "the rung's answer, banded by the table" do
    test "a certified benign reading is allowed", ctx do
      result = ask(ctx, "rung-no ls")
      assert_received {:rung_called, _pid}
      assert decision(result) == {"allow", "s1_benign"}
      assert result.rung == "system_one"
      assert result.system_one.outcome == "answered"
      assert result.system_one.capped == nil
      assert result.system_one.audit.model_version == "test-model"
      assert result.table == @table

      assert result.definition_hash ==
               :crypto.hash(:sha256, File.read!(@table)) |> Base.encode16(case: :lower)

      assert hd(result.matched_rule_ids) == "s1_benign"
    end

    test "an unsure reading is an ask", ctx do
      assert decision(ask(ctx, "rung-unsure")) == {"ask", "s1_unsure"}
    end
  end

  describe "the rung only makes a call stricter" do
    test "uncertified judgment never allows", ctx do
      result = ask(ctx, "rung-uncertified")
      assert decision(result) == {"ask", "s1_benign"}
      assert result.system_one.table_decision == "allow"
      assert result.system_one.capped == "uncertified_allow"
      assert result.reason =~ "not certified"
    end

    test "a model never refuses on its own", ctx do
      result = ask(ctx, "rung-yes")
      assert decision(result) == {"ask", "s1_destructive"}
      assert result.system_one.table_decision == "deny"
      assert result.system_one.capped == "deny"
    end
  end

  describe "a rung that cannot answer is an ask, never an allow" do
    for {command, label} <- [
          {"rung-sleep", "a timeout"},
          {"rung-raise", "a raise"},
          {"rung-error", "an error"},
          {"rung-exit", "an exit"},
          {"rung-garbage", "an answer that is not the contract"}
        ] do
      test label, ctx do
        result = ask(ctx, unquote(command))
        assert decision(result) == {"ask", "system_one_unavailable"}
        assert result.rung == "system_one"
        assert result.system_one.outcome == "model_unavailable"
      end
    end

    test "a missing banding table", ctx do
      result = ask(ctx, "rung-no", system_one_table: Path.join(ctx.root, "missing.dmn"))
      assert decision(result) == {"ask", "system_one_unavailable"}
    end

    test "a timed-out rung is stopped", ctx do
      ask(ctx, "rung-sleep")
      assert_received {:rung_called, pid}
      refute Process.alive?(pid)
    end
  end

  test "the audit line records both rungs", ctx do
    log = Path.join(ctx.root, "gate.jsonl")

    Gate.check(
      %{"tool" => "Bash", "command" => "rung-uncertified", "cwd" => ctx.root},
      root: ctx.root,
      log: log,
      system_one: GateRung,
      system_one_table: @table
    )

    [line] = log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert %{
             "decision" => "ask",
             "rung" => "system_one",
             "rule_id" => "s1_benign",
             "evaluations" => [%{"rule_id" => "gate_no_rule", "definition_hash" => seed_hash}],
             "system_one" => %{
               "outcome" => "answered",
               "certified" => false,
               "capped" => "uncertified_allow",
               "inputs" => %{"destructive" => "no"},
               "audit" => %{"question_hashes" => ["sha256:q1", "sha256:q2"]}
             }
           } = line

    assert is_binary(seed_hash)

    assert line["definition_hash"] ==
             :crypto.hash(:sha256, File.read!(@table)) |> Base.encode16(case: :lower)
  end

  test "verify/1 proves the banding table when the rung is configured", ctx do
    report = Gate.verify(root: ctx.root, system_one: GateRung, system_one_table: @table)
    assert @table in Enum.map(report.tables, & &1.table)
    assert report.ok?
  end

  test "system_one_children/1 starts a rung that has a runtime" do
    assert Gate.system_one_children(system_one: GateRung) == []
    assert Gate.system_one_children(system_one: false) == []
  end
end
