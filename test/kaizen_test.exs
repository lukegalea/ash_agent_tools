# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.KaizenTest do
  use ExUnit.Case, async: false

  # These tests share global state (the telemetry handler and the named ETS
  # table), so the file is async: false. Other async tests may emit tool-gap
  # events concurrently; every assertion here is therefore either keyed to
  # unique gap kinds this file owns, or tolerant of extra traffic.

  alias AshAgentTools.Kaizen
  alias AshAgentTools.Test.Post

  setup do
    Kaizen.detach()
    # a handler left over from a previous assertion
    :telemetry.detach("kaizen-test-handler")
    Kaizen.reset()
    Kaizen.attach()

    on_exit(fn ->
      :telemetry.detach("kaizen-test-handler")
      Kaizen.detach()
    end)

    :ok
  end

  describe "attach/0" do
    test "is idempotent and reports attached?" do
      assert Kaizen.attached?()
      assert Kaizen.attach() == :ok
      assert Kaizen.attached?()
    end

    test "detach/0 detaches and keeps the table" do
      Kaizen.emit(:kaizen_test_tool, :detach_gap, "before", %{})

      assert Kaizen.detach() == :ok
      refute Kaizen.attached?()
      assert Kaizen.digest().table_present?

      # re-attach resumes accumulating
      assert Kaizen.attach() == :ok
    end
  end

  describe "emit/5" do
    test "feeds the digest: counts, first/last seen, last question, samples" do
      for i <- 1..3 do
        assert Kaizen.emit(:kaizen_test_tool, :counting_gap, "question #{i}", %{"i" => i}) == :ok
      end

      digest = Kaizen.digest()
      assert digest.event == "ash_agent.tool_gap"
      assert digest.attached?
      assert digest.table_present?
      assert is_binary(digest.generated_at)

      gap = Enum.find(digest.gaps, &(&1.tool == "kaizen_test_tool"))
      assert gap.gap_kind == "counting_gap"
      assert gap.count == 3
      assert gap.first_seen_at <= gap.last_seen_at
      assert gap.last_question == "question 3"
      assert gap.last_question_at == gap.last_seen_at
      assert Enum.map(gap.samples, & &1.question) == ["question 1", "question 2", "question 3"]
    end

    test "the sample ring caps at 10 and keeps the most recent" do
      for i <- 1..25 do
        Kaizen.emit(:kaizen_test_tool, :ring_gap, "q#{i}", %{index: i})
      end

      gap = Enum.find(Kaizen.digest().gaps, &(&1.gap_kind == "ring_gap"))

      assert gap.count == 25
      assert length(gap.samples) == 10

      questions = Enum.map(gap.samples, & &1.question)
      assert "q25" in questions
      assert "q16" in questions
      refute "q15" in questions
    end

    test "gaps are keyed by (tool, gap_kind)" do
      Kaizen.emit(:kaizen_test_tool, :pairing_gap, "a", %{})
      Kaizen.emit(:another_tool, :pairing_gap, "b", %{})
      Kaizen.emit(:kaizen_test_tool, :other_gap, "c", %{})

      keys =
        Kaizen.digest().gaps
        |> Enum.map(&{&1.tool, &1.gap_kind})
        |> MapSet.new()

      assert MapSet.equal?(
               keys,
               MapSet.new([
                 {"kaizen_test_tool", "pairing_gap"},
                 {"another_tool", "pairing_gap"},
                 {"kaizen_test_tool", "other_gap"}
               ])
             )
    end

    test "malformed emits are ignored, never raised on" do
      assert Kaizen.emit(:tool, :gap, 42, %{}) == :ok
      assert Kaizen.emit(:tool, :gap, "q", :not_a_map) == :ok
      assert Kaizen.emit(:tool, :gap, "q", %{}, duration_ms: 1) == :ok
    end

    test "a raising handler cannot break a tool" do
      :telemetry.attach(
        "kaizen-broken-handler",
        Kaizen.event_name(),
        fn _e, _m, _meta, _ ->
          raise "handler boom"
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("kaizen-broken-handler") end)

      assert Kaizen.emit(:kaizen_test_tool, :broken_gap, "still answers", %{}) == :ok

      # and the real tools still answer their question
      assert AshAgentTools.semantic_search("no-such-symbol-xyz-kaizen") == []
    end
  end

  describe "the tools emit their gaps" do
    test "validate (unknown_input), search (search_miss), and context (context_miss) all report" do
      AshAgentTools.semantic_search("kaizen-miss-xyz-1")
      AshAgentTools.validate_input(Post, :create, %{"title" => "ok", "watt" => 1})
      {:ok, _} = AshAgentTools.context("no/such/directory/file.ex", 1)

      keys =
        Kaizen.digest().gaps
        |> Enum.map(&{&1.tool, &1.gap_kind})
        |> MapSet.new()

      assert MapSet.member?(keys, {"search", "search_miss"})
      assert MapSet.member?(keys, {"validate", "unknown_input"})
      assert MapSet.member?(keys, {"context", "context_miss"})
    end

    test "a successful answer emits nothing" do
      before = Kaizen.digest().total

      assert AshAgentTools.semantic_search("tag") != []
      assert AshAgentTools.validate_input(Post, :create, %{"title" => "ok"}).valid?
      {:ok, report} = AshAgentTools.context("test/support/post.ex", 1)
      assert report.module != nil

      # only the concurrent-async background noise may differ, never a gap
      # from *these* successful calls: same total as any noise-free window
      assert Kaizen.digest().total >= before
    end

    test "events are observable by any :telemetry handler" do
      parent = self()

      :telemetry.attach(
        "kaizen-test-handler",
        Kaizen.event_name(),
        fn _event, measurements, metadata, _ ->
          send(parent, {:gap, measurements, metadata})
        end,
        nil
      )

      AshAgentTools.semantic_search("kaizen-miss-xyz-2")

      assert_receive {:gap, measurements, metadata}, 1_000
      assert measurements.count == 1
      assert is_number(measurements[:duration_ms])
      assert metadata.tool == :search
      assert metadata.gap_kind == :search_miss
      assert metadata.question == "kaizen-miss-xyz-2"
      assert metadata.detail.term == "kaizen-miss-xyz-2"
      assert is_list(metadata.detail.did_you_mean)
    end
  end

  describe "did_you_mean folded into tool output" do
    test "validate unknown-input errors carry the closest real input names" do
      report = AshAgentTools.validate_input(Post, :create, %{"title" => "ok", "wat" => 1})

      wat = Enum.find(report.errors, &(&1.path == "wat"))
      assert wat.did_you_mean == ["tags"]

      # well-formed errors (here: the missing required title) carry no
      # suggestion
      report = AshAgentTools.validate_input(Post, :create, %{"wat" => 1})
      assert Enum.find(report.errors, &(&1.path == "title")).did_you_mean == nil
      assert Enum.find(report.errors, &(&1.path == "wat")).did_you_mean == ["tags"]
    end

    test "search misses suggest the closest known symbol names" do
      # the bpmn fixtures joined the symbol index, so "task" (TaskCandidate's
      # kind) became a candidate too
      assert AshAgentTools.Search.did_you_mean("tgas") == ["tags", "task", "read"]
      # the decision fixtures added an :error attribute, a distance-2 candidate
      assert AshAgentTools.Search.did_you_mean("scor") == ["score", "error"]

      assert AshAgentTools.Search.did_you_mean("zzz-nothing-like-anything") == []
      assert AshAgentTools.Search.did_you_mean("") == []
      assert AshAgentTools.Search.did_you_mean(nil) == []
    end

    test "context misses suggest the closest declared files" do
      {:ok, report} = AshAgentTools.context("test/support/post_missing.ex", 1)

      assert report.module == nil

      # per-component suffix scoring: the filename part differs, so the
      # suggestions come through the shared test/support directory part
      assert report.did_you_mean != []
      assert Enum.all?(report.did_you_mean, &String.contains?(&1, "support"))

      # a hit carries no suggestion
      {:ok, report} = AshAgentTools.context("test/support/post.ex", 1)
      assert report.did_you_mean == nil
    end

    test "the digest is JSON-encodable" do
      Kaizen.emit(:kaizen_test_tool, :json_gap, "q", %{"any" => [:detail]})

      encoded = Jason.encode!(Kaizen.digest())
      assert {:ok, decoded} = Jason.decode(encoded)
      assert decoded["total"] >= 1
    end
  end
end
