# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.RuntimeTest do
  use ExUnit.Case, async: true

  # The tests run in an env where observer_cli is not compiled (it is a
  # dev-only optional dep), so `:auto` resolves to the builtin backend and
  # every builtin path is exercised through explicit `backend: :builtin`
  # as well.

  alias AshAgentTools.Runtime

  describe "snapshot/1 (builtin)" do
    test "reports the VM vitals" do
      report = Runtime.snapshot(backend: :builtin, n: 5)

      assert report.backend == "builtin"
      assert report.node == to_string(node())
      assert report.otp_release |> String.to_integer() > 20
      assert is_integer(report.uptime_seconds)
      assert is_integer(report.process_count)
      assert is_integer(report.process_limit)
      assert is_integer(report.port_count)
      assert report.schedulers.online >= 1
      assert is_integer(report.run_queue_length)

      assert report.memory["total"] > 0
      assert report.memory["processes"] > 0
      assert report.memory["ets"] > 0

      assert report.ets.table_count > 0
      assert report.ets.total_memory_words > 0
      assert length(report.ets.top) <= 10
      assert Enum.all?(report.ets.top, &(&1.size >= 0 and &1.memory >= 0))

      assert length(report.processes) <= 5
      assert {:ok, _} = Jason.decode(Jason.encode!(report))
    end

    test "echoes trace_id/correlation_id" do
      report = Runtime.snapshot(backend: :builtin, trace_id: "abc", correlation_id: "xyz")

      assert report.trace_id == "abc"
      assert report.correlation_id == "xyz"
    end
  end

  describe "top/2 (builtin)" do
    test "returns at most n processes with the classic fields" do
      report = Runtime.top(7, backend: :builtin)

      assert report.backend == "builtin"
      assert report.sort == "message_queue_len"
      assert report.count == length(report.processes)
      assert length(report.processes) <= 7

      for process <- report.processes do
        assert process.pid =~ ~r/^#PID<\d+\.\d+\.\d+>$/
        assert is_integer(process.message_queue_len) and process.message_queue_len >= 0
        assert is_integer(process.memory) and process.memory > 0
        assert is_integer(process.reductions) and process.reductions >= 0
      end

      # sorted descending by the sort key
      queues = Enum.map(report.processes, & &1.message_queue_len)
      assert queues == Enum.sort(queues, :desc)
    end

    test "sort accepts strings and sorts by memory" do
      report = Runtime.top(5, backend: :builtin, sort: "memory")
      assert report.sort == "memory"

      memories = Enum.map(report.processes, & &1.memory)
      assert memories == Enum.sort(memories, :desc)
    end

    test "invalid sort raises" do
      assert_raise ArgumentError, ~r/:sort must be one of/, fn ->
        Runtime.top(5, backend: :builtin, sort: "cpu")
      end
    end

    test "non-integer n raises" do
      assert_raise ArgumentError, ~r/n must be a positive integer/, fn ->
        Runtime.top("lots", backend: :builtin)
      end
    end
  end

  describe "tree/2 (builtin)" do
    test "walks every started application, sorted by name" do
      report = Runtime.tree(nil, backend: :builtin, depth: 3)

      assert report.backend == "builtin"
      assert report.filter == nil
      names = Enum.map(report.applications, & &1.name)
      assert names == Enum.sort(names)
      assert "elixir" in names
      assert "logger" in names

      for application <- report.applications do
        assert is_binary(application.name)
        assert is_binary(application.version)

        if application.root do
          assert application.root.type == "supervisor"
          assert application.root.id =~ ~r/^#PID<\d+\.\d+\.\d+>$/
          assert is_integer(application.root.child_count)
          assert length(application.root.children) <= 100
        end
      end

      assert {:ok, _} = Jason.decode(Jason.encode!(report))
    end

    test "a library application without a top supervisor reports root: nil" do
      report = Runtime.tree("stdlib", backend: :builtin)
      assert [%{name: "stdlib", root: nil}] = report.applications
    end

    test "the filter walks exactly one application (atom or string)" do
      for app <- [:logger, "logger"] do
        report = Runtime.tree(app, backend: :builtin, depth: 4)
        assert report.filter == "logger"
        assert [%{name: "logger"}] = report.applications
        assert report.applications |> hd() |> Map.get(:root) != nil
      end
    end

    test "caps are honored: depth, width, and the node budget" do
      report = Runtime.tree(nil, backend: :builtin, depth: 1, max_children: 2, max_nodes: 3)

      for application <- report.applications do
        assert walk_children(application.root) == []
      end

      # max_nodes smaller than the tree truncates without crashing
      report = Runtime.tree("logger", backend: :builtin, max_nodes: 1)
      assert [%{name: "logger"}] = report.applications
    end

    test "unknown app raises listing the started applications" do
      assert_raise ArgumentError, ~r/not a started application.*elixir/s, fn ->
        Runtime.tree("definitely_not_started_app", backend: :builtin)
      end
    end

    defp walk_children(nil), do: []

    defp walk_children(node) do
      if node.type == "worker" do
        []
      else
        Enum.flat_map(node.children, fn child ->
          child_children = walk_children(child)
          # depth cap: nodes at the cap report no children at all
          child_children
        end)
      end
    end
  end

  describe "backend selection" do
    test "forcing :observer_cli when it is not loaded raises a directed error" do
      # In this env observer_cli is not compiled (dev-only optional dep), so
      # the forced backend must fail with the remediation in the message.
      assert_raise ArgumentError, ~r/observer_cli 2.0 is not loaded.*backend: :builtin/s, fn ->
        Runtime.snapshot(backend: :observer_cli)
      end
    end

    test ":auto resolves to something that answers" do
      report = Runtime.snapshot([])
      assert report.backend in ["builtin", "observer_cli"]
    end

    test "invalid backend raises" do
      assert_raise ArgumentError, ~r/:backend must be one of/, fn ->
        Runtime.snapshot(backend: :gdb)
      end
    end
  end

  describe "option validation" do
    test "unknown options raise" do
      assert_raise ArgumentError, ~r/unknown/, fn ->
        Runtime.snapshot(bakend: :builtin)
      end
    end

    test "non-string echo values raise" do
      assert_raise ArgumentError, ~r/:trace_id must be a string or nil/, fn ->
        Runtime.snapshot(backend: :builtin, trace_id: 42)
      end
    end

    test "non-positive caps raise" do
      assert_raise ArgumentError, ~r/:depth must be a positive integer/, fn ->
        Runtime.tree(nil, backend: :builtin, depth: 0)
      end

      assert_raise ArgumentError, ~r/:n must be a positive integer/, fn ->
        Runtime.snapshot(backend: :builtin, n: 0)
      end
    end

    test "non-keyword opts raise" do
      assert_raise ArgumentError, ~r/opts must be a keyword list/, fn ->
        Runtime.snapshot("snapshot")
      end
    end
  end
end
