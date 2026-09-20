# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

defmodule AshAgentTools.TraceTest do
  use ExUnit.Case, async: true

  doctest AshAgentTools.Trace

  alias AshAgentTools.Trace

  # A span fixture in the JSON-decoded shape agents actually hand over:
  # string keys, string status.
  defp span(overrides) do
    Map.merge(
      %{
        "name" => "span",
        "kind" => "internal",
        "status" => "ok",
        "attributes" => %{},
        "start" => 0,
        "end" => 10,
        "trace_id" => "t1",
        "span_id" => "s1",
        "parent_id" => nil
      },
      overrides
    )
  end

  describe "explain/2 — shape" do
    test "an empty trace is a valid, empty report" do
      report = Trace.explain([])

      assert report.root == nil
      assert report.errors == []
      assert report.policy == []
      assert report.queries == []
      assert report.notifications == []
      assert report.async == []
      assert report.symbols == []
      assert report.summary == %{trace_id: nil, span_count: 0, duration: nil}
      refute report.truncated?
      assert report.backend_url == nil
    end

    test "atom- and string-keyed spans produce the same report" do
      atom_report =
        Trace.explain([
          %{
            name: "ash.read",
            status: :ok,
            attributes: %{},
            start: 0,
            end: 90,
            trace_id: "t1",
            span_id: "s1",
            parent_id: nil
          }
        ])

      string_report =
        Trace.explain([
          %{
            "name" => "ash.read",
            "status" => "ok",
            "attributes" => %{},
            "start" => 0,
            "end" => 90,
            "trace_id" => "t1",
            "span_id" => "s1",
            "parent_id" => nil
          }
        ])

      assert atom_report.root.name == string_report.root.name
      assert atom_report.summary == string_report.summary
    end

    test "status shapes: OTel integer codes, status maps, and strings" do
      errors = fn status -> Trace.explain([span(%{"status" => status})]).errors end

      assert [%{message: "boom"}] = errors.(%{"code" => 2, "message" => "boom"})
      assert [%{message: nil}] = errors.(2)
      assert length(errors.("ERROR")) == 1
      assert length(errors.(%{code: :error})) == 1

      assert [] = errors.(0)
      assert [] = errors.(1)
      assert [] = errors.("ok")
      assert [] = errors.(%{code: :unset})
    end

    test "root selection prefers the parentless span; orphans whose parent left the set are roots too" do
      report =
        Trace.explain([
          span(%{"name" => "child", "span_id" => "kid", "parent_id" => "gone"}),
          span(%{"name" => "root", "span_id" => "top", "start" => -5})
        ])

      assert report.root.name == "root"
      assert report.summary.trace_id == "t1"
    end

    test "summary duration is the root span's, in input units" do
      report = Trace.explain([span(%{"start" => 1_000, "end" => 1_500})])
      assert report.summary.duration == 500
    end
  end

  describe "explain/2 — error traces" do
    test "errors come innermost first, with depth and message" do
      report =
        Trace.explain([
          span(%{
            "name" => "http.request",
            "kind" => "server",
            "status" => "error",
            "end" => 100
          }),
          span(%{
            "name" => "ash.create",
            "status" => %{code: :error, message: "title is required"},
            "span_id" => "s2",
            "parent_id" => "s1"
          }),
          span(%{
            "name" => "validate",
            "status" => %{code: :error, message: "deeper still"},
            "span_id" => "s3",
            "parent_id" => "s2"
          })
        ])

      assert Enum.map(report.errors, & &1.name) == ["validate", "ash.create", "http.request"]
      assert Enum.map(report.errors, & &1.depth) == [2, 1, 0]
      assert hd(report.errors).message == "deeper still"
    end

    test "error.message attribute fills in when the status has no message" do
      report =
        Trace.explain([
          span(%{
            "status" => :error,
            "attributes" => %{"error.message" => "boom"},
            "span_id" => "s2"
          })
        ])

      assert hd(report.errors).message == "boom"
    end
  end

  describe "explain/2 — queries and N+1 detection" do
    test "identical sources under one parent collapse into one flagged entry" do
      parent = span(%{"name" => "ash.read", "span_id" => "p", "end" => 90})

      queries =
        for i <- 1..3 do
          span(%{
            "name" => "query",
            "kind" => "client",
            "attributes" => %{"db.statement" => "select comments"},
            "span_id" => "q#{i}",
            "parent_id" => "p",
            "start" => i,
            "end" => i + 9
          })
        end

      [entry] = Trace.explain([parent | queries]).queries

      assert entry.source == "select comments"
      assert entry.count == 3
      assert entry.n_plus_one? == true
      assert entry.parent_span_id == "p"
      assert entry.duration == 9 * 3
    end

    test "distinct sources under one parent are not flagged; same source under different parents is not either" do
      spans = [
        span(%{"span_id" => "p1", "name" => "read_one"}),
        span(%{"span_id" => "p2", "name" => "read_two"}),
        span(%{
          "span_id" => "a",
          "kind" => "client",
          "parent_id" => "p1",
          "attributes" => %{"db.statement" => "select a"}
        }),
        span(%{
          "span_id" => "b",
          "kind" => "client",
          "parent_id" => "p1",
          "attributes" => %{"db.statement" => "select b"}
        }),
        span(%{
          "span_id" => "c",
          "kind" => "client",
          "parent_id" => "p2",
          "attributes" => %{"db.statement" => "select a"}
        })
      ]

      queries = Trace.explain(spans).queries

      assert Enum.all?(queries, &(&1.n_plus_one? == false))
      assert Enum.map(queries, & &1.source) |> Enum.sort() == ["select a", "select a", "select b"]
    end

    test "N+1 entries come first, highest count first" do
      parent = span(%{"name" => "ash.read", "span_id" => "p"})

      trio =
        for i <- 1..3 do
          span(%{
            "span_id" => "t#{i}",
            "kind" => "client",
            "parent_id" => "p",
            "attributes" => %{"db.statement" => "select trio"}
          })
        end

      pair =
        for i <- 1..2 do
          span(%{
            "span_id" => "d#{i}",
            "kind" => "client",
            "parent_id" => "p",
            "attributes" => %{"db.statement" => "select duo"}
          })
        end

      single = [
        span(%{
          "span_id" => "one",
          "kind" => "client",
          "parent_id" => "p",
          "attributes" => %{"db.statement" => "select one"}
        })
      ]

      report = Trace.explain([parent] ++ trio ++ pair ++ single)

      assert Enum.map(report.queries, &{&1.source, &1.count}) == [
               {"select trio", 3},
               {"select duo", 2},
               {"select one", 1}
             ]

      assert [trio_entry, duo_entry, _] = report.queries
      assert trio_entry.n_plus_one? and duo_entry.n_plus_one?
    end

    test "client spans without a statement use their name as the source" do
      report =
        Trace.explain([span(%{"span_id" => "c1", "name" => "http.post", "kind" => "client"})])

      assert [%{source: "http.post", count: 1}] = report.queries
    end
  end

  describe "explain/2 — policy, notifications, async, symbols" do
    test "policy spans report name and decision" do
      report =
        Trace.explain([
          span(%{
            "name" => "ash.apply_policy",
            "span_id" => "pol",
            "attributes" => %{"ash.policy.decision" => :forbid}
          })
        ])

      assert [%{name: "ash.apply_policy", decision: "forbid"}] = report.policy
    end

    test "notification spans group by name with counts" do
      report =
        Trace.explain([
          span(%{
            "span_id" => "n1",
            "name" => "ash.notification",
            "attributes" => %{"ash.notification" => "post_created"}
          }),
          span(%{
            "span_id" => "n2",
            "name" => "ash.notification",
            "attributes" => %{"ash.notification" => "post_created"}
          }),
          span(%{"span_id" => "n3", "name" => "ash.notification"})
        ])

      assert report.notifications == [
               %{name: "ash.notification", count: 3}
             ]
    end

    test "producer/consumer kinds land in async" do
      report =
        Trace.explain([
          span(%{"span_id" => "p", "name" => "enqueue", "kind" => "producer"}),
          span(%{"span_id" => "c", "name" => "dequeue", "kind" => :consumer})
        ])

      assert Enum.map(report.async, & &1.kind) |> Enum.sort() == ["consumer", "producer"]
      assert Enum.map(report.async, & &1.name) |> Enum.sort() == ["dequeue", "enqueue"]
    end

    test "ash.symbol_id attributes collect into symbols with their spans" do
      report =
        Trace.explain([
          span(%{
            "span_id" => "x1",
            "name" => "ash.read",
            "attributes" => %{"ash.symbol_id" => "MyApp.Post/read"}
          }),
          span(%{
            "span_id" => "x2",
            "name" => "ash.read",
            "attributes" => %{"ash.symbol_id" => "MyApp.Post/read"}
          }),
          span(%{
            "span_id" => "x3",
            "name" => "ash.create",
            "attributes" => %{"ash.symbol_id" => "MyApp.Post/create"}
          })
        ])

      assert report.symbols == [
               %{symbol: "MyApp.Post/create", span_count: 1, spans: ["ash.create"]},
               %{symbol: "MyApp.Post/read", span_count: 2, spans: ["ash.read"]}
             ]
    end
  end

  describe "explain/2 — budget" do
    test "entries are dropped until the encoded report fits, with truncated? raised" do
      spans =
        for i <- 1..50 do
          span(%{
            "name" => "query",
            "kind" => "client",
            "attributes" => %{"db.statement" => "SELECT #{i} FROM t"},
            "span_id" => "s#{i}",
            "start" => i,
            "end" => i + 1
          })
        end

      report = Trace.explain(spans, budget: 600)

      assert report.truncated?
      assert length(report.queries) < 50
      encoded = Jason.encode!(report)
      assert byte_size(encoded) <= 600
    end

    test "errors survive longest when everything must go" do
      spans = [
        span(%{"status" => :error, "span_id" => "err"}),
        for i <- 1..30 do
          span(%{
            "span_id" => "q#{i}",
            "kind" => "client",
            "attributes" => %{"db.statement" => "SELECT #{i} FROM big_table_name"}
          })
        end
      ]

      report = Trace.explain(List.flatten(spans), budget: 500)

      assert report.truncated?
      assert report.errors != []
    end

    test "a small trace under budget is not truncated" do
      report = Trace.explain([span(%{})])
      refute report.truncated?
    end

    test "backend_url is echoed" do
      report =
        Trace.explain([span(%{})],
          backend_url: "https://tempo.example.com/trace/t1"
        )

      assert report.backend_url == "https://tempo.example.com/trace/t1"
    end
  end

  describe "explain/2 — input validation" do
    test "raises on a non-list" do
      assert_raise ArgumentError, ~r/spans must be a list/, fn ->
        Trace.explain("not spans")
      end
    end

    test "raises on a non-map span" do
      assert_raise ArgumentError, ~r/each span must be a map/, fn ->
        Trace.explain([span(%{}), "oops"])
      end
    end

    test "raises on an invalid budget" do
      assert_raise ArgumentError, ~r/:budget must be a positive integer/, fn ->
        Trace.explain([span(%{})], budget: -1)
      end
    end

    test "raises on an invalid backend_url" do
      assert_raise ArgumentError, ~r/:backend_url must be a string/, fn ->
        Trace.explain([span(%{})], backend_url: :tempo)
      end
    end
  end

  describe "explain/2 — JSON discipline" do
    test "the report round-trips through Jason even with hostile attribute values" do
      report =
        Trace.explain([
          span(%{
            "span_id" => "h1",
            "status" => :error,
            "attributes" => %{
              "db.statement" => "select 1",
              "weird" => {:tuple, self(), make_ref()}
            }
          })
        ])

      assert is_binary(Jason.encode!(report))
    end
  end

  describe "facade explain_trace/2" do
    test "delegates to Trace.explain/2" do
      report = AshAgentTools.explain_trace([span(%{"span_id" => "f1"})], budget: 10_000)
      assert report.root.name == "span"
      assert Map.has_key?(report, :truncated?)
    end
  end
end
